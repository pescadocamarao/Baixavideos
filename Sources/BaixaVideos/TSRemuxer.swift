import Foundation

/// Remuxador interno MPEG-TS → MP4 (passthrough, sem re-encodar e SEM
/// AVFoundation). Motivo: o AVFoundation não lê vários .ts locais — o
/// player abre com duração 0:00 e a exportação falha nos dois presets,
/// embora o arquivo esteja íntegro (toca no VLC). Aqui o app lê o TS
/// com as próprias mãos: separa vídeo/áudio e remonta um MP4 padrão.
///
/// Suporte: vídeo H.264 (faixa 0x1B) e áudio AAC-ADTS (0x0F). Outros
/// codecs são identificados pelo `probe` pra falha nunca ser caixa-preta.
enum TSRemuxer {

    // MARK: - Diagnóstico

    struct Probe {
        var videoCodec = "nenhum"
        var audioCodec = "nenhum"
        var summary: String { "vídeo \(videoCodec), áudio \(audioCodec)" }
    }

    private static func codecName(_ streamType: UInt8) -> String {
        switch streamType {
        case 0x1B: return "H.264"
        case 0x24: return "H.265/HEVC"
        case 0x42: return "H.266/VVC"
        case 0x10: return "MPEG-4"
        case 0x01, 0x02: return "MPEG-1/2 vídeo"
        case 0x0F, 0x11: return "AAC"
        case 0x03, 0x04: return "MP3"
        case 0x06: return "AC-3/privado"
        case 0x81: return "AC-3"
        case 0x84: return "E-AC-3"
        case 0x87: return "DTS"
        default: return String(format: "0x%02X", streamType)
        }
    }

    // MARK: - Estruturas internas

    struct SampleInfo {
        var offset: UInt64
        var size: Int
        var dts: Int64   // relógio 90 kHz, já desenrolado
        var pts: Int64
        var keyframe: Bool
    }

    struct TrackData {
        var pid: Int = -1
        var streamType: UInt8 = 0
        var samples: [SampleInfo] = []
        var payloadBytes: UInt64 = 0
        var firstPts90: Int64 = 0
    }

    // MARK: - Entrada pública

