import Foundation

/// Escavador de mídia: recebe o link de uma PÁGINA de vídeo e acha o
/// link do stream (.m3u8/.mp4) escondido nela — pra colar o link da
/// página direto, sem caçar o .m3u8 na mão.
///
/// Estratégias, na ordem (as duas primeiras são as regex do próprio
/// seidao, as que ele usa nas rules do Yealico):
/// 1. JSON/script com barras escapadas (`https:\/\/...index.m3u8`)
/// 2. Iframe com `url=` no src → a página do player embutido (escava ela)
/// 3. og:video / og:video:secure_url
/// 4. Qualquer .m3u8 / .mp4 literal no HTML
enum PageDigger {

    /// Devolve a URL de mídia achada, ou nil se a página não revelar nada.
    static func dig(pageURL: URL) async -> URL? {
        guard let html = try? await DownloadTransport.fetchText(url: pageURL) else {
            return nil
        }
        // A "página" pode ser a playlist disfarçada (URL sem extensão).
        if html.contains("#EXTM3U") { return pageURL }
        let found = extract(html: html, baseURL: pageURL)
        if let media = found.media { return media }
        if let embed = found.embed,
           let embedHTML = try? await DownloadTransport.fetchText(url: embed) {
            if embedHTML.contains("#EXTM3U") { return embed }
            return extract(html: embedHTML, baseURL: embed).media
        }
        return nil
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

    private static func isMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "m3u8" || ext == "mp4"
    }

    private static func resolve(_ raw: String, baseURL: URL) -> URL? {
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
