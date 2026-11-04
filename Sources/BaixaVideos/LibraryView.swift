import SwiftUI
import AVFoundation
import UIKit

// MARK: - Miniaturas dos vídeos (geradas do próprio arquivo)

actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [String: UIImage] = [:]

    func thumbnail(for url: URL) async -> UIImage? {
        let key = url.path
        if let cached = cache[key] { return cached }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        if let cgImage = try? generator.copyCGImage(
            at: CMTime(seconds: 2, preferredTimescale: 600), actualTime: nil) {
            let image = UIImage(cgImage: cgImage)
            cache[key] = image
            return image
        }
        return nil
    }
}

struct VideoThumbnail: View {
    let url: URL

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(white: 0.10)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.textDim)
            }
        }
        .frame(width: 92, height: 58)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: url) {
            image = await ThumbnailCache.shared.thumbnail(for: url)
        }
    }
}

// MARK: - Biblioteca

enum LibrarySort: String, CaseIterable {
    case date = "Data"
    case name = "Nome"
    case size = "Tamanho"
}

enum LibraryFilter: String, CaseIterable {
    case all = "Todos"
    case mp4 = "MP4"
    case hls = "HLS"
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore

    @State private var searchText = ""
    @State private var sort: LibrarySort = .date
    @State private var ascending = false
    @State private var filter: LibraryFilter = .all
    @State private var playerTarget: LibraryItem?
    @State private var shareItem: ShareSheetItem?
    @State private var renameTarget: LibraryItem?
    @State private var renameText = ""
    @State private var deleteTarget: LibraryItem?

    private var visibleItems: [LibraryItem] {
        var result = library.items
        if !searchText.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(searchText)
            }
        }
        switch filter {
        case .all: break
        case .mp4: result = result.filter { $0.fileName.lowercased().hasSuffix(".mp4") }
        case .hls: result = result.filter { $0.isHLS }
        }
        switch sort {
        case .date:
            result.sort { ascending ? $0.createdAt < $1.createdAt : $0.createdAt > $1.createdAt }
        case .name:
            result.sort {
                ascending
                    ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending
            }
        case .size:
            result.sort { ascending ? $0.fileSize < $1.fileSize : $0.fileSize > $1.fileSize }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Group {
                if visibleItems.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 44))
                            .foregroundColor(Theme.textDim)
                        Text(library.items.isEmpty ? "Nenhum vídeo baixado" : "Nada encontrado")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundColor(Theme.textDim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(visibleItems) { item in
                            row(item)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(Theme.background)
            .navigationTitle("Biblioteca")
            .searchable(text: $searchText, prompt: "Buscar")
            .toolbar { toolbarContent }
            .fullScreenCover(item: $playerTarget) { item in
                PlayerScreen(url: library.url(for: item), title: item.title, isRemote: false)
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(items: [item.url])
            }
            .alert("Renomear", isPresented: renamePresented) {
                TextField("Título", text: $renameText)
                Button("Cancelar", role: .cancel) { renameTarget = nil }
                Button("Salvar") {
                    if let target = renameTarget {
                        library.rename(target, to: renameText)
                    }
                    renameTarget = nil
                }
            }
            .alert("Apagar vídeo?", isPresented: deletePresented) {
                Button("Cancelar", role: .cancel) { deleteTarget = nil }
                Button("Apagar", role: .destructive) {
                    if let target = deleteTarget { library.delete(target) }
                    deleteTarget = nil
                }
            } message: {
                if let target = deleteTarget {
                    Text(target.title)
                }
            }
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Ordenar", selection: $sort) {
                    ForEach(LibrarySort.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                Button {
                    ascending.toggle()
                } label: {
                    Label(ascending ? "Crescente" : "Decrescente",
                          systemImage: ascending ? "arrow.up" : "arrow.down")
                }
                Divider()
                Picker("Filtrar", selection: $filter) {
                    ForEach(LibraryFilter.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundColor(Theme.lime)
            }
        }
    }

    private func row(_ item: LibraryItem) -> some View {
        Button {
            if library.fileExists(item) { playerTarget = item }
        } label: {
            HStack(spacing: 12) {
                VideoThumbnail(url: library.url(for: item))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(item.qualityLabel)
                            .font(.system(.caption2, design: .monospaced).weight(.bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.lime)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Text(Format.bytes(item.fileSize))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(Theme.textDim)
                        Text("·")
                            .foregroundColor(Theme.textDim)
                        Text(Format.date(item.createdAt))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(Theme.textDim)
                    }
                    if !library.fileExists(item) {
                        Text("Arquivo não encontrado")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(Theme.danger)
                    }
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(Theme.lime)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.panel)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { deleteTarget = item } label: {
                Label("Apagar", systemImage: "trash")
            }
            Button {
                shareItem = ShareSheetItem(url: library.url(for: item))
            } label: {
                Label("Compartilhar", systemImage: "square.and.arrow.up")
            }
            .tint(Theme.lime)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                renameText = item.title
                renameTarget = item
            } label: {
                Label("Renomear", systemImage: "pencil")
            }
            .tint(.gray)
        }
        .contextMenu {
            Button {
                if library.fileExists(item) { playerTarget = item }
            } label: {
                Label("Assistir", systemImage: "play.fill")
            }
            Button {
                shareItem = ShareSheetItem(url: library.url(for: item))
            } label: {
                Label("Compartilhar", systemImage: "square.and.arrow.up")
            }
            Button {
                renameText = item.title
                renameTarget = item
            } label: {
                Label("Renomear", systemImage: "pencil")
            }
            Button(role: .destructive) { deleteTarget = item } label: {
                Label("Apagar", systemImage: "trash")
            }
        }
    }
}
