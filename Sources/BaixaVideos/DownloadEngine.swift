import Foundation
import AVFoundation

// MARK: - Job

enum StopIntent {
    case none
    case pause
    case cancel
}

@MainActor
final class DownloadJob: ObservableObject, Identifiable {
    let id: UUID
    let request: DownloadRequest

    @Published var state: DownloadState = .queued
    @Published var pieces: [Piece] = []
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64?
    @Published var speedMBs: Double = 0
    @Published var etaSeconds: Double?
    @Published var errorMessage: String?
    @Published var resultItemID: UUID?

    var task: Task<Void, Never>?
    var stopIntent: StopIntent = .none

    private var lastSampleBytes: Int64 = 0
    private var lastSampleDate = Date()

    init(request: DownloadRequest, id: UUID = UUID()) {
        self.id = id
        self.request = request
        self.totalBytes = request.totalBytes
    }

    var title: String { request.title }

    var progress: Double {
        if request.isHLS {
            guard !pieces.isEmpty else { return 0 }
            let done = pieces.filter { $0.state == .done }.count
            return Double(done) / Double(pieces.count)
        }
        guard let totalBytes, totalBytes > 0 else { return 0 }
        return min(1.0, Double(downloadedBytes) / Double(totalBytes))
    }

    var tempDirectory: URL {
        // Documents (não Caches): o iOS pode limpar Caches sozinho, e a
        // retomada entre aberturas do app precisa dos pedaços no disco.
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents
            .appendingPathComponent("InProgress", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func setPieceState(_ pieceID: Int, _ state: PieceState) {
        if let idx = pieces.firstIndex(where: { $0.id == pieceID }) {
            pieces[idx].state = state
        }
    }

    func resetSampler() {
        lastSampleBytes = downloadedBytes
        lastSampleDate = Date()
        speedMBs = 0
        etaSeconds = nil
    }

    func refreshSpeed() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSampleDate)
        guard elapsed >= 0.4 else { return }
        let delta = downloadedBytes - lastSampleBytes
        speedMBs = Double(delta) / elapsed / 1_048_576.0
        lastSampleBytes = downloadedBytes
        lastSampleDate = now
        if let totalBytes, totalBytes > 0, speedMBs > 0 {
            etaSeconds = Double(totalBytes - downloadedBytes) / (speedMBs * 1_048_576.0)
        } else {
            etaSeconds = nil
        }
    }
}

