import Foundation
import WebKit
import UIKit

/// Escavador de mídia: recebe o link de uma PÁGINA de vídeo e acha o
/// link do stream (.m3u8/.mp4) escondido nela — pra colar o link da
/// página direto, sem caçar o .m3u8 na mão.
///
/// Estratégias, na ordem:
/// 1. Busca direta do HTML + regex (as do próprio seidao: barras
///    escapadas do player_aaaa e iframe com `url=`)
/// 2. Navegador embutido (WKWebView): vê a página como o Safari,
///    colhe a config do player, os recursos que o player carregou e,
///    se o player morar num iframe, entra no iframe e colhe de novo
/// Cada etapa anota o que viu num relatório — se tudo falhar, o
/// relatório vai na mensagem de erro, pra não voar no escuro.
enum PageDigger {

    struct Result {
        let media: URL?
        let report: String
    }

    static func dig(pageURL: URL) async -> Result {
        var notes: [String] = []

        // Etapa 1 — busca direta
        var staticEmbed: URL? = nil
        do {
            let html = try await DownloadTransport.fetchText(url: pageURL)
            notes.append("busca direta: HTML de \(html.count / 1024) KB")
            if html.contains("#EXTM3U") {
                return Result(media: pageURL, report: notes.joined(separator: " · "))
            }
            if html.contains("player_aaaa") || html.contains("player_data") {
                notes.append("config do player presente no HTML")
            } else {
                notes.append("sem config de player no HTML")
            }
            let found = extract(html: html, baseURL: pageURL)
            if let media = found.media {
                notes.append("regex achou a mídia no HTML")
                return Result(media: media, report: notes.joined(separator: " · "))
            }
            staticEmbed = found.embed
            if let embedHTML = try? await DownloadTransport.fetchText(url: found.embed ?? pageURL),
               found.embed != nil {
                let inner = extract(html: embedHTML, baseURL: found.embed ?? pageURL)
                if let media = inner.media {
                    notes.append("regex achou a mídia no iframe (busca direta)")
                    return Result(media: media, report: notes.joined(separator: " · "))
                }
            }
        } catch {
            notes.append("busca direta falhou (\(error.localizedDescription))")
        }

        // Etapa 2 — navegador embutido
        let harvest = await WebViewDigger.dig(url: pageURL, staticEmbed: staticEmbed)
        notes.append(harvest.note)
        for candidate in harvest.urls where !candidate.contains("<") {
            if let url = resolve(candidate, baseURL: pageURL), isMedia(url) {
                return Result(media: url, report: notes.joined(separator: " · "))
            }
        }
        if let renderedHTML = harvest.urls.last(where: { $0.contains("<") }),
           let media = extract(html: renderedHTML, baseURL: pageURL).media {
            notes.append("regex achou a mídia no HTML renderizado")
            return Result(media: media, report: notes.joined(separator: " · "))
        }
        return Result(media: nil, report: notes.joined(separator: " · "))
    }

    static func extract(html: String, baseURL: URL) -> (media: URL?, embed: URL?) {
        // Cópia sem escape do HTML: `\/` vira `/` (a regex nº 2 dele
        // faz exatamente essa limpeza) e entidades HTML são resolvidas.
        let unescaped = html
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u002F", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")

        // 1) og:video
        for pattern in [
            #"<meta[^>]+property="og:video(?::secure_url)?"[^>]+content="([^"]+)""#,
            #"<meta[^>]+content="([^"]+)"[^>]+property="og:video(?::secure_url)?""#
        ] {
            if let value = firstMatch(pattern, in: unescaped),
               let url = resolve(value, baseURL: baseURL), isMedia(url) {
                return (url, nil)
            }
        }

        // 2) .m3u8 literal (inclui o que estava escapado, já limpo acima)
        if let value = firstMatch(#"https?://[^\s"'<>]+?\.m3u8(?:\?[^\s"'<>]*)?"#, in: unescaped),
           let url = resolve(value, baseURL: baseURL) {
            return (url, nil)
        }

        // 3) Regex nº 1 dele: iframe com url= no src
        var embed: URL? = nil
        if let raw = firstMatch(#"src="[^"]*?url=([^"]+)""#, in: html) {
            let decoded = raw.removingPercentEncoding ?? raw
            if let url = resolve(decoded, baseURL: baseURL) {
                if isMedia(url) { return (url, nil) }
                embed = url
            }
        }

        // 4) Iframe comum (player embutido sem url=)
        if embed == nil,
           let raw = firstMatch(#"<iframe[^>]+src="([^"]+)""#, in: html),
           let url = resolve(raw, baseURL: baseURL), !isMedia(url) {
            embed = url
        }

        // 5) .mp4 literal
        if let value = firstMatch(#"https?://[^\s"'<>]+?\.mp4(?:\?[^\s"'<>]*)?"#, in: unescaped),
           let url = resolve(value, baseURL: baseURL) {
            return (url, embed)
        }
        return (nil, embed)
    }

    static func isMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "m3u8" || ext == "mp4"
    }

    static func resolve(_ raw: String, baseURL: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL { return url }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[capture])
    }
}

