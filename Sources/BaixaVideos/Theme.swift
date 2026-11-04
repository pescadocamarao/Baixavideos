import SwiftUI

/// Visual do app: escuro e compacto, tipografia técnica (monoespaçada nos
/// dados) e verde-lima APENAS em ações (botões) e progresso.
enum Theme {
    static let background = Color(red: 0.04, green: 0.05, blue: 0.04)
    static let panel = Color(red: 0.08, green: 0.10, blue: 0.08)
    static let panelBorder = Color(white: 0.16)
    static let textPrimary = Color(white: 0.92)
    static let textDim = Color(white: 0.55)
    static let lime = Color(red: 0.72, green: 0.96, blue: 0.20)
    static let danger = Color(red: 0.95, green: 0.35, blue: 0.30)
}

struct PanelCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(Theme.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.panelBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

extension View {
    func panelCard() -> some View { modifier(PanelCard()) }
}

/// Cabeçalho de passo: "01 · ANALISAR" em fonte técnica.
struct StepHeader: View {
    let number: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(number)
                .font(.system(.footnote, design: .monospaced).weight(.bold))
                .foregroundColor(Theme.textDim)
            Text(title.uppercased())
                .font(.system(.footnote, design: .monospaced).weight(.bold))
                .foregroundColor(Theme.textPrimary)
                .tracking(1.2)
            Spacer()
        }
    }
}

/// Botão principal (verde-lima) usado só nas ações.
struct LimeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .monospaced).weight(.bold))
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Theme.lime.opacity(configuration.isPressed ? 0.65 : 1.0))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
            .foregroundColor(Theme.textPrimary)
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .background(Color(white: 0.14).opacity(configuration.isPressed ? 0.6 : 1.0))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

enum Format {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func speed(_ mbPerSecond: Double) -> String {
        if mbPerSecond <= 0 { return "0,0 MB/s" }
        return String(format: "%.1f MB/s", mbPerSecond).replacingOccurrences(of: ".", with: ",")
    }

    static func eta(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        return "\(total / 60)m \(total % 60)s"
    }

    static func date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "dd/MM/yyyy HH:mm"
        return f.string(from: date)
    }

    /// Tempo de player: 0:00, 12:34 ou 1:02:03.
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