    /// Só lê PAT/PMT e devolve os codecs das faixas principais.
    static func probe(url: URL) -> Probe {
        var probe = Probe()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return probe }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 188 * 400)
        let packetSize = detectPacketSize(data)
        var pmtPID: Int? = nil
        var index = 0
        while index + packetSize <= data.count {
            let packet = data.subdata(in: index..<(index + packetSize))
            index += packetSize
            guard packet.count == packetSize, packet[0] == 0x47 else { continue }
            let pid = (Int(packet[1] & 0x1F) << 8) | Int(packet[2])
            let pusi = (packet[1] & 0x40) != 0
            let adaptation = (packet[3] >> 4) & 0x3
            var payloadStart = 4
            if adaptation == 2 || adaptation == 3 {
                payloadStart += 1 + Int(packet[4])
            }
            if adaptation == 0 || payloadStart >= packetSize { continue }
            let payload = [UInt8](packet.dropFirst(payloadStart))
            if pid == 0 {
                pmtPID = parsePAT(payload, pusi: pusi)
            } else if let pmt = pmtPID, pid == pmt {
                let streams = parsePMT(payload, pusi: pusi)
                for stream in streams {
                    if probe.videoCodec == "nenhum",
                       [0x1B, 0x24, 0x42, 0x10, 0x01, 0x02].contains(stream.type) {
                        probe.videoCodec = codecName(stream.type)
                    }
                    if probe.audioCodec == "nenhum",
                       [0x0F, 0x11, 0x03, 0x04, 0x06, 0x81, 0x84, 0x87].contains(stream.type) {
                        probe.audioCodec = codecName(stream.type)
                    }
                }
                if probe.videoCodec != "nenhum" { break }
            }
        }
        return probe
    }

    /// Remux completo. Roda fora da main thread; devolve true se o MP4
    /// foi escrito. Em qualquer falha, remove a saída parcial.
    static func remux(source: URL, destination: URL) async -> Bool {
        let ok = await Task.detached(priority: .userInitiated) {
            remuxSync(source: source, destination: destination)
        }.value
        if !ok { try? FileManager.default.removeItem(at: destination) }
        return ok
    }

    // MARK: - Análise do TS

    private static func detectPacketSize(_ data: Data) -> Int {
        for size in [188, 192, 204] {
            if data.count > size * 2, data[0] == 0x47,
               data[size] == 0x47, data[size * 2] == 0x47 {
                return size
            }
        }
        return 188
    }

    private static func parsePAT(_ payload: [UInt8], pusi: Bool) -> Int? {
        var bytes = payload
        if pusi {
            guard let pointer = bytes.first else { return nil }
            bytes = Array(bytes.dropFirst(1 + Int(pointer)))
        }
        guard bytes.count > 12, bytes[0] == 0x00 else { return nil }
        let sectionLength = (Int(bytes[1] & 0x0F) << 8) | Int(bytes[2])
        let end = min(bytes.count, 3 + sectionLength - 4)
        var offset = 8
        while offset + 4 <= end {
            let program = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            let pid = (Int(bytes[offset + 2] & 0x1F) << 8) | Int(bytes[offset + 3])
            if program != 0 { return pid }
            offset += 4
        }
        return nil
    }

    private static func parsePMT(_ payload: [UInt8], pusi: Bool)
        -> [(type: UInt8, pid: Int)] {
        var bytes = payload
        if pusi {
            guard let pointer = bytes.first else { return [] }
            bytes = Array(bytes.dropFirst(1 + Int(pointer)))
        }
        guard bytes.count > 12, bytes[0] == 0x02 else { return [] }
        let sectionLength = (Int(bytes[1] & 0x0F) << 8) | Int(bytes[2])
        let end = min(bytes.count, 3 + sectionLength - 4)
        let programInfoLength = (Int(bytes[10] & 0x0F) << 8) | Int(bytes[11])
        var offset = 12 + programInfoLength
        var streams: [(UInt8, Int)] = []
        while offset + 5 <= end {
            let type = bytes[offset]
            let pid = (Int(bytes[offset + 1] & 0x1F) << 8) | Int(bytes[offset + 2])
            let infoLength = (Int(bytes[offset + 3] & 0x0F) << 8) | Int(bytes[offset + 4])
            streams.append((type, pid))
            offset += 5 + infoLength
        }
        return streams
    }

    /// Desenrola o relógio de 33 bits dos carimbos de tempo do TS.
    private struct Unwrapper {
        private var lastRaw: Int64 = -1
        private var offset: Int64 = 0
        mutating func unwrap(_ raw: Int64) -> Int64 {
            if lastRaw >= 0 {
                if raw < lastRaw - (1 << 32) { offset += (1 << 33) }
                if raw > lastRaw + (1 << 32) { offset -= (1 << 33) }
            }
            lastRaw = raw
            return raw + offset
        }
    }

    // MARK: - Remux (síncrono)

    private static func remuxSync(source: URL, destination: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: source) else { return false }
        defer { try? handle.close() }

        let tmpDir = FileManager.default.temporaryDirectory
        let videoTmp = tmpDir.appendingPathComponent("tsremux-v-\(UUID().uuidString).bin")
        let audioTmp = tmpDir.appendingPathComponent("tsremux-a-\(UUID().uuidString).bin")
        defer {
            try? FileManager.default.removeItem(at: videoTmp)
            try? FileManager.default.removeItem(at: audioTmp)
        }
        FileManager.default.createFile(atPath: videoTmp.path, contents: nil)
        FileManager.default.createFile(atPath: audioTmp.path, contents: nil)
        guard let videoOut = try? FileHandle(forWritingTo: videoTmp),
              let audioOut = try? FileHandle(forWritingTo: audioTmp) else { return false }

        var video = TrackData()
        var audio = TrackData()
        var pmtPID: Int? = nil
        var sps: [UInt8]? = nil
        var pps: [UInt8]? = nil
        var audioConfig: (profile: Int, sampleRateIndex: Int, sampleRate: Int, channels: Int)? = nil
        var videoUnwrap = Unwrapper()
        var audioUnwrap = Unwrapper()

        // PES em montagem (um PES de vídeo = uma unidade de acesso)
        var currentPES: (pid: Int, pts: Int64, dts: Int64, payload: [UInt8])? = nil

        func flushPES() {
            guard let pes = currentPES else { return }
            currentPES = nil
            if pes.pid == video.pid {
                // Separa as NAL units do PES; SPS/PPS vão pro avcC e os
                // demais viram a amostra com prefixos de tamanho.
                var sample = Data()
                var isKey = false
                for nal in splitAnnexB(pes.payload) {
                    guard let type = nal.first.map({ $0 & 0x1F }) else { continue }
                    switch type {
                    case 7: sps = nal
                    case 8: pps = nal
                    case 9: continue // AUD não entra na amostra
                    default:
                        if type == 5 { isKey = true }
                        var length = UInt32(nal.count).bigEndian
                        withUnsafeBytes(of: &length) { sample.append(contentsOf: $0) }
                        sample.append(contentsOf: nal)
                    }
                }
                guard !sample.isEmpty else { return }
                let info = SampleInfo(
                    offset: video.payloadBytes, size: sample.count,
                    dts: pes.dts, pts: pes.pts, keyframe: isKey || video.samples.isEmpty)
                if video.samples.isEmpty { video.firstPts90 = pes.pts }
                video.samples.append(info)
                video.payloadBytes += UInt64(sample.count)
                videoOut.write(sample)
            } else if pes.pid == audio.pid {
                // Quebra o PES em quadros ADTS; cada quadro é uma amostra.
                var bytes = pes.payload
                var framePts = pes.pts
                var isFirst = true
                while bytes.count >= 7 {
                    guard bytes[0] == 0xFF, (bytes[1] & 0xF0) == 0xF0 else {
                        bytes = Array(bytes.dropFirst()); continue
                    }
                    let profile = Int((bytes[2] >> 6) & 0x3)
                    let sfIndex = Int((bytes[2] >> 2) & 0xF)
                    let channels = Int(((bytes[2] & 0x1) << 2) | ((bytes[3] >> 6) & 0x3))
                    let frameLength = (Int(bytes[3] & 0x3) << 11)
                        | (Int(bytes[4]) << 3) | (Int(bytes[5]) >> 5)
                    guard frameLength >= 7, bytes.count >= frameLength else { break }
                    let headerLength = (bytes[1] & 0x1) == 0 ? 9 : 7
                    let raw = Array(bytes[headerLength..<frameLength])
                    if audioConfig == nil {
                        let rates = [96000, 88200, 64000, 48000, 44100, 32000,
                                     24000, 22050, 16000, 12000, 11025, 8000, 7350]
                        let rate = (sfIndex >= 0 && sfIndex < rates.count) ? rates[sfIndex] : 44100
                        audioConfig = (profile, sfIndex, rate, channels == 0 ? 2 : channels)
                    }
                    let info = SampleInfo(
                        offset: audio.payloadBytes, size: raw.count,
                        dts: framePts, pts: framePts, keyframe: true)
                    if audio.samples.isEmpty { audio.firstPts90 = framePts }
                    audio.samples.append(info)
                    audio.payloadBytes += UInt64(raw.count)
                    audioOut.write(Data(raw))
                    if let rate = audioConfig?.sampleRate, rate > 0 {
                        framePts += Int64(1024 * 90000 / rate)
                    }
                    bytes = Array(bytes.dropFirst(frameLength))
                    isFirst = false
                }
                _ = isFirst
            }
        }

        // Varredura dos pacotes
        let chunkSize = 188 * 4096
        var leftover = Data()
        var sawVideo = false
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            var buffer = leftover + chunk
            let packetSize = detectPacketSize(buffer)
            let usable = buffer.count - (buffer.count % packetSize)
            var index = 0
            while index + packetSize <= usable {
                let packet = [UInt8](buffer[index..<(index + packetSize)])
                index += packetSize
                guard packet[0] == 0x47 else { continue }
                let pid = (Int(packet[1] & 0x1F) << 8) | Int(packet[2])
                let pusi = (packet[1] & 0x40) != 0
                let adaptation = (packet[3] >> 4) & 0x3
                var payloadStart = 4
                if adaptation == 2 || adaptation == 3 {
                    payloadStart += 1 + Int(packet[4])
                }
                if adaptation == 0 || payloadStart >= packetSize { continue }
                let payload = Array(packet[payloadStart..<packetSize])

                if pid == 0 {
                    if pmtPID == nil { pmtPID = parsePAT(payload, pusi: pusi) }
                    continue
                }
                if let pmt = pmtPID, pid == pmt {
                    if video.pid < 0 {
                        for stream in parsePMT(payload, pusi: pusi) {
                            if stream.type == 0x1B, video.pid < 0 {
                                video.pid = stream.pid; video.streamType = stream.type
                            } else if stream.type == 0x0F, audio.pid < 0 {
                                audio.pid = stream.pid; audio.streamType = stream.type
                            }
                        }
                    }
                    continue
                }
                guard pid == video.pid || pid == audio.pid else { continue }
                sawVideo = sawVideo || pid == video.pid

                if pusi {
                    flushPES()
                    // Cabeçalho PES: 00 00 01 + stream id + flags
                    guard payload.count >= 9,
                          payload[0] == 0x00, payload[1] == 0x00, payload[2] == 0x01
                    else { continue }
                    let flags = payload[7]
                    let headerLength = Int(payload[8])
                    var pts: Int64 = -1
                    var dts: Int64 = -1
                    if flags & 0x80 != 0, payload.count >= 14 {
                        pts = parseTimestamp(Array(payload[9..<14]))
                        if flags & 0x40 != 0, payload.count >= 19 {
                            dts = parseTimestamp(Array(payload[14..<19]))
                        } else { dts = pts }
                    }
                    let body = payload.count >= 9 + headerLength
                        ? Array(payload[(9 + headerLength)...]) : []
                    if pid == video.pid {
                        let p = pts >= 0 ? videoUnwrap.unwrap(pts) : (video.samples.last?.pts ?? 0) + 3000
                        let d = dts >= 0 ? videoUnwrap.unwrap(dts) : p
                        currentPES = (pid, p, d, body)
                    } else {
                        let p = pts >= 0 ? audioUnwrap.unwrap(pts) : (audio.samples.last?.pts ?? 0)
                        currentPES = (pid, p, p, body)
                    }
                } else if currentPES?.pid == pid {
                    currentPES?.payload.append(contentsOf: payload)
                }
            }
            leftover = buffer.subdata(in: usable..<buffer.count)
            _ = buffer
        }
        flushPES()
        try? videoOut.close()
        try? audioOut.close()

        guard sawVideo, !video.samples.isEmpty,
              let spsData = sps, let ppsData = pps,
              let dimensions = SPSParser.dimensions(from: spsData) else { return false }

        return MP4Writer.write(
            destination: destination,
            video: video, audio: audio,
            sps: spsData, pps: ppsData,
            dimensions: dimensions,
            audioConfig: audioConfig,
            videoTmp: videoTmp, audioTmp: audioTmp)
    }

    private static func parseTimestamp(_ b: [UInt8]) -> Int64 {
        guard b.count == 5 else { return -1 }
        let v = (Int64(b[0] >> 1) & 0x7) << 30
            | Int64(b[1]) << 22
            | (Int64(b[2] >> 1) & 0x7F) << 15
            | Int64(b[3]) << 7
            | Int64(b[4] >> 1) & 0x7F
        return v
    }

    /// Divide um fluxo Annex-B em NAL units (sem os códigos de início).
    private static func splitAnnexB(_ bytes: [UInt8]) -> [[UInt8]] {
        var units: [[UInt8]] = []
        var start: Int? = nil
        var i = 0
        func startCodeLength(at pos: Int) -> Int {
            if pos + 4 <= bytes.count, bytes[pos] == 0, bytes[pos + 1] == 0,
               bytes[pos + 2] == 0, bytes[pos + 3] == 1 { return 4 }
            if pos + 3 <= bytes.count, bytes[pos] == 0, bytes[pos + 1] == 0,
               bytes[pos + 2] == 1 { return 3 }
            return 0
        }
        while i < bytes.count {
            let length = startCodeLength(at: i)
            if length > 0 {
                if let s = start, i > s { units.append(Array(bytes[s..<i])) }
                start = i + length
                i += length
            } else {
                i += 1
            }
        }
        if let s = start, s < bytes.count { units.append(Array(bytes[s...])) }
        return units
    }
}

