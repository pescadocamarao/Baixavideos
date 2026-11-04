import SwiftUI
import AVKit
import UIKit

struct PlayerSheetItem: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

struct ShareSheetItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ContentView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager

    @State private var urlText = ""
    @State private var probe: ProbeResult?
    @State private var selectedVariantID: UUID?
    @State private var title = ""
    @State private var connections = 8
    @State private var isAnalyzing = false
    @State private var analyzeError: String?
    @State private var queueExpanded = false
    @State private var playerItem: PlayerSheetItem?
    @State private var shareItem: ShareSheetItem?

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
        case .hlsMaster:
            return selectedVariant?.label ?? "Original"
        case .hlsMedia:
            return "Original (HLS)"
        case .file:
            return "Original"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    stepAnalyze
                    stepWatch
                    stepQuality
                    stepDownload
                    librarySection
                }
                .padding(12)
            }
            .background(Theme.background)
            .navigationTitle("BaixaVídeos")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                QueueBar(expanded: $queueExpanded)
            }
        }
        .sheet(item: $playerItem) { item in
            PlayerView(url: item.url, title: item.title)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
    }

    // MARK: 01 · Analisar

    private var stepAnalyze: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepHeader(number: "01", title: "Analisar link")
            TextField("Cole a URL direta (.mp4, .mov, .webm, .m3u8)", text: $urlText)
                .font(.system(.subheadline, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(10)
                .background(Color(white: 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 10) {
                Button {
                    if let pasted = UIPasteboard.general.string {
                        urlText = pasted
                    }
                } label: {
                    Text("Colar")
                }
                .buttonStyle(GhostButtonStyle())

                Button {
                    Task { await analyze() }
                } label: {
                    Text(isAnalyzing ? "Analisando…" : "Analisar")
                }
                .buttonStyle(LimeButtonStyle())
                .disabled(isAnalyzing || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let analyzeError {
                Text(analyzeError)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(Theme.danger)
            }
            if let probe {
                VStack(alignment: .leading, spacing: 3) {
                    infoRow("TIPO", probe.kind == .file ? "Arquivo direto" : (probe.kind == .hlsMaster ? "HLS (várias qualidades)" : "HLS (qualidade única)"))
                    infoRow("FORMATO", probe.contentType ?? probe.fileExtension.uppercased())
                    infoRow("TAMANHO", Format.bytes(probe.contentLength))
                    if probe.kind == .file {
                        infoRow("RANGE", probe.supportsRange ? "SIM (paralelo)" : "NÃO (contínuo)")
                    }
                    if let segments = probe.segmentCount {
                        infoRow("SEGMENTOS", "\(segments)")
                    }
                    infoRow("ARQUIVO", probe.suggestedFileName)
                }
            }
        }
        .panelCard()
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundColor(Theme.textDim)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    // MARK: 02 · Assistir

    private var stepWatch: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepHeader(number: "02", title: "Assistir")
            if let mediaURL = selectedMediaURL {
                RemotePreview(url: mediaURL)
                    .frame(height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .id(mediaURL)
                TextField("Título do vídeo", text: $title)
                    .font(.system(.subheadline, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(10)
                    .background(Color(white: 0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Analise um link para liberar o player e assistir antes de baixar.")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(Theme.textDim)
            }
        }
        .panelCard()
    }

    // MARK: 03 · Qualidade e conexões

    private var stepQuality: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepHeader(number: "03", title: "Qualidade e conexões")
            if let probe, probe.kind == .hlsMaster {
                VStack(spacing: 6) {
                    ForEach(probe.variants) { variant in
                        Button {
                            selectedVariantID = variant.id
                        } label: {
                            HStack {
                                Text(variant.id == selectedVariantID ? "●" : "○")
                                    .foregroundColor(variant.id == selectedVariantID ? Theme.lime : Theme.textDim)
                                Text(variant.label)
                                    .font(.system(.subheadline, design: .monospaced))
                                    .foregroundColor(Theme.textPrimary)
                                Spacer()
                            }
                            .padding(.vertical, 7)
                            .padding(.horizontal, 10)
                            .background(Color(white: 0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Text(probe == nil ? "A qualidade aparece aqui quando o link tem variantes (HLS)." : "Qualidade única: \(qualityLabel).")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(Theme.textDim)
            }

            Text("CONEXÕES (estilo aria2)")
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundColor(Theme.textDim)
            HStack(spacing: 8) {
                ForEach(connectionOptions, id: \.self) { option in
                    Button {
                        connections = option
                    } label: {
                        Text("\(option)x")
                            .font(.system(.subheadline, design: .monospaced).weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(connections == option ? Theme.lime : Color(white: 0.14))
                            .foregroundColor(connections == option ? .black : Theme.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            if let probe, probe.kind == .file, !probe.supportsRange {
                Text("Este servidor não aceita Range: as conexões não se aplicam e o download será contínuo (1x).")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(Theme.textDim)
            }
            if let probe, probe.kind != .file {
                Text("No HLS os segmentos baixam em até 4 conexões paralelas.")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(Theme.textDim)
            }
        }
        .panelCard()
    }

    // MARK: 04 · Baixar e salvar

    private var stepDownload: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepHeader(number: "04", title: "Baixar e salvar")
            Button {
                enqueueDownload()
            } label: {
                Text("Baixar agora")
            }
            .buttonStyle(LimeButtonStyle())
            .disabled(probe == nil || selectedMediaURL == nil)
            Text("App nativo: sem bloqueio de CORS. O arquivo final fica salvo na Biblioteca (Documents/Videos).")
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(Theme.textDim)
        }
        .panelCard()
    }

    // MARK: Biblioteca

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepHeader(number: "05", title: "Biblioteca")
            if library.items.isEmpty {
                Text("Nenhum vídeo salvo ainda.")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(Theme.textDim)
            } else {
                ForEach(library.items) { item in
                    libraryRow(item)
                    if item.id != library.items.last?.id {
                        Divider().background(Theme.panelBorder)
                    }
                }
            }
        }
        .panelCard()
    }

    private func libraryRow(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)
            Text("\(item.qualityLabel) · \(Format.bytes(item.fileSize)) · \(Format.date(item.createdAt))")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(Theme.textDim)
            HStack(spacing: 8) {
                Button {
                    playerItem = PlayerSheetItem(url: library.url(for: item), title: item.title)
                } label: {
                    Label("Assistir", systemImage: "play.fill")
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(!library.fileExists(item))

                Button {
                    shareItem = ShareSheetItem(url: library.url(for: item))
                } label: {
                    Label("Compartilhar", systemImage: "square.and.arrow.up")
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(!library.fileExists(item))

                Spacer()

                Button(role: .destructive) {
                    library.delete(item)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Ações

    private func analyze() async {
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
                selectedVariantID = result.variants.max(by: { $0.bandwidth < $1.bandwidth })?.id
            } else {
                selectedVariantID = nil
            }
        } catch {
            probe = nil
            analyzeError = "Não consegui analisar: \((error as NSError).localizedDescription)"
        }
    }

    private func enqueueDownload() {
        guard let probe, let mediaURL = selectedMediaURL else { return }
        let isHLS = probe.kind != .file
        let request = DownloadRequest(
            title: title.trimmingCharacters(in: .whitespaces).isEmpty ? probe.suggestedTitle : title,
            mediaURL: mediaURL,
            isHLS: isHLS,
            qualityLabel: qualityLabel,
            connections: connections,
            totalBytes: isHLS ? nil : probe.contentLength,
            supportsRange: probe.supportsRange,
            fileExtension: probe.fileExtension
        )
        downloads.enqueue(request)
        queueExpanded = true
    }
}

/// Player de prévia do link remoto (passo 02).
struct RemotePreview: View {
    let url: URL
    @State private var player: AVPlayer

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .onDisappear { player.pause() }
    }
}
