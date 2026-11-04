import Foundation

/// Transporte HTTP de baixo nível usado pela sondagem e pelo motor.
enum DownloadTransport {
    /// UA de Safari desktop: vários CDNs servem a playlist master completa
    /// (com as qualidades altas) pra navegador de desktop, mas entregam uma
    /// variante baixa quando detectam o UA genérico de app.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    static func makeRequest(url: URL, timeout: TimeInterval = 120) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout
        return request
    }

    static func fetchRange(url: URL, start: Int64, end: Int64) async throws -> Data {
        var request = makeRequest(url: url)
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 206 {
            return data
        }
        if http.statusCode == 200 {
            // O servidor ignorou o Range e mandou o arquivo inteiro:
            // recortamos localmente o pedaço pedido.
            guard Int64(data.count) > start else { throw URLError(.badServerResponse) }
            let lower = Int(start)
            let upper = min(Int64(data.count), end + 1)
            guard upper > Int64(lower) else { throw URLError(.badServerResponse) }
            return data.subdata(in: lower..<Int(upper))
        }
        throw URLError(.badServerResponse)
    }

    static func fetchData(url: URL) async throws -> Data {
        let request = makeRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    static func fetchText(url: URL) async throws -> String {
        let data = try await fetchData(url: url)
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .ascii) { return text }
        throw URLError(.cannotDecodeContentData)
    }

    static func expectedLength(of response: HTTPURLResponse) -> Int64? {
        let length = response.expectedContentLength
        return length > 0 ? length : nil
    }
}

/// Passo 01 — Analisar: descobre tipo, tamanho, suporte a Range e,
/// para .m3u8 master, as variantes reais de qualidade.
enum ProbeService {

