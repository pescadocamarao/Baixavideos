import SwiftUI
import AVKit
import UIKit

/// Versão real do app instalado, lida do pacote — pra ele sempre saber
/// qual versão está rodando (a UI não mostrava e gerava confusão).
enum AppInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }
    static var versionLabel: String { "BaixaVídeos v\(version)" }
}

// MARK: - Raiz (abas)

struct ContentView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @State private var tab: AppTab = .download

    enum AppTab {
        case download
        case queue
        case library
        case converter
    }

    var body: some View {
        TabView(selection: $tab) {
            DownloadScreen(selectedTab: $tab)
                .tabItem { Label("Baixar", systemImage: "arrow.down.circle.fill") }
                .tag(AppTab.download)

            QueueScreen()
                .tabItem { Label("Downloads", systemImage: "tray.and.arrow.down.fill") }
                .tag(AppTab.queue)
                .badge(downloads.activeCount)

            LibraryView()
                .tabItem { Label("Biblioteca", systemImage: "film.stack") }
                .tag(AppTab.library)

            ConverterView(selectedTab: $tab)
                .tabItem { Label("Converter", systemImage: "arrow.triangle.2.circlepath") }
                .tag(AppTab.converter)
        }
        .tint(Theme.lime)
    }
}

// MARK: - Tela de download

