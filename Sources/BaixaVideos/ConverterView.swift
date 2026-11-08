import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Remux .ts → .mp4 (mesma receita do motor de download)

/// Remux com passthrough: troca só o envelope (.ts → .mp4), sem
/// re-encodar — mesma qualidade, conversão rápida.
enum Remuxer {
    static func remuxToMP4(source: URL, destination: URL) async -> Bool {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough
        ) else { return false }
        session.outputURL = destination
        session.outputFileType = .mp4
        await withCheckedContinuation { continuation in
            session.exportAsynchronously { continuation.resume() }
        }
        if session.status == .completed { return true }
        try? FileManager.default.removeItem(at: destination)
        return false
    }
}

// MARK: - Tela do conversor M3U8/TS → MP4

struct ConverterView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @Binding var selectedTab: ContentView.AppTab

    @State private var linkText = ""
    @State private var isConvertingLink = false
    @State private var convertingItemID: UUID?
    @State private var isImporting = false
    @State private var showImporter = false
    @State private var statusMessage: String?

    private var tsItems: [LibraryItem] {
        library.items.filter {
            ($0.fileName as NSString).pathExtension.lowercased() == "ts"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Converter")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)

                linkSection
                librarySection
                importSection

                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundColor(Theme.textDim)
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: Self.importTypes,
            allowsMultipleSelection: false,
            onCompletion: handleImport
        )
    }

    private static var importTypes: [UTType] {
        var types: [UTType] = [.movie, .video]
        if let ts = UTType(filenameExtension: "ts") { types.append(ts) }
        return types
    }

    // MARK: Link .m3u8

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Link .m3u8", systemImage: "link")
                .font(.headline)
                .foregroundColor(Theme.textPrimary)
            HStack(spacing: 10) {
                TextField("https://…/video.m3u8", text: $linkText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .padding(12)
                    .background(Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .foregroundColor(Theme.textPrimary)
                Button {
                    convertLink()
                } label: {
                    if isConvertingLink {
                        ProgressView().tint(Theme.lime)
                    } else {
                        Text("Converter")
                            .fontWeight(.semibold)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Theme.lime)
                .foregroundColor(.black)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .disabled(isConvertingLink || linkText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("O vídeo entra na fila de Downloads e chega na Biblioteca já em .mp4.")
                .font(.footnote)
                .foregroundColor(Theme.textDim)
        }
    }

    private func convertLink() {
        let raw = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            statusMessage = "Cola um link .m3u8 válido."
            return
        }
        isConvertingLink = true
        Task {
            defer { isConvertingLink = false }
            do {
                let probe = try await ProbeService.probe(url: url)
                guard probe.kind != .file else {
                    statusMessage = "Esse link já é um arquivo de vídeo pronto — baixa ele na aba Baixar."
                    return
                }
                let best = probe.variants.max {
                    ($0.height ?? 0, $0.bandwidth) < ($1.height ?? 0, $1.bandwidth)
                }
                let request = DownloadRequest(
                    title: probe.suggestedTitle,
                    mediaURL: best?.url ?? probe.finalURL,
                    isHLS: true,
                    qualityLabel: best?.label ?? "HLS",
                    connections: 8,
                    totalBytes: nil,
                    supportsRange: false,
                    fileExtension: "mp4"
                )
                let job = downloads.enqueue(request)
                downloads.start(job)
                statusMessage = "Convertendo “\(probe.suggestedTitle)” — acompanha na aba Downloads."
                selectedTab = .queue
            } catch {
                statusMessage = "Não consegui analisar esse link. Confere o endereço e tenta de novo."
            }
        }
    }

    // MARK: .ts já na Biblioteca

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Arquivos .ts na Biblioteca", systemImage: "film.stack")
                .font(.headline)
                .foregroundColor(Theme.textPrimary)
            if tsItems.isEmpty {
                Text("Nenhum .ts por aqui — tudo já está em .mp4.")
                    .font(.footnote)
                    .foregroundColor(Theme.textDim)
            } else {
                ForEach(tsItems) { item in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)
                            Text(ByteCountFormatter.string(
                                fromByteCount: item.fileSize, countStyle: .file))
                                .font(.caption)
                                .foregroundColor(Theme.textDim)
                        }
                        Spacer()
                        Button {
                            convertLibraryItem(item)
                        } label: {
                            if convertingItemID == item.id {
                                ProgressView().tint(Theme.lime)
                            } else {
                                Label("MP4", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.panel)
                        .foregroundColor(Theme.lime)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .disabled(convertingItemID != nil)
                    }
                    .padding(12)
                    .background(Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func convertLibraryItem(_ item: LibraryItem) {
        convertingItemID = item.id
        Task {
            defer { convertingItemID = nil }
            let source = library.url(for: item)
            let name = library.uniqueFileName(title: item.title, extension: "mp4")
            let destination = library.videosDirectory.appendingPathComponent(name)
            if await Remuxer.remuxToMP4(source: source, destination: destination) {
                library.markConverted(item, newFileName: name, newSize: fileSize(destination) ?? item.fileSize)
                statusMessage = "“\(item.title)” convertido pra .mp4."
            } else {
                statusMessage = "Não consegui converter “\(item.title)”. O .ts continua na Biblioteca (abre no VLC)."
            }
        }
    }

    // MARK: Importar do app Arquivos

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Importar arquivo", systemImage: "square.and.arrow.down")
                .font(.headline)
                .foregroundColor(Theme.textPrimary)
            Button {
                showImporter = true
            } label: {
                HStack {
                    if isImporting {
                        ProgressView().tint(Theme.lime)
                    } else {
                        Image(systemName: "doc.badge.plus")
                    }
                    Text("Escolher .ts ou vídeo no Arquivos")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .background(Theme.panel)
            .foregroundColor(Theme.lime)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .disabled(isImporting)
            Text("Um .ts de outro app vira .mp4 na Biblioteca; um vídeo pronto entra como está.")
                .font(.footnote)
                .foregroundColor(Theme.textDim)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let source = urls.first else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            let ext = source.pathExtension.lowercased()
            let title = (source.lastPathComponent as NSString).deletingPathExtension
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + (ext.isEmpty ? "ts" : ext))
            do {
                try FileManager.default.copyItem(at: source, to: staging)
            } catch {
                statusMessage = "Não consegui ler esse arquivo do Arquivos."
                return
            }
            defer { try? FileManager.default.removeItem(at: staging) }

            if ext == "ts" {
                let name = library.uniqueFileName(title: title, extension: "mp4")
                let destination = library.videosDirectory.appendingPathComponent(name)
                if await Remuxer.remuxToMP4(source: staging, destination: destination) {
                    library.add(LibraryItem(
                        id: UUID(), title: title, sourceURL: "importado",
                        qualityLabel: "Convertido", fileName: name,
                        fileSize: fileSize(destination) ?? 0,
                        createdAt: Date(), isHLS: true
                    ))
                    statusMessage = "“\(title)” convertido e salvo na Biblioteca."
                } else {
                    let tsName = library.uniqueFileName(title: title, extension: "ts")
                    let tsDestination = library.videosDirectory.appendingPathComponent(tsName)
                    try? FileManager.default.copyItem(at: staging, to: tsDestination)
                    library.add(LibraryItem(
                        id: UUID(), title: title, sourceURL: "importado",
                        qualityLabel: "TS", fileName: tsName,
                        fileSize: fileSize(tsDestination) ?? 0,
                        createdAt: Date(), isHLS: true
                    ))
                    statusMessage = "Não deu pra converter — guardei o .ts na Biblioteca (abre no VLC)."
                }
            } else {
                let finalExt = ext.isEmpty ? "mp4" : ext
                let name = library.uniqueFileName(title: title, extension: finalExt)
                let destination = library.videosDirectory.appendingPathComponent(name)
                do {
                    try FileManager.default.copyItem(at: staging, to: destination)
                    library.add(LibraryItem(
                        id: UUID(), title: title, sourceURL: "importado",
                        qualityLabel: "Importado", fileName: name,
                        fileSize: fileSize(destination) ?? 0,
                        createdAt: Date(), isHLS: false
                    ))
                    statusMessage = "“\(title)” importado pra Biblioteca."
                } catch {
                    statusMessage = "Não consegui importar esse arquivo."
                }
            }
        }
    }

    private func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }
}