/// Etapa 2 da escavação: carrega a página num WKWebView ligado à
/// janela do app (WebView solto o iOS pode congelar) e colhe, de
/// todos os frames acessíveis: config do player (player_aaaa /
/// player_data), tags <video>/<source>, os recursos realmente
/// carregados (performance entries) e o HTML renderizado. Se o
/// player morar num iframe, faz uma segunda rodada dentro dele.
@MainActor
final class WebViewDigger: NSObject, WKNavigationDelegate {
    struct Harvest {
        let urls: [String]
        let note: String
    }

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Harvest, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var extractionStarted = false
    private var round = 0
    private var collected: [String] = []
    private var pendingEmbed: URL?
    private var baseURL: URL?

    static func dig(url: URL, staticEmbed: URL?) async -> Harvest {
        let digger = WebViewDigger()
        return await digger.run(url: url, staticEmbed: staticEmbed)
    }

    private func run(url: URL, staticEmbed: URL?) async -> Harvest {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.baseURL = url
            self.pendingEmbed = staticEmbed
            let webView = WKWebView(
                frame: CGRect(x: -1200, y: 0, width: 390, height: 844),
                configuration: WKWebViewConfiguration())
            webView.navigationDelegate = self
            webView.customUserAgent = DownloadTransport.userAgent
            webView.isUserInteractionEnabled = false
            webView.alpha = 0.02
            self.webView = webView
            // Ligado à janela (fora da tela): WebView solto pode ser
            // congelado pelo iOS e nunca rodar o JS da página.
            if let window = Self.keyWindow() {
                window.addSubview(webView)
            }
            webView.load(DownloadTransport.makeRequest(url: url, timeout: 30))
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                self?.finish(note: "tempo esgotado")
            }
        }
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Dá tempo do JS do player montar e pedir a playlist.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            self?.extract()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(note: "navegação falhou (\(error.localizedDescription))")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(note: "navegação falhou (\(error.localizedDescription))")
    }

    private func extract() {
        guard !extractionStarted, let webView else { return }
        extractionStarted = true
        let script = """
        (() => {
          const urls = [];
          const frames = [];
          const scan = (win) => {
            try {
              if (win.player_aaaa && win.player_aaaa.url) urls.push(win.player_aaaa.url);
              if (win.player_data && win.player_data.url) urls.push(win.player_data.url);
            } catch (e) {}
            try {
              win.document.querySelectorAll('video, source').forEach(el => { if (el.src) urls.push(el.src); });
            } catch (e) {}
            try {
              win.performance.getEntriesByType('resource').forEach(e => { if (e.name) urls.push(e.name); });
            } catch (e) {}
            try {
              for (let i = 0; i < win.frames.length; i++) {
                try { frames.push(win.frames[i].location.href); } catch (e) {}
                scan(win.frames[i]);
              }
            } catch (e) {}
          };
          scan(window);
          try {
            document.querySelectorAll('iframe').forEach(el => { if (el.src) frames.push(el.src); });
          } catch (e) {}
          try { urls.push(document.documentElement.outerHTML); } catch (e) {}
          return { urls: urls, frames: frames };
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self else { return }
            var urls: [String] = []
            var frames: [String] = []
            if let dict = result as? [String: Any] {
                urls = (dict["urls"] as? [String]) ?? []
                frames = (dict["frames"] as? [String]) ?? []
            }
            self.collected.append(contentsOf: urls)
            let hasMedia = self.collected.contains {
                !$0.contains("<") && (PageDigger.isMedia(URL(string: $0) ?? URL(fileURLWithPath: "/")))
            }
            if !hasMedia, self.round == 0 {
                // Segunda rodada: entra no iframe do player.
                let frameURL = frames
                    .compactMap { URL(string: $0) }
                    .first { $0.scheme == "https" || $0.scheme == "http" }
                let next = frameURL ?? self.pendingEmbed
                if let next, next != self.baseURL {
                    self.round = 1
                    self.extractionStarted = false
                    self.webView?.load(DownloadTransport.makeRequest(url: next, timeout: 30))
                    return
                }
            }
            self.finish(note: "webview: \(self.collected.count) candidatos, \(frames.count) frames, rodada \(self.round + 1)")
        }
    }

    private func finish(note: String) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        continuation.resume(returning: Harvest(urls: collected, note: note))
    }
}