struct DownloadScreen: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @Binding var selectedTab: ContentView.AppTab

    @State private var urlText = ""
    @State private var probe: ProbeResult?
    @State private var selectedVariantID: UUID?
    @State private var title = ""
    @State private var connections = 8
    @State private var isAnalyzing = false
    @State private var analyzeError: String?
    @State private var previewPlayer: AVPlayer?
    @State private var showFullPlayer = false
    @FocusState private var activeField: Field?

    private enum Field {
        case url
        case title
    }

    private let connectionOptions = [1, 4, 8, 16]

    private var selectedVariant: HLSVariant? {
        probe?.variants.first { $0.id == selectedVariantID }
    }

    private var selectedMediaURL: URL? {
        guard let probe else { return nil }
        if probe.kind == .hlsMaster, let variant = selectedVariant {
            return variant.url
        }
        return probe.finalURL
    }

    private var qualityLabel: String {
        guard let probe else { return "—" }
        switch probe.kind {
        case .hlsMaster: return selectedVariant?.label ?? "Original"
        case .hlsMedia: return "Original"
        case .file: return "Original"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    urlCard
                    if let probe { resultSection(probe) }
                    Text(AppInfo.versionLabel)
                        .font(.caption2)
                        .foregroundColor(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("BaixaVídeos")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Concluir") { activeField = nil }
                        .font(.system(.subheadline, design: .monospaced).weight(.bold))
                }
            }
            .fullScreenCover(isPresented: $showFullPlayer) {
                if let mediaURL = selectedMediaURL {
                    PlayerScreen(
                        url: mediaURL,
                        title: title.isEmpty ? (probe?.suggestedTitle ?? "Vídeo") : title,
                        isRemote: true
                    )
                }
            }
            .onChange(of: selectedVariantID) { _ in refreshPreview() }
        }
    }

    // MARK: URL

    private var urlCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundColor(Theme.textDim)
                TextField("https://…", text: $urlText)
                    .font(.system(.subheadline, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($activeField, equals: .url)
                    .submitLabel(.go)
                    .onSubmit { Task { await analyze() } }
                if !urlText.isEmpty {
                    Button {
                        urlText = ""
                        probe = nil
                        previewPlayer = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Theme.textDim)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(Color(white: 0.10))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 10) {
                Button {
                    if let pasted = UIPasteboard.general.string {
                        urlText = pasted
                    }
                } label: {
                    Label("Colar", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(GhostButtonStyle())

                Button {
                    Task { await analyze() }
                } label: {
                    if isAnalyzing {
                        HStack(spacing: 8) {
                            ProgressView().tint(.black)
                            Text("Analisando…")
                        }
                    } else {
                        Label("Analisar", systemImage: "magnifyingglass")
                    }
                }
                .buttonStyle(LimeButtonStyle())
                .disabled(isAnalyzing || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let analyzeError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(analyzeError)
                        .font(.system(.footnote, design: .monospaced))
                }
                .foregroundColor(Theme.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .panelCard()
    }

    // MARK: Resultado da análise

    private func resultSection(_ probe: ProbeResult) -> some View {
        VStack(spacing: 16) {
            if let mediaURL = selectedMediaURL {
                ZStack(alignment: .bottomTrailing) {
                    if let previewPlayer {
                        VideoPlayer(player: previewPlayer)
                            .frame(height: 216)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(white: 0.08))
                            .frame(height: 216)
                    }
                    Button { showFullPlayer = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.black)
                            .padding(8)
                            .background(Theme.lime)
                            .clipShape(Circle())
                    }
                    .padding(10)
                }
                .id(mediaURL)
            }

            HStack(spacing: 10) {
                Image(systemName: "pencil")
                    .foregroundColor(Theme.textDim)
                TextField("Título", text: $title)
                    .font(.system(.subheadline, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($activeField, equals: .title)
            }
            .padding(12)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.panelBorder, lineWidth: 1)
            )

            if probe.kind == .hlsMaster {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(probe.variants) { variant in
                            chip(
                                label: variant.label,
                                selected: variant.id == selectedVariantID,
                                icon: variant.id == selectedVariantID ? "checkmark.circle.fill" : nil
                            ) {
                                selectedVariantID = variant.id
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textDim)
                ForEach(connectionOptions, id: \.self) { option in
                    chip(label: "\(option)x", selected: connections == option, icon: nil) {
                        connections = option
                    }
                }
            }

            HStack(spacing: 10) {
                Label(probe.kind == .file ? "Arquivo" : "HLS",
                      systemImage: probe.kind == .file ? "doc.fill" : "list.bullet.rectangle.fill")
                Text("·")
                Text(probe.contentType ?? probe.fileExtension.uppercased())
                if let length = probe.contentLength {
                    Text("·")
                    Text(Format.bytes(length))
                }
                if let segments = probe.segmentCount {
                    Text("·")
                    Text("\(segments) segmentos")
                }
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(Theme.textDim)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Button { showFullPlayer = true } label: {
                    Label("Assistir", systemImage: "play.fill")
                        .font(.system(.subheadline, design: .monospaced).weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .background(Theme.panel)
                .foregroundColor(Theme.lime)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Theme.panelBorder, lineWidth: 1)
                )

                Button { enqueueDownload() } label: {
                    Label("Baixar", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(LimeButtonStyle())
            }
        }
    }

    private func chip(label: String, selected: Bool, icon: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 12, weight: .bold))
                }
                Text(label)
                    .font(.system(.subheadline, design: .monospaced).weight(.bold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? Theme.lime : Color(white: 0.13))
            .foregroundColor(selected ? .black : Theme.textPrimary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Ações

    private func refreshPreview() {
        guard let mediaURL = selectedMediaURL else {
            previewPlayer = nil
            return
        }
        previewPlayer?.pause()
        previewPlayer = AVPlayer(url: mediaURL)
    }

    private func analyze() async {
        activeField = nil
        var raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw) else {
            analyzeError = "URL inválida."
            return
        }
        isAnalyzing = true
        analyzeError = nil
        defer { isAnalyzing = false }
        do {
            let result = try await ProbeService.probe(url: url)
            probe = result
            title = result.suggestedTitle
            if result.kind == .hlsMaster {
                selectedVariantID = result.variants.max(by: {
                    ($0.height ?? 0, $0.bandwidth) < ($1.height ?? 0, $1.bandwidth)
                })?.id
            } else {
                selectedVariantID = nil
            }
            refreshPreview()
        } catch {
            probe = nil
            previewPlayer = nil
            analyzeError = "Não consegui analisar: \((error as NSError).localizedDescription)"
        }
    }

    private func enqueueDownload() {
        guard let probe, let mediaURL = selectedMediaURL else { return }
        activeField = nil
        let isHLS = probe.kind != .file
        var finalTitle = title.trimmingCharacters(in: .whitespaces)
        if finalTitle.isEmpty { finalTitle = probe.suggestedTitle }
        if finalTitle == probe.suggestedTitle, probe.kind == .hlsMaster,
           let height = selectedVariant?.height {
            finalTitle += " \(height)p"
        }
        let request = DownloadRequest(
            title: finalTitle,
            mediaURL: mediaURL,
            isHLS: isHLS,
            qualityLabel: qualityLabel,
            connections: connections,
            totalBytes: isHLS ? nil : probe.contentLength,
            supportsRange: probe.supportsRange,
            fileExtension: probe.fileExtension
        )
        downloads.enqueue(request)
        selectedTab = .queue
    }
}

// MARK: - Tela de downloads (fila)

struct QueueScreen: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @State private var playerItem: LibraryItem?

    var body: some View {
        NavigationStack {
            Group {
                if downloads.jobs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 44))
                            .foregroundColor(Theme.textDim)
                        Text("Nenhum download")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundColor(Theme.textDim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(downloads.jobs) { job in
                                JobCard(job: job) { item in
                                    playerItem = item
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .background(Theme.background)
            .navigationTitle("Downloads")
            .fullScreenCover(item: $playerItem) { item in
                PlayerScreen(url: library.url(for: item), title: item.title, isRemote: false)
            }
        }
    }
}

struct JobCard: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject var job: DownloadJob
    var onWatch: (LibraryItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                statusIcon
                Text(job.title)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                Spacer()
                Text(job.state.label)
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .foregroundColor(job.state == .failed ? Theme.danger : Theme.textDim)
            }

            ProgressView(value: job.progress)
                .tint(Theme.lime)

            HStack(spacing: 8) {
                Text("\(Int(job.progress * 100))%")
                    .foregroundColor(Theme.lime)
                    .fontWeight(.bold)
                if job.state == .downloading {
                    Text(Format.speed(job.speedMBs))
                    Text("· ETA \(Format.eta(job.etaSeconds))")
                }
                Text(Format.bytes(job.downloadedBytes))
                if let total = job.totalBytes {
                    Text("/ \(Format.bytes(total))")
                }
                if job.request.isHLS, !job.pieces.isEmpty {
                    Text("· \(job.pieces.filter { $0.state == .done }.count)/\(job.pieces.count) seg")
                }
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(Theme.textDim)

            if let error = job.errorMessage, job.state == .failed {
                Text(error)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(Theme.danger)
                    .lineLimit(3)
            }

            HStack(spacing: 10) {
                Spacer()
                if job.state == .downloading || job.state == .assembling {
                    iconButton("pause.fill") { downloads.pause(job) }
                }
                if job.state == .paused || job.state == .failed || job.state == .queued {
                    iconButton("play.fill", lime: true) { downloads.start(job) }
                }
                if job.state == .completed, let itemID = job.resultItemID,
                   let item = library.items.first(where: { $0.id == itemID }) {
                    iconButton("play.circle.fill", lime: true) { onWatch(item) }
                }
                if !job.state.isTerminal {
                    iconButton("xmark") { downloads.cancel(job) }
                }
                iconButton("trash") { downloads.remove(job) }
            }
        }
        .panelCard()
    }

    private var statusIcon: some View {
        Group {
            switch job.state {
            case .downloading, .assembling:
                Image(systemName: "arrow.down.circle.fill").foregroundColor(Theme.lime)
            case .paused:
                Image(systemName: "pause.circle.fill").foregroundColor(Theme.textDim)
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.lime)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundColor(Theme.danger)
            case .cancelled:
                Image(systemName: "xmark.circle.fill").foregroundColor(Theme.textDim)
            case .queued:
                Image(systemName: "clock.fill").foregroundColor(Theme.textDim)
            }
        }
        .font(.system(size: 18))
    }

    private func iconButton(_ systemName: String, lime: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(lime ? .black : Theme.textPrimary)
                .frame(width: 38, height: 32)
                .background(lime ? Theme.lime : Color(white: 0.14))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
