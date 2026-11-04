import SwiftUI

/// Fila de downloads fixa e discreta no rodapé da tela principal.
/// Toque no cabeçalho para expandir/recolher.
struct QueueBar: View {
    @EnvironmentObject private var downloads: DownloadManager
    @Binding var expanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.bold))
                    Text("FILA")
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .tracking(1.2)
                    Text(downloads.activeCount > 0
                         ? "· \(downloads.activeCount) ativo(s)"
                         : (downloads.jobs.isEmpty ? "· vazia" : "· \(downloads.jobs.count) item(ns)"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(Theme.textDim)
                    Spacer()
                    if let active = downloads.jobs.first(where: { $0.state == .downloading }) {
                        Text("\(Int(active.progress * 100))%")
                            .font(.system(.caption, design: .monospaced).weight(.bold))
                            .foregroundColor(Theme.lime)
                    }
                }
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded && !downloads.jobs.isEmpty {
                Divider().background(Theme.panelBorder)
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(downloads.jobs) { job in
                            JobRow(job: job)
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 240)
            }
        }
        .background(Theme.panel)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.panelBorder), alignment: .top)
    }
}

struct JobRow: View {
    @EnvironmentObject private var downloads: DownloadManager
    @ObservedObject var job: DownloadJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.title)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(job.state.label)
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .foregroundColor(job.state == .failed ? Theme.danger : Theme.textDim)
            }

            ProgressView(value: job.progress)
                .tint(Theme.lime)

            HStack(spacing: 10) {
                Text("\(Int(job.progress * 100))%")
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundColor(Theme.lime)
                if job.state == .downloading {
                    Text(Format.speed(job.speedMBs))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(Theme.textDim)
                    Text("ETA \(Format.eta(job.etaSeconds))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(Theme.textDim)
                }
                Text("\(Format.bytes(job.downloadedBytes)) / \(Format.bytes(job.totalBytes))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(Theme.textDim)
                Spacer()
            }

            if !job.pieces.isEmpty && job.pieces.count <= 160 {
                PieceGrid(job: job)
            }

            if let error = job.errorMessage, job.state == .failed {
                Text(error)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(Theme.danger)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                if job.state == .downloading {
                    smallButton("Pausar", systemImage: "pause.fill") { downloads.pause(job) }
                }
                if job.state == .paused || job.state == .failed {
                    smallButton(job.state == .failed ? "Tentar de novo" : "Retomar", systemImage: "play.fill") {
                        downloads.start(job)
                    }
                }
                if !job.state.isTerminal {
                    smallButton("Cancelar", systemImage: "xmark") { downloads.cancel(job) }
                }
                Spacer()
                if job.state.isTerminal || job.state == .paused {
                    Button {
                        downloads.remove(job)
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(GhostButtonStyle())
                }
            }
        }
        .padding(10)
        .background(Color(white: 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func smallButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.system(.caption, design: .monospaced).weight(.bold))
        }
        .buttonStyle(GhostButtonStyle())
    }
}

/// Grade de pedaços: verde-lima = baixado, claro = ativo, cinza = pendente.
struct PieceGrid: View {
    @ObservedObject var job: DownloadJob

    private let columns = [GridItem(.adaptive(minimum: 9, maximum: 9), spacing: 3)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
            ForEach(job.pieces) { piece in
                Rectangle()
                    .fill(color(for: piece.state))
                    .frame(width: 9, height: 9)
                    .cornerRadius(2)
            }
        }
    }

    private func color(for state: PieceState) -> Color {
        switch state {
        case .done: return Theme.lime
        case .active: return Theme.textPrimary
        case .pending: return Color(white: 0.25)
        case .failed: return Theme.danger
        }
    }
}
