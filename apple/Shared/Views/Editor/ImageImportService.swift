import Foundation
import AppKit

/// Servicio de importación de imágenes a una nota: copia a `<carpeta nota>/_attachments/`
/// y devuelve el enlace Markdown con ruta relativa (resuelve contra la carpeta de la nota).
enum ImageImportService {
    static let attachmentsDirName = "_attachments"

    /// Copia `source` (fuera del vault) a la carpeta de attachments de la nota y devuelve el link MD.
    static func importIntoAttachments(source: URL, noteDir: URL) -> String? {
        guard let dest = uniqueDestination(for: source, noteDir: noteDir) else { return nil }
        do { try FileManager.default.copyItem(at: source, to: dest) }
        catch { return nil }
        return markdownLink(from: dest, noteDir: noteDir)
    }

    /// Enlace Markdown: `![alt](rel)` si es imagen, `[title](rel)` si no.
    static func markdownLink(from target: URL, noteDir: URL) -> String {
        let rel = FileTypeHelper.relativePath(from: noteDir.path, to: target.path)
        if FileTypeHelper.isImage(target.path) {
            return "![](\(rel))"
        }
        return "[\(target.lastPathComponent)](\(rel))"
    }

    /// Si el portapapeles trae una imagen, la guarda en `_attachments/` y devuelve el link MD.
    static func importFromPasteboard(noteDir: URL) -> String? {
        let pb = NSPasteboard.general
        if let tiff = pb.data(forType: .tiff), let img = NSImage(data: tiff) {
            return saveImage(img, noteDir: noteDir, ext: "png")
        }
        if let png = pb.data(forType: .png), let img = NSImage(data: png) {
            return saveImage(img, noteDir: noteDir, ext: "png")
        }
        return nil
    }

    // MARK: - Privado

    private static func uniqueDestination(for source: URL, noteDir: URL) -> URL? {
        let att = noteDir.appendingPathComponent(attachmentsDirName)
        try? FileManager.default.createDirectory(at: att, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
        let base = source.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "\\W", with: "-", options: .regularExpression)
        var dest = att.appendingPathComponent("\(base).\(ext)")
        var i = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = att.appendingPathComponent("\(base)-\(i).\(ext)")
            i += 1
        }
        return dest
    }

    private static func saveImage(_ img: NSImage, noteDir: URL, ext: String) -> String? {
        let att = noteDir.appendingPathComponent(attachmentsDirName)
        try? FileManager.default.createDirectory(at: att, withIntermediateDirectories: true)
        let dest = att.appendingPathComponent("image-\(Int(Date().timeIntervalSince1970)).\(ext)")
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: ext == "png" ? .png : .jpeg, properties: [:]) else { return nil }
        do { try data.write(to: dest) } catch { return nil }
        return markdownLink(from: dest, noteDir: noteDir)
    }
}