// MARK: - Manager (motor estilo aria2)

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var jobs: [DownloadJob] = []

    private let library: LibraryStore

    private struct PersistedJob: Codable {
        let id: UUID
        let request: DownloadRequest
    }

    private var inProgressDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("InProgress", isDirectory: true)
    }

    private var manifestURL: URL {
        inProgressDirectory.appendingPathComponent("manifest.json")
    }

    init(library: LibraryStore) {
        self.library = library
        restorePersistedJobs()
    }

    // MARK: Persistência da fila (retomar entre aberturas do app)

    private func restorePersistedJobs() {
        try? FileManager.default.createDirectory(at: inProgressDirectory, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: manifestURL),
              let persisted = try? JSONDecoder().decode([PersistedJob].self, from: data) else { return }
        for entry in persisted {
            let job = DownloadJob(request: entry.request, id: entry.id)
            job.state = .paused
            job.downloadedBytes = downloadedBytesOnDisk(job)
            jobs.append(job)
        }
    }

    private func downloadedBytesOnDisk(_ job: DownloadJob) -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: job.tempDirectory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    private func persistQueue() {
        let pending = jobs
            .filter { !$0.state.isTerminal }
            .map { PersistedJob(id: $0.id, request: $0.request) }
        if pending.isEmpty {
            try? FileManager.default.removeItem(at: manifestURL)
            return
        }
        try? FileManager.default.createDirectory(at: inProgressDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(pending) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    var activeCount: Int {
        jobs.filter { $0.state == .downloading || $0.state == .queued || $0.state == .assembling }.count
    }

    // MARK: Controle público

    @discardableResult
    func enqueue(_ request: DownloadRequest) -> DownloadJob {
        let job = DownloadJob(request: request)
        jobs.append(job)
        persistQueue()
        start(job)
        return job
    }

    func start(_ job: DownloadJob) {
        // Concluído/cancelado não reinicia; falhou pode tentar de novo
        // (os pedaços já baixados ficam no disco e são reaproveitados).
        guard job.task == nil, job.state != .completed, job.state != .cancelled else { return }
        job.stopIntent = .none
        job.errorMessage = nil
        job.state = .downloading
        job.task = Task { [weak self, weak job] in
            guard let self, let job else { return }
            await self.run(job)
            job.task = nil
            self.persistQueue()
        }
    }

    func pause(_ job: DownloadJob) {
        job.stopIntent = .pause
        job.task?.cancel()
        if job.task == nil { job.state = .paused }
    }

    func cancel(_ job: DownloadJob) {
        job.stopIntent = .cancel
        job.task?.cancel()
        if job.task == nil {
            job.state = .cancelled
            cleanTemp(job)
        }
    }

    func remove(_ job: DownloadJob) {
        cancel(job)
        cleanTemp(job)
        jobs.removeAll { $0.id == job.id }
        persistQueue()
    }

    // MARK: Execução

    private func run(_ job: DownloadJob) async {
        do {
            if job.request.isHLS {
                try await runHLS(job)
            } else {
                try await runFile(job)
            }
        } catch is CancellationError {
            handleStop(job)
        } catch let error as URLError where error.code == .cancelled {
            handleStop(job)
        } catch {
            job.state = .failed
            job.errorMessage = (error as NSError).localizedDescription
            job.speedMBs = 0
        }
    }

    private func handleStop(_ job: DownloadJob) {
        job.speedMBs = 0
        if job.stopIntent == .cancel {
            job.state = .cancelled
            cleanTemp(job)
        } else {
            job.state = .paused
        }
        job.stopIntent = .none
    }

    // MARK: Arquivo direto com Range paralelo

    private func runFile(_ job: DownloadJob) async throws {
        let request = job.request
        guard let total = request.totalBytes, total > 0, request.supportsRange else {
            try await runStream(job)
            return
        }

        if job.pieces.isEmpty || job.pieces.reduce(0, { $0 + $1.size }) != total {
            job.pieces = Self.buildPieces(total: total, connections: request.connections)
            job.downloadedBytes = 0
        }
        job.totalBytes = total
        try createTempDirectory(job)

        // Retomada: pedaços já baixados por inteiro ficam no disco.
        for piece in job.pieces {
            let file = partFile(job, pieceID: piece.id)
            if let size = fileSize(file), size == piece.size {
                job.setPieceState(piece.id, .done)
                job.downloadedBytes += piece.size
            } else {
                job.setPieceState(piece.id, .pending)
            }
        }
        job.resetSampler()

        let pending = job.pieces.filter { $0.state != .done }
        if !pending.isEmpty {
            let url = request.mediaURL
            let limit = max(1, request.connections)
            let tempDir = job.tempDirectory
            let expectedSizes = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, $0.size) })
            // O corpo do TaskGroup não roda no MainActor: todo acesso ao job
            // (que é @MainActor) passa por MainActor.run.
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                var iterator = pending.makeIterator()
                var started = 0
                while started < limit, let piece = iterator.next() {
                    started += 1
                    let pieceID = piece.id
                    await MainActor.run { job.setPieceState(pieceID, .active) }
                    let start = piece.start
                    let end = piece.end
                    group.addTask {
                        (pieceID, try await DownloadTransport.fetchRange(url: url, start: start, end: end))
                    }
                }
                for try await (pieceID, data) in group {
                    guard let expected = expectedSizes[pieceID], Int64(data.count) == expected else {
                        throw URLError(.cannotDecodeContentData)
                    }
                    let partURL = tempDir.appendingPathComponent(String(format: "part-%04d", pieceID))
                    try data.write(to: partURL)
                    await MainActor.run {
                        job.setPieceState(pieceID, .done)
                        job.downloadedBytes += expected
                        job.refreshSpeed()
                    }
                    if let next = iterator.next() {
                        let nextID = next.id
                        await MainActor.run { job.setPieceState(nextID, .active) }
                        let start = next.start
                        let end = next.end
                        group.addTask {
                            (nextID, try await DownloadTransport.fetchRange(url: url, start: start, end: end))
                        }
                    }
                }
            }
        }

        if Task.isCancelled { throw CancellationError() }
        job.state = .assembling
        job.speedMBs = 0
        let item = try assembleFile(job, piecesInOrder: job.pieces.map { partFile(job, pieceID: $0.id) },
                                    expectedSize: total)
        job.resultItemID = item.id
        job.downloadedBytes = total
        job.state = .completed
        cleanTemp(job)
    }

    static func buildPieces(total: Int64, connections: Int) -> [Piece] {
        let target = max(1, connections) * 8
        var pieceSize = max(Int64(512 * 1024), total / Int64(target))
        var count = Int((total + pieceSize - 1) / pieceSize)
        if count > 512 {
            pieceSize = total / 512
            count = Int((total + pieceSize - 1) / pieceSize)
        }
        var pieces: [Piece] = []
        var start: Int64 = 0
        for index in 0..<count {
            let end = min(total - 1, start + pieceSize - 1)
            pieces.append(Piece(id: index, start: start, end: end))
            start = end + 1
        }
        return pieces
    }

    // MARK: Arquivo direto sem Range (download contínuo)

    private func runStream(_ job: DownloadJob) async throws {
        let request = job.request
        try createTempDirectory(job)
        // Sem Range não há retomada real: recomeça do zero (honesto).
        let partial = job.tempDirectory.appendingPathComponent("single.part")
        job.downloadedBytes = 0
        job.resetSampler()

        let downloader = StreamDownloader()
        downloader.onProgress = { [weak job] downloaded, total in
            Task { @MainActor in
                guard let job else { return }
                job.downloadedBytes = downloaded
                if let total { job.totalBytes = total }
                job.refreshSpeed()
            }
        }
        let downloadedFile = try await downloader.download(url: request.mediaURL, to: partial)
        if Task.isCancelled { throw CancellationError() }

        job.state = .assembling
        job.speedMBs = 0
        let size = fileSize(downloadedFile) ?? job.downloadedBytes
        let item = try moveToLibrary(job, source: downloadedFile, size: size)
        job.resultItemID = item.id
        job.state = .completed
        cleanTemp(job)
    }

    // MARK: HLS (segmentos .ts em paralelo, até 4 conexões)

    private func runHLS(_ job: DownloadJob) async throws {
        let request = job.request
        let playlist = try await DownloadTransport.fetchText(url: request.mediaURL)
        if playlist.contains("#EXT-X-KEY") && !playlist.contains("METHOD=NONE") {
            throw NSError(
                domain: "BaixaVideos", code: 10,
                userInfo: [NSLocalizedDescriptionKey:
                    "Este HLS é criptografado (EXT-X-KEY). Esta versão não descriptografa streams protegidos."]
            )
        }
        let segmentURLs = Self.parseSegmentURLs(playlist: playlist, baseURL: request.mediaURL)
        guard !segmentURLs.isEmpty else {
            throw URLError(.cannotParseResponse)
        }

        try createTempDirectory(job)
        if job.pieces.count != segmentURLs.count {
            job.pieces = segmentURLs.indices.map { Piece(id: $0, start: Int64($0), end: Int64($0)) }
            job.downloadedBytes = 0
        }
        job.totalBytes = nil
        for piece in job.pieces {
            let file = segmentFile(job, pieceID: piece.id)
            if let size = fileSize(file), size > 0 {
                job.setPieceState(piece.id, .done)
                job.downloadedBytes += size
            } else {
                job.setPieceState(piece.id, .pending)
            }
        }
        job.resetSampler()

        let pending = job.pieces.filter { $0.state != .done }
        if !pending.isEmpty {
            let limit = 4
            let tempDir = job.tempDirectory
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                var iterator = pending.makeIterator()
                var started = 0
                while started < limit, let piece = iterator.next() {
                    started += 1
                    let pieceID = piece.id
                    await MainActor.run { job.setPieceState(pieceID, .active) }
                    let segmentURL = segmentURLs[pieceID]
                    group.addTask {
                        (pieceID, try await DownloadTransport.fetchData(url: segmentURL))
                    }
                }
                for try await (pieceID, data) in group {
                    let segmentURLFile = tempDir.appendingPathComponent(String(format: "seg-%04d.ts", pieceID))
                    try data.write(to: segmentURLFile)
                    let byteCount = Int64(data.count)
                    await MainActor.run {
                        job.setPieceState(pieceID, .done)
                        job.downloadedBytes += byteCount
                        job.refreshSpeed()
                    }
                    if let next = iterator.next() {
                        let nextID = next.id
                        await MainActor.run { job.setPieceState(nextID, .active) }
                        let segmentURL = segmentURLs[nextID]
                        group.addTask {
                            (nextID, try await DownloadTransport.fetchData(url: segmentURL))
                        }
                    }
                }
            }
        }

        if Task.isCancelled { throw CancellationError() }
        job.state = .assembling
        job.speedMBs = 0
        let files = job.pieces.map { segmentFile(job, pieceID: $0.id) }
        let item = try await assembleHLS(job, segmentFiles: files)
        job.resultItemID = item.id
        job.state = .completed
        cleanTemp(job)
    }

    static func parseSegmentURLs(playlist: String, baseURL: URL) -> [URL] {
        var urls: [URL] = []
        for rawLine in playlist.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                urls.append(url)
            }
        }
        return urls
    }

    // MARK: Montagem e biblioteca

    private func assembleFile(_ job: DownloadJob, piecesInOrder: [URL], expectedSize: Int64?) throws -> LibraryItem {
        let ext = job.request.fileExtension
        let fileName = library.uniqueFileName(title: job.request.title, extension: ext)
        let destination = library.videosDirectory.appendingPathComponent(fileName)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var written: Int64 = 0
        for part in piecesInOrder {
            let input = try FileHandle(forReadingFrom: part)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
                written += Int64(chunk.count)
            }
        }
        if let expectedSize, written != expectedSize {
            try? FileManager.default.removeItem(at: destination)
            throw URLError(.cannotDecodeContentData)
        }
        let item = LibraryItem(
            id: UUID(),
            title: job.request.title,
            sourceURL: job.request.mediaURL.absoluteString,
            qualityLabel: job.request.qualityLabel,
            fileName: fileName,
            fileSize: written,
            createdAt: Date(),
            isHLS: job.request.isHLS
        )
        library.add(item)
        return item
    }

    /// Junta os segmentos .ts e converte o resultado pra .mp4 (remux, sem
    /// re-encodar: mesma qualidade, só troca o envelope), porque o .ts puro
    /// não abre nos players padrão do iPhone.
    private func assembleHLS(_ job: DownloadJob, segmentFiles: [URL]) async throws -> LibraryItem {
        let merged = job.tempDirectory.appendingPathComponent("merged.ts")
        var total: Int64 = 0
        FileManager.default.createFile(atPath: merged.path, contents: nil)
        let output = try FileHandle(forWritingTo: merged)
        do {
            for part in segmentFiles {
                let input = try FileHandle(forReadingFrom: part)
                while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                    total += Int64(chunk.count)
                }
                try? input.close()
            }
            try output.close()
        } catch {
            try? output.close()
            throw error
        }

        let mp4Name = library.uniqueFileName(title: job.request.title, extension: "mp4")
        let mp4URL = library.videosDirectory.appendingPathComponent(mp4Name)
        if await remuxToMP4(source: merged, destination: mp4URL) {
            let item = LibraryItem(
                id: UUID(),
                title: job.request.title,
                sourceURL: job.request.mediaURL.absoluteString,
                qualityLabel: job.request.qualityLabel,
                fileName: mp4Name,
                fileSize: fileSize(mp4URL) ?? total,
                createdAt: Date(),
                isHLS: true
            )
            library.add(item)
            return item
        }

        // Conversão falhou: guarda o .ts mesmo (abre em players como o VLC)
        // em vez de perder o download.
        let tsName = library.uniqueFileName(title: job.request.title, extension: "ts")
        let tsURL = library.videosDirectory.appendingPathComponent(tsName)
        try FileManager.default.moveItem(at: merged, to: tsURL)
        let item = LibraryItem(
            id: UUID(),
            title: job.request.title,
            sourceURL: job.request.mediaURL.absoluteString,
            qualityLabel: job.request.qualityLabel,
            fileName: tsName,
            fileSize: total,
            createdAt: Date(),
            isHLS: true
        )
        library.add(item)
        return item
    }

    /// Remux .ts → .mp4. Primeira tentativa: passthrough (sem re-encodar,
    /// rápido). O resultado é VALIDADO de verdade (abre? tem vídeo? tem
    /// duração?) — passthrough de certos conteúdos gera um .mp4 que o
    /// player abre preto/dá erro. Se não validar, segunda tentativa com
    /// re-encode (H.264/AAC), que conserta o arquivo.
    private func remuxToMP4(source: URL, destination: URL) async -> Bool {
        // Primeiro o remuxador interno: o AVFoundation não lê vários
        // .ts locais (a exportação falha e o player abre 0:00).
        if await TSRemuxer.remux(source: source, destination: destination),
           await isPlayableFile(destination) {
            return true
        }
        try? FileManager.default.removeItem(at: destination)
        if await exportMP4(source: source, destination: destination,
                           preset: AVAssetExportPresetPassthrough),
           await isPlayableFile(destination) {
            return true
        }
        try? FileManager.default.removeItem(at: destination)
        if await exportMP4(source: source, destination: destination,
                           preset: AVAssetExportPresetHighestQuality),
           await isPlayableFile(destination) {
            return true
        }
        try? FileManager.default.removeItem(at: destination)
        return false
    }

    private func exportMP4(source: URL, destination: URL, preset: String) async -> Bool {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            return false
        }
        session.outputURL = destination
        session.outputFileType = .mp4
        await withCheckedContinuation { continuation in
            session.exportAsynchronously { continuation.resume() }
        }
        return session.status == .completed
    }

    /// Um .mp4 só é aceito se o AVFoundation confirma: é tocável, tem
    /// faixa de vídeo e tem duração.
    private func isPlayableFile(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let playable = try? await asset.load(.isPlayable), playable else { return false }
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              !tracks.isEmpty else { return false }
        guard let duration = try? await asset.load(.duration) else { return false }
        return duration.seconds > 0
    }

    private func moveToLibrary(_ job: DownloadJob, source: URL, size: Int64) throws -> LibraryItem {
        let ext = job.request.fileExtension
        let fileName = library.uniqueFileName(title: job.request.title, extension: ext)
        let destination = library.videosDirectory.appendingPathComponent(fileName)
        try FileManager.default.moveItem(at: source, to: destination)
        let item = LibraryItem(
            id: UUID(),
            title: job.request.title,
            sourceURL: job.request.mediaURL.absoluteString,
            qualityLabel: job.request.qualityLabel,
            fileName: fileName,
            fileSize: size,
            createdAt: Date(),
            isHLS: job.request.isHLS
        )
        library.add(item)
        return item
    }

    // MARK: Arquivos temporários

    private func createTempDirectory(_ job: DownloadJob) throws {
        try FileManager.default.createDirectory(at: job.tempDirectory, withIntermediateDirectories: true)
    }

    private func partFile(_ job: DownloadJob, pieceID: Int) -> URL {
        job.tempDirectory.appendingPathComponent(String(format: "part-%04d", pieceID))
    }

    private func segmentFile(_ job: DownloadJob, pieceID: Int) -> URL {
        job.tempDirectory.appendingPathComponent(String(format: "seg-%04d.ts", pieceID))
    }

    private func cleanTemp(_ job: DownloadJob) {
        try? FileManager.default.removeItem(at: job.tempDirectory)
    }

    private func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }
}