// MARK: - Leitura do SPS (dimensões do vídeo)

/// Leitor de bits Exp-Golomb mínimo, só pra extrair largura/altura do
/// SPS H.264 (o MP4 precisa delas no cabeçalho da faixa de vídeo).
enum SPSParser {
    private struct BitReader {
        let bytes: [UInt8]
        var pos = 0
        mutating func bit() -> Int {
            guard pos < bytes.count * 8 else { return 0 }
            let value = (bytes[pos / 8] >> (7 - (pos % 8))) & 1
            pos += 1
            return Int(value)
        }
        mutating func bits(_ count: Int) -> Int {
            var value = 0
            for _ in 0..<count { value = (value << 1) | bit() }
            return value
        }
        mutating func ue() -> Int {
            var zeros = 0
            while bit() == 0, zeros < 32 { zeros += 1 }
            return (1 << zeros) - 1 + bits(zeros)
        }
        mutating func se() -> Int {
            let code = ue()
            return (code % 2 == 0) ? -(code / 2) : (code + 1) / 2
        }
        mutating func skipScalingList(_ size: Int) {
            var lastScale = 8
            var nextScale = 8
            for _ in 0..<size {
                if nextScale != 0 {
                    let delta = se()
                    nextScale = (lastScale + delta + 256) % 256
                }
                lastScale = (nextScale == 0) ? lastScale : nextScale
            }
        }
    }

