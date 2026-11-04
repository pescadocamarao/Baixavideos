import SwiftUI

@main
struct BaixaVideosApp: App {
    @StateObject private var library: LibraryStore
    @StateObject private var downloads: DownloadManager

    init() {
        let library = LibraryStore()
        _library = StateObject(wrappedValue: library)
        _downloads = StateObject(wrappedValue: DownloadManager(library: library))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(downloads)
                .preferredColorScheme(.dark)
        }
    }
}
