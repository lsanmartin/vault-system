import Foundation
import AppKit
import SwiftUI

/// Categoría general de un archivo, derivada de su extensión.
enum FileCategory {
    case image, pdf, code, text, archive, audio, video, data, other
}

/// Helpers de tipos de archivo por extensión (sin I/O de disco).
enum FileTypeHelper {
    static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "gif", "ico", "webp", "bmp", "tiff", "heic", "heif", "avif", "svg"
    ]
    static let markdownExts: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx"]
    static let textLikeExts: Set<String> = [
        "txt", "log", "csv", "tsv", "json", "jsonl", "yaml", "yml", "toml", "ini", "cfg", "conf",
        "py", "js", "ts", "jsx", "tsx", "swift", "rs", "c", "h", "cpp", "hpp", "go", "rb", "php",
        "sh", "bash", "zsh", "sql", "html", "css", "scss", "xml", "plist", "r", "java", "kt", "lua", "md"
    ]

    static func ext(for path: String) -> String {
        (path as NSString).pathExtension.lowercased()
    }

    static func isImage(_ path: String) -> Bool { imageExts.contains(ext(for: path)) }
    static func isMarkdown(_ path: String) -> Bool { markdownExts.contains(ext(for: path)) }
    static func isTextLike(_ path: String) -> Bool { textLikeExts.contains(ext(for: path)) }

    static func category(_ path: String) -> FileCategory {
        let e = ext(for: path)
        if imageExts.contains(e) { return .image }
        if e == "pdf" { return .pdf }
        if ["zip", "tar", "gz", "bz2", "rar", "7z", "dmg", "pkg"].contains(e) { return .archive }
        if ["mp3", "wav", "aac", "m4a", "flac", "ogg", "mid", "midi"].contains(e) { return .audio }
        if ["mp4", "mov", "avi", "mkv", "m4v", "webm"].contains(e) { return .video }
        if ["db", "sqlite", "sqlite3", "parquet", "ibd", "rda", "wt", "map", "lock"].contains(e) { return .data }
        if textLikeExts.contains(e) { return .text }
        return .other
    }

    /// Símbolo SF Symbol representativo de cada formato.
    static func iconSymbol(for path: String) -> String {
        switch category(path) {
        case .image:   return "photo"
        case .pdf:     return "doc.richtext"
        case .archive: return "archivebox"
        case .audio:   return "waveform"
        case .video:   return "film"
        case .data:    return "cylinder.split.1x2"
        case .text:
            switch ext(for: path) {
            case "json", "jsonl":            return "curlybraces"
            case "yaml", "yml", "toml", "ini", "cfg", "conf", "plist": return "gearshape"
            case "csv", "tsv":               return "tablecells"
            case "sql":                      return "externaldrive"
            default:                         return "chevron.left.forwardslash.chevron.right"
            }
        default: return "doc"
        }
    }

    /// Ruta relativa de `target` respecto a `baseDir` (ambas absolutas), separadores `/`.
    static func relativePath(from baseDir: String, to target: String) -> String {
        let base = (baseDir as NSString).pathComponents
        let tgt = (target as NSString).pathComponents
        var i = 0
        while i < base.count && i < tgt.count && base[i] == tgt[i] { i += 1 }
        let ups = Array(repeating: "..", count: base.count - i)
        return (ups + tgt[i...].map { $0 }).joined(separator: "/")
    }
}

extension Notification.Name {
    static let vaultInsertImageMarkdown = Notification.Name("VaultInsertImageMarkdown")
}