    static func dimensions(from sps: [UInt8]) -> (width: Int, height: Int)? {
        guard sps.count >= 4, (sps[0] & 0x1F) == 7 else { return nil }
        // Remove a prevenção de emulação (00 00 03 → 00 00) só pra leitura.
        var rbsp: [UInt8] = []
        var i = 1 // pula o cabeçalho NAL
        while i < sps.count {
            if i + 2 < sps.count, sps[i] == 0, sps[i + 1] == 0, sps[i + 2] == 3 {
                rbsp.append(contentsOf: [0, 0])
                i += 3
            } else {
                rbsp.append(sps[i])
                i += 1
            }
        }
        guard rbsp.count >= 3 else { return nil }
        var reader = BitReader(bytes: rbsp)
        let profile = reader.bits(8)
        _ = reader.bits(8) // constraint flags
        _ = reader.bits(8) // level
        _ = reader.ue()    // sps id
        var chromaFormat = 1
        var subWidth = 2
        var subHeight = 2
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            chromaFormat = reader.ue()
            if chromaFormat == 3 { _ = reader.bit() }
            switch chromaFormat {
            case 0: subWidth = 1; subHeight = 2
            case 1: subWidth = 2; subHeight = 2
            case 2: subWidth = 2; subHeight = 1
            case 3: subWidth = 1; subHeight = 1
            default: break
            }
            _ = reader.ue() // bit_depth_luma_minus8
            _ = reader.ue() // bit_depth_chroma_minus8
            _ = reader.bit() // qpprime_y_zero_transform_bypass
            if reader.bit() == 1 { // seq_scaling_matrix_present
                let count = chromaFormat != 3 ? 8 : 12
                for list in 0..<count {
                    if reader.bit() == 1 {
                        reader.skipScalingList(list < 6 ? 16 : 64)
                    }
                }
            }
        }
        _ = reader.ue() // log2_max_frame_num_minus4
        let pocType = reader.ue()
        if pocType == 0 {
            _ = reader.ue()
        } else if pocType == 1 {
            _ = reader.bit()
            _ = reader.se()
            _ = reader.se()
            let cycles = reader.ue()
            for _ in 0..<cycles { _ = reader.se() }
        }
        _ = reader.ue() // max_num_ref_frames
        _ = reader.bit() // gaps
        let widthMbs = reader.ue() + 1
        let heightMap = reader.ue() + 1
        let frameMbsOnly = reader.bit()
        if frameMbsOnly == 0 { _ = reader.bit() }
        _ = reader.bit() // direct_8x8
        var crop = (left: 0, right: 0, top: 0, bottom: 0)
        if reader.bit() == 1 {
            crop = (reader.ue(), reader.ue(), reader.ue(), reader.ue())
        }
        let cropUnitX = chromaFormat == 0 ? 1 : subWidth
        let cropUnitY = chromaFormat == 0
            ? (2 - frameMbsOnly) : subHeight * (2 - frameMbsOnly)
        let width = widthMbs * 16 - (crop.left + crop.right) * cropUnitX
        let height = (2 - frameMbsOnly) * heightMap * 16
            - (crop.top + crop.bottom) * cropUnitY
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }
}