// MARK: - Download contínuo com delegate (fallback sem Range)

final class StreamDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var onProgress: ((Int64, Int64?) -> Void)?

    private var continuation: CheckedContinuation<URL, Error>?
    private var dataTask: URLSessionDataTask?
    private var session: URLSession?
    private var fileHandle: FileHandle?
    private var destination: URL?
    private var downloaded: Int64 = 0
    private var expectedTotal: Int64?
    private var lastReported: Int64 = 0

    func download(url: URL, to destination: URL) async throws -> URL {
        self.destination = destination
        try? FileManager.default.removeItem(at: destination)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: destination)
        downloaded = 0
        lastReported = 0
        expectedTotal = nil
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                self.continuation = continuation
                let task = session.dataTask(with: DownloadTransport.makeRequest(url: url))
                self.dataTask = task
                task.resume()
            }
        } onCancel: {
            self.dataTask?.cancel()
        }
    }

    private func finish(returning url: URL) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: url)
    }

    private func finish(throwing error: Error) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            completionHandler(.cancel)
            finish(throwing: URLError(.badServerResponse))
            return
        }
        if response.expectedContentLength > 0 {
            expectedTotal = response.expectedContentLength
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try fileHandle?.write(contentsOf: data)
        } catch {
            dataTask.cancel()
            finish(throwing: error)
            return
        }
        downloaded += Int64(data.count)
        if downloaded - lastReported >= 262_144 {
            lastReported = downloaded
            onProgress?(downloaded, expectedTotal)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? fileHandle?.close()
        fileHandle = nil
        session.finishTasksAndInvalidate()
        if let error {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                finish(throwing: CancellationError())
            } else {
                finish(throwing: error)
            }
            return
        }
        onProgress?(downloaded, expectedTotal)
        if let destination {
            finish(returning: destination)
        } else {
            finish(throwing: URLError(.unknown))
        }
    }
}
