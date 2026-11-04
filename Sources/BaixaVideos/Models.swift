import Foundation

// MARK: - Análise de link (passo 01)

struct HLSVariant: Identifiable, Equatable {
    let id = UUID()
    let bandwidth: Int
    let width: Int?
    let height: Int?
    let url: URL

    var label: String {
        var parts: [String] = []
        if let height {
            parts.append("\(height)p")
        } else {
            parts.append("Áudio/var")
        }
        let mbps = Double(bandwidth) / 1_000_000.0
        parts.append(String(format: "%.1f Mbps", mbps).replacingOccurrences(of: ".", with: ","))
        return parts.joined(separator: " · ")
    }
}

enum MediaKind: Equatable {
    case file           // .mp4/.mov/.webm direto
    case hlsMaster      // .m3u8 com variantes de qualidade
    case hlsMedia       // .m3u8 com segmentos (qualidade única)
}

struct ProbeResult {
    let sourceURL: URL
    let finalURL: URL
    let contentType: String?
    let contentLength: Int64?
    let supportsRange: Bool
    let kind: MediaKind
    let variants: [HLSVariant]
    let segmentCount: Int?

    var suggestedFileName: String {
        let name = finalURL.lastPathComponent
        return name.isEmpty ? "video.mp4" : name
    }

    var suggestedTitle: String {
        let base = suggestedFileName
        let ext = (base as NSString).pathExtension
        if ext.isEmpty { return base }
        return (base as NSString).deletingPathExtension
    }

    var fileExtension: String {
        switch kind {
        case .hlsMaster, .hlsMedia:
            return "ts"
        case .file:
            let ext = finalURL.pathExtension.lowercased()
            return ext.isEmpty ? "mp4" : ext
        }
    }
}

// MARK: - Biblioteca (passo 04 / biblioteca)

struct LibraryItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var sourceURL: String
    var qualityLabel: String
    /// Nome do arquivo dentro de Documents/Videos.
    var fileName: String
    var fileSize: Int64
    var createdAt: Date
    var isHLS: Bool
}

// MARK: - Downloads

enum DownloadState: String {
    case queued
    case downloading
    case paused
    case assembling
    case completed
    case failed
    case cancelled

    var label: String {
        switch self {
        case .queued: return "NA FILA"
        case .downloading: return "BAIXANDO"
        case .paused: return "PAUSADO"
        case .assembling: return "MONTANDO"
        case .completed: return "CONCLUÍDO"
        case .failed: return "FALHOU"
        case .cancelled: return "CANCELADO"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }
}

enum PieceState {
    case pending
    case active
    case done
    case failed
}

struct Piece: Identifiable {
    let id: Int
    let start: Int64
    let end: Int64
    var state: PieceState = .pending

    /// Tamanho em bytes (para HLS vale 1: o progresso é por segmento).
    var size: Int64 { max(0, end - start + 1) }
}

struct DownloadRequest {
    var title: String
    /// URL da mídia (arquivo direto ou playlist .m3u8 da qualidade escolhida).
    var mediaURL: URL
    var isHLS: Bool
    var qualityLabel: String
    var connections: Int
    var totalBytes: Int64?
    var supportsRange: Bool
    var fileExtension: String
}