// MARK: - Escrita do MP4

/// Monta o MP4 final: ftyp + moov (tabelas construídas das amostras) +
/// mdat copiado dos arquivos temporários de carga útil. Um bloco (chunk)
/// por faixa — formato simples e aceito pelos players.
enum MP4Writer {
    private static func u32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
    private static func u64(_ value: UInt64) -> [UInt8] {
        u32(UInt32((value >> 32) & 0xFFFF_FFFF)) + u32(UInt32(value & 0xFFFF_FFFF))
    }
    private static func u16(_ value: UInt16) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
    private static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        u32(UInt32(payload.count + 8)) + Array(type.utf8) + payload
    }
    private static func fullBox(_ type: String, version: UInt8, flags: UInt32,
                                _ payload: [UInt8]) -> [UInt8] {
        box(type, [version] + Array(u32(flags).suffix(3)) + payload)
    }
    private static let matrix: [UInt8] = u32(0x0001_0000) + u32(0) + u32(0)
        + u32(0) + u32(0x0001_0000) + u32(0) + u32(0) + u32(0) + u32(0x4000_0000)
    private static let epoch: UInt32 = 2_082_844_800 // 1904 → 1970

    /// O TS montado de pedaços de HLS costuma ter carimbos de tempo com
    /// saltos e voltas nas emendas — o player engasga nisso (o VLC
    /// perdoa, o do iPhone não). Reconstrói a linha do tempo do vídeo:
    /// DTS sempre crescente, com o passo típico (mediana) nas emendas.
    private static func retimed(_ track: TSRemuxer.TrackData) -> TSRemuxer.TrackData {
        guard track.samples.count > 2 else { return track }
        var deltas: [Int64] = []
        for index in 1..<track.samples.count {
            let delta = track.samples[index].dts - track.samples[index - 1].dts
            if delta > 0 { deltas.append(delta) }
        }
        guard !deltas.isEmpty else { return track }
        let median = deltas.sorted()[deltas.count / 2]
        var fixed = track
        var lastDts = fixed.samples[0].dts
        for index in 1..<fixed.samples.count {
            var dts = fixed.samples[index].dts
            let delta = dts - lastDts
            if delta <= 0 || delta > 4 * median { dts = lastDts + median }
            let cto = max(0, fixed.samples[index].pts - fixed.samples[index].dts)
            fixed.samples[index].dts = dts
            fixed.samples[index].pts = dts + cto
            lastDts = dts
        }
        return fixed
    }

    static func write(destination: URL,
                      video rawVideo: TSRemuxer.TrackData,
                      audio: TSRemuxer.TrackData,
                      sps: [UInt8], pps: [UInt8],
                      dimensions: (width: Int, height: Int),
                      audioConfig: (profile: Int, sampleRateIndex: Int, sampleRate: Int, channels: Int)?,
                      videoTmp: URL, audioTmp: URL) -> Bool {
        let video = retimed(rawVideo)
        // Sincronia entre as faixas: o início global é o menor primeiro
        // carimbo; o atraso de cada faixa vira deslocamento de composição
        // (ctts) — mecanismo padrão, sem listas de edição.
        let hasAudio = !audio.samples.isEmpty && audioConfig != nil
        let videoFirstDts = video.samples.first?.dts ?? 0
        let videoFirstPts = video.samples.first?.pts ?? 0
        let audioFirstPts = hasAudio ? audio.samples.first!.pts : 0
        let globalStart = hasAudio ? min(videoFirstDts, audioFirstPts) : videoFirstDts
        let videoCtoDelta = videoFirstDts - globalStart // ≥ 0, em 90 kHz
        let audioShiftUnits: Int64 = hasAudio
            ? (audioFirstPts - globalStart) * Int64(audioConfig!.sampleRate) / 90000 : 0

        let videoDurations = durations(of: video.samples)
        let videoDuration90 = videoDurations.reduce(0, +)
        var audioDurations: [Int64] = []
        var audioDurationUnits: Int64 = 0
        if hasAudio {
            audioDurations = audio.samples.map { _ in 1024 }
            audioDurationUnits = Int64(audio.samples.count) * 1024
        }
        let movieDurationMs = max(
            (videoDuration90 + videoCtoDelta) * 1000 / 90000,
            hasAudio ? (audioDurationUnits + audioShiftUnits) * 1000
                / Int64(audioConfig!.sampleRate) : 0)

        // moov montado com deslocamentos provisórios pra medir o tamanho;
        // o tamanho não muda com os valores (offsets são de 64 bits fixos).
        func buildMoov(mdatStart: UInt64) -> [UInt8] {
            var tracks: [[UInt8]] = []
            tracks.append(videoTrack(
                samples: video.samples, durations: videoDurations,
                chunkOffset: mdatStart,
                durationMs: UInt32((videoDuration90 + videoCtoDelta) * 1000 / 90000),
                ctoDelta: videoCtoDelta,
                sps: sps, pps: pps, dimensions: dimensions))
            if hasAudio, let config = audioConfig {
                tracks.append(audioTrack(
                    samples: audio.samples, durations: audioDurations,
                    chunkOffset: mdatStart + video.payloadBytes,
                    durationMs: UInt32((audioDurationUnits + audioShiftUnits) * 1000
                                       / Int64(config.sampleRate)),
                    startShiftUnits: audioShiftUnits,
                    config: config))
            }
            var mvhdPayload: [UInt8] = []
            mvhdPayload += u32(epoch) + u32(epoch) + u32(1000)
            mvhdPayload += u32(UInt32(movieDurationMs))
            mvhdPayload += u32(0x0001_0000) + u16(0x0100) + u16(0)
            mvhdPayload += u32(0) + u32(0)
            mvhdPayload += matrix
            for _ in 0..<6 { mvhdPayload += u32(0) }
            mvhdPayload += u32(3)
            let mvhd = fullBox("mvhd", version: 0, flags: 0, mvhdPayload)
            return box("moov", mvhd + tracks.flatMap { $0 })
        }
        _ = videoFirstPts

        let ftyp = box("ftyp", Array("isom".utf8) + u32(0x200)
            + Array("isom".utf8) + Array("iso2".utf8)
            + Array("avc1".utf8) + Array("mp41".utf8))
        let probeMoov = buildMoov(mdatStart: 0)
        let mdatHeaderSize = 16 // tamanho estendido de 64 bits
        let mdatStart = UInt64(ftyp.count + probeMoov.count + mdatHeaderSize)
        let moov = buildMoov(mdatStart: mdatStart)

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: destination) else { return false }
        out.write(Data(ftyp))
        out.write(Data(moov))
        let totalPayload = video.payloadBytes + (hasAudio ? audio.payloadBytes : 0)
        out.write(Data(u32(1) + Array("mdat".utf8)
                       + u64(UInt64(mdatHeaderSize) + totalPayload)))
        func copyFile(_ url: URL) -> Bool {
            guard let input = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? input.close() }
            while true {
                let data = input.readData(ofLength: 1 << 20)
                if data.isEmpty { break }
                out.write(data)
            }
            return true
        }
        let okVideo = copyFile(videoTmp)
        let okAudio = !hasAudio || copyFile(audioTmp)
        try? out.close()
        return okVideo && okAudio
    }

    /// Durações por amostra a partir do DTS da próxima; a última repete
    /// a anterior (ou 3000 ≈ 30 fps no relógio de 90 kHz).
    private static func durations(of samples: [TSRemuxer.SampleInfo]) -> [Int64] {
        var result: [Int64] = []
        for index in samples.indices {
            if index + 1 < samples.count {
                result.append(max(1, samples[index + 1].dts - samples[index].dts))
            } else if let previous = result.last {
                result.append(previous)
            } else {
                result.append(3000)
            }
        }
        return result
    }

    private static func runLength(_ values: [Int64]) -> [(count: Int, value: Int64)] {
        var result: [(Int, Int64)] = []
        for value in values {
            if var last = result.last, last.1 == value {
                last.0 += 1
                result[result.count - 1] = last
            } else {
                result.append((1, value))
            }
        }
        return result
    }

    private static func videoTrack(samples: [TSRemuxer.SampleInfo],
                                   durations: [Int64],
                                   chunkOffset: UInt64,
                                   durationMs: UInt32,
                                   ctoDelta: Int64,
                                   sps: [UInt8], pps: [UInt8],
                                   dimensions: (width: Int, height: Int)) -> [UInt8] {
        let duration90 = durations.reduce(0, +)
        var tkhdPayload: [UInt8] = []
        tkhdPayload += u32(epoch) + u32(epoch) + u32(1) + u32(0)
        tkhdPayload += u32(durationMs)
        tkhdPayload += u32(0) + u32(0)
        tkhdPayload += u16(0) + u16(0) + u16(0) + u16(0)
        tkhdPayload += matrix
        tkhdPayload += u32(UInt32(dimensions.width) << 16)
        tkhdPayload += u32(UInt32(dimensions.height) << 16)
        let tkhd = fullBox("tkhd", version: 0, flags: 0x7, tkhdPayload)
        let mdhd = fullBox("mdhd", version: 0, flags: 0,
            u32(epoch) + u32(epoch) + u32(90000) + u32(UInt32(duration90))
            + u16(0x55C4) + u16(0)) // idioma "und"
        let hdlr = fullBox("hdlr", version: 0, flags: 0,
            u32(0) + Array("vide".utf8) + u32(0) + u32(0) + u32(0)
            + Array("VideoHandler".utf8) + [UInt8(0)])
        var avcC: [UInt8] = [1]
        avcC.append(sps.count > 1 ? sps[1] : 100)
        avcC.append(sps.count > 2 ? sps[2] : 0)
        avcC.append(sps.count > 3 ? sps[3] : 30)
        avcC.append(0xFF)
        avcC.append(0xE1)
        avcC += u16(UInt16(sps.count)) + sps
        avcC.append(1)
        avcC += u16(UInt16(pps.count)) + pps
        var avc1: [UInt8] = []
        avc1 += [UInt8](repeating: 0, count: 6) + u16(1)
        avc1 += u16(0) + u16(0) + u32(0) + u32(0) + u32(0)
        avc1 += u16(UInt16(dimensions.width)) + u16(UInt16(dimensions.height))
        avc1 += u32(0x0048_0000) + u32(0x0048_0000) + u32(0) + u16(1)
        avc1 += [UInt8](repeating: 0, count: 32)
        avc1 += u16(0x0018) + u16(0xFFFF)
        avc1 += box("avcC", avcC)
        let stsd = fullBox("stsd", version: 0, flags: 0, u32(1) + box("avc1", avc1))
        var stts: [UInt8] = u32(UInt32(runLength(durations).count))
        for entry in runLength(durations) {
            stts += u32(UInt32(entry.count)) + u32(UInt32(entry.value))
        }
        // Deslocamentos de composição: (PTS − DTS) de cada amostra, mais
        // o atraso da faixa em relação ao início global (sincronia).
        let cttsValues = samples.map { max(0, $0.pts - $0.dts + ctoDelta) }
        var ctts: [UInt8] = u32(UInt32(runLength(cttsValues).count))
        for entry in runLength(cttsValues) {
            ctts += u32(UInt32(entry.count)) + u32(UInt32(entry.value))
        }
        var stbl = stsd
        stbl += fullBox("stts", version: 0, flags: 0, stts)
        if cttsValues.contains(where: { $0 > 0 }) {
            stbl += fullBox("ctts", version: 0, flags: 0, ctts)
        }
        let keyframes = samples.enumerated().filter { $0.element.keyframe }.map { $0.offset + 1 }
        if keyframes.count < samples.count {
            var stss: [UInt8] = u32(UInt32(keyframes.count))
            for index in keyframes { stss += u32(UInt32(index)) }
            stbl += fullBox("stss", version: 0, flags: 0, stss)
        }
        var stsz: [UInt8] = u32(0) + u32(UInt32(samples.count))
        for sample in samples { stsz += u32(UInt32(sample.size)) }
        stbl += fullBox("stsz", version: 0, flags: 0, stsz)
        stbl += fullBox("stsc", version: 0, flags: 0,
                        u32(1) + u32(1) + u32(UInt32(samples.count)) + u32(1))
        stbl += box("co64", [0, 0, 0, 0] + u32(1) + u64(chunkOffset))
        let minf = box("minf",
            fullBox("vmhd", version: 0, flags: 1, u16(0) + u16(0) + u16(0) + u16(0))
            + box("dinf", fullBox("dref", version: 0, flags: 0,
                                  u32(1) + fullBox("url ", version: 0, flags: 1, [])))
            + box("stbl", stbl))
        let mdia = box("mdia", mdhd + hdlr + minf)
        
        return box("trak", tkhd + mdia)
    }

    private static func audioTrack(samples: [TSRemuxer.SampleInfo],
                                   durations: [Int64],
                                   chunkOffset: UInt64,
                                   durationMs: UInt32,
                                   startShiftUnits: Int64,
                                   config: (profile: Int, sampleRateIndex: Int, sampleRate: Int, channels: Int)) -> [UInt8] {
        var tkhdPayload: [UInt8] = []
        tkhdPayload += u32(epoch) + u32(epoch) + u32(2) + u32(0)
        tkhdPayload += u32(durationMs)
        tkhdPayload += u32(0) + u32(0)
        tkhdPayload += u16(0) + u16(0) + u16(0x0100) + u16(0)
        tkhdPayload += matrix
        tkhdPayload += u32(0) + u32(0)
        let tkhd = fullBox("tkhd", version: 0, flags: 0x7, tkhdPayload)
        let durationUnits = durations.reduce(0, +)
        let mdhd = fullBox("mdhd", version: 0, flags: 0,
            u32(epoch) + u32(epoch) + u32(UInt32(config.sampleRate))
            + u32(UInt32(durationUnits)) + u16(0x55C4) + u16(0))
        let hdlr = fullBox("hdlr", version: 0, flags: 0,
            u32(0) + Array("soun".utf8) + u32(0) + u32(0) + u32(0)
            + Array("SoundHandler".utf8) + [UInt8(0)])
        // Configuração específica do AAC (2 bytes)
        let asc: UInt16 = (UInt16(config.profile + 1) << 11)
            | (UInt16(config.sampleRateIndex) << 7)
            | (UInt16(config.channels) << 3)
        func descriptor(_ tag: UInt8, _ payload: [UInt8]) -> [UInt8] {
            var out: [UInt8] = [tag]
            var length = payload.count
            var encoded: [UInt8] = []
            repeat {
                var byte = UInt8(length & 0x7F)
                length >>= 7
                if length > 0 { byte |= 0x80 }
                encoded.append(byte)
            } while length > 0
            out += encoded + payload
            return out
        }
        let decoderSpecific = descriptor(0x05, u16(asc))
        var decoderConfigBody: [UInt8] = [0x40, 0x15] // AAC, áudio
        decoderConfigBody += [0, 0, 0] + u32(0) + u32(0)
        let decoderConfig = descriptor(0x04, decoderConfigBody + decoderSpecific)
        let slConfig = descriptor(0x06, [0x02])
        let esDescriptor = descriptor(0x03, u16(0) + [UInt8(0)] + decoderConfig + slConfig)
        let esds = fullBox("esds", version: 0, flags: 0, esDescriptor)
        var mp4a: [UInt8] = []
        mp4a += [UInt8](repeating: 0, count: 6) + u16(1)
        mp4a += u32(0) + u32(0)
        mp4a += u16(UInt16(config.channels)) + u16(16)
        mp4a += u16(0) + u16(0)
        mp4a += u32(UInt32(config.sampleRate) << 16)
        mp4a += esds
        let stsd = fullBox("stsd", version: 0, flags: 0, u32(1) + box("mp4a", mp4a))
        var stbl = stsd
        var stts: [UInt8] = u32(UInt32(runLength(durations).count))
        for entry in runLength(durations) {
            stts += u32(UInt32(entry.count)) + u32(UInt32(entry.value))
        }
        stbl += fullBox("stts", version: 0, flags: 0, stts)
        // Atraso inicial do áudio em relação ao início global: só a
        // primeira amostra carrega o deslocamento de composição.
        if startShiftUnits > 0, samples.count > 1 {
            var ctts: [UInt8] = u32(2)
            ctts += u32(1) + u32(UInt32(startShiftUnits))
            ctts += u32(UInt32(samples.count - 1)) + u32(0)
            stbl += fullBox("ctts", version: 0, flags: 0, ctts)
        }
        var stsz: [UInt8] = u32(0) + u32(UInt32(samples.count))
        for sample in samples { stsz += u32(UInt32(sample.size)) }
        stbl += fullBox("stsz", version: 0, flags: 0, stsz)
        stbl += fullBox("stsc", version: 0, flags: 0,
                        u32(1) + u32(1) + u32(UInt32(samples.count)) + u32(1))
        stbl += box("co64", [0, 0, 0, 0] + u32(1) + u64(chunkOffset))
        let minf = box("minf",
            fullBox("smhd", version: 0, flags: 0, u16(0) + u16(0))
            + box("dinf", fullBox("dref", version: 0, flags: 0,
                                  u32(1) + fullBox("url ", version: 0, flags: 1, [])))
            + box("stbl", stbl))
        let mdia = box("mdia", mdhd + hdlr + minf)
        
        return box("trak", tkhd + mdia)
    }
}