    static func probe(url: URL) async throws -> ProbeResult {
        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" {
            return try await probeHLS(url: url)
        }
        return try await probeFile(url: url)
    }

    // MARK: Arquivo direto

    private static func probeFile(url: URL) async throws -> ProbeResult {
        // 1) HEAD
        var head = DownloadTransport.makeRequest(url: url, timeout: 30)
        head.httpMethod = "HEAD"
        if let (_, response) = try? await URLSession.shared.data(for: head),
           let http = response as? HTTPURLResponse,
           (200..<300).contains(http.statusCode) {
            let length = DownloadTransport.expectedLength(of: http)
            let ranges = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "")
                .lowercased().contains("bytes")
            return ProbeResult(
                sourceURL: url,
                finalURL: http.url ?? url,
                contentType: http.mimeType,
                contentLength: length,
                supportsRange: ranges && (length ?? 0) > 0,
                kind: .file,
                variants: [],
                segmentCount: nil
            )
        }

        // 2) GET com Range de 1 byte (descobre tamanho via Content-Range)
        var get = DownloadTransport.makeRequest(url: url, timeout: 30)
        get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await URLSession.shared.data(for: get)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var total: Int64? = DownloadTransport.expectedLength(of: http)
        var supportsRange = false
        if http.statusCode == 206 {
            supportsRange = true
            if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               let slash = contentRange.lastIndex(of: "/") {
                let tail = contentRange[contentRange.index(after: slash)...]
                if let parsed = Int64(tail) { total = parsed }
            }
        }
        return ProbeResult(
            sourceURL: url,
            finalURL: http.url ?? url,
            contentType: http.mimeType,
            contentLength: total,
            supportsRange: supportsRange && (total ?? 0) > 0,
            kind: .file,
            variants: [],
            segmentCount: nil
        )
    }

    // MARK: HLS

    private static func probeHLS(url: URL) async throws -> ProbeResult {
        let text = try await DownloadTransport.fetchText(url: url)
        if text.contains("#EXT-X-STREAM-INF") {
            return masterResult(masterURL: url, text: text, sourceURL: url)
        }
        // A URL colada é uma playlist de mídia (qualidade única, geralmente a
        // variante que o player do site escolheu — muitas vezes a baixa).
        // Antes de aceitar, procura uma playlist MASTER irmã com as variantes.
        if let master = await discoverMaster(mediaURL: url) {
            return masterResult(masterURL: master.url, text: master.text, sourceURL: url)
        }
        let lines = text.components(separatedBy: .newlines)
        let segments = lines.filter { $0.hasPrefix("#EXTINF") }.count
        return ProbeResult(
            sourceURL: url,
            finalURL: url,
            contentType: "application/x-mpegURL",
            contentLength: nil,
            supportsRange: false,
            kind: .hlsMedia,
            variants: [],
            segmentCount: segments > 0 ? segments : nil
        )
    }

    private static func masterResult(masterURL: URL, text: String, sourceURL: URL) -> ProbeResult {
        let lines = text.components(separatedBy: .newlines)
        let variants = parseVariants(lines: lines, baseURL: masterURL)
        return ProbeResult(
            sourceURL: sourceURL,
            finalURL: masterURL,
            contentType: "application/x-mpegURL",
            contentLength: nil,
            supportsRange: false,
            kind: .hlsMaster,
            variants: variants.sorted { ($0.height ?? 0, $0.bandwidth) > ($1.height ?? 0, $1.bandwidth) },
            segmentCount: nil
        )
    }

    /// Tenta achar a playlist master a partir de uma playlist de mídia:
    /// mesmos nomes clássicos na mesma pasta e na pasta acima (padrão de CDN:
    /// /720p/index.m3u8 com a master em /index.m3u8 ou /master.m3u8).
    private static func discoverMaster(mediaURL: URL) async -> (url: URL, text: String)? {
        let masterNames = ["master.m3u8", "index.m3u8", "playlist.m3u8", "main.m3u8", "manifest.m3u8", "hls.m3u8"]
        var directories: [URL] = []
        let sameDir = mediaURL.deletingLastPathComponent()
        directories.append(sameDir)
        let parentDir = sameDir.deletingLastPathComponent()
        if parentDir != sameDir { directories.append(parentDir) }

        var candidates: [URL] = []
        for dir in directories {
            for name in masterNames {
                let candidate = dir.appendingPathComponent(name)
                if candidate.absoluteString != mediaURL.absoluteString {
                    candidates.append(candidate)
                }
            }
        }
        for candidate in candidates {
            if let text = try? await DownloadTransport.fetchText(url: candidate),
               text.contains("#EXT-X-STREAM-INF") {
                return (candidate, text)
            }
        }
        return nil
    }

    static func parseVariants(lines: [String], baseURL: URL) -> [HLSVariant] {
        var variants: [HLSVariant] = []
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                var uriLine: String?
                var look = index + 1
                while look < lines.count {
                    let candidate = lines[look].trimmingCharacters(in: .whitespaces)
                    if !candidate.isEmpty && !candidate.hasPrefix("#") {
                        uriLine = candidate
                        break
                    }
                    look += 1
                }
                if let uriLine, let resolved = URL(string: uriLine, relativeTo: baseURL)?.absoluteURL {
                    var width: Int?
                    var height: Int?
                    if let resolution = attrs["RESOLUTION"] {
                        let parts = resolution.split(separator: "x")
                        if parts.count == 2 {
                            width = Int(parts[0])
                            height = Int(parts[1])
                        }
                    }
                    variants.append(HLSVariant(
                        bandwidth: Int(attrs["BANDWIDTH"] ?? "") ?? 0,
                        width: width,
                        height: height,
                        url: resolved
                    ))
                }
            }
            index += 1
        }
        return variants
    }

    /// Divide "A=1,B=\"x,y\",C=2" respeitando aspas.
    static func parseAttributes(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        var current = ""
        var inQuotes = false
        var parts: [String] = []
        for char in raw {
            if char == "\"" { inQuotes.toggle() }
            if char == "," && !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { parts.append(current) }
        for part in parts {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                let key = kv[0].trimmingCharacters(in: .whitespaces)
                let value = kv[1].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                result[key] = value
            }
        }
        return result
    }
}
