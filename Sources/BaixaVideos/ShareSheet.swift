import SwiftUI

/// Compartilhar (salvar em Arquivos/Fotos, enviar, etc.).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Item de folha de compartilhamento (arquivo local ou URL remota).
struct ShareSheetItem: Identifiable {
    let id = UUID()
    let url: URL
}
