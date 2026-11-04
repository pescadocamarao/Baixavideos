import Foundation

/// Biblioteca: arquivos em Documents/Videos + metadados em library.json
/// no mesmo diretório. Sem banco externo, sem tracking.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []

    let videosDirectory: URL
    private let metadataURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        videosDirectory = documents.appendingPathComponent("Videos", isDirectory: true)
        metadataURL = videosDirectory.appendingPathComponent("library.json")
        try? FileManager.default.createDirectory(at: videosDirectory, withIntermediateDirectories: true)
        load()
    }

    func url(for item: LibraryItem) -> URL {
        videosDirectory.appendingPathComponent(item.fileName)
    }

    func fileExists(_ item: LibraryItem) -> Bool {
        FileManager.default.fileExists(atPath: url(for: item).path)
    }

    func add(_ item: LibraryItem) {
        items.insert(item, at: 0)
        save()
    }

    func delete(_ item: LibraryItem) {
        try? FileManager.default.removeItem(at: url(for: item))
        items.removeAll { $0.id == item.id }
        save()
    }

    /// Renomeia o título e o arquivo físico (mantém a extensão).
    func rename(_ item: LibraryItem, to newTitle: String) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ext = (items[index].fileName as NSString).pathExtension
        let currentName = items[index].fileName
        let baseName = "\(Self.sanitizeFileName(trimmed)).\(ext)"
        var newName = baseName
        if baseName != currentName {
            newName = uniqueFileName(title: trimmed, extension: ext)
            try? FileManager.default.moveItem(
                at: videosDirectory.appendingPathComponent(currentName),
                to: videosDirectory.appendingPathComponent(newName)
            )
        }
        items[index].title = trimmed
        items[index].fileName = newName
        save()
    }

    /// Gera um nome de arquivo único dentro de Documents/Videos.
    func uniqueFileName(title: String, extension ext: String) -> String {
        let base = Self.sanitizeFileName(title)
        var candidate = "\(base).\(ext)"
        var counter = 2
        while FileManager.default.fileExists(atPath: videosDirectory.appendingPathComponent(candidate).path) {
            candidate = "\(base) \(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    static func sanitizeFileName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = trimmed.unicodeScalars
            .map { invalid.contains($0) ? "-" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "video" : String(cleaned.prefix(80))
    }

    // MARK: Persistência

    private func load() {
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder.library.decode([LibraryItem].self, from: data) else {
            items = []
            return
        }
        items = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func save() {
        guard let data = try? JSONEncoder.library.encode(items) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }
}

extension JSONEncoder {
    static var library: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var library: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
