import SwiftUI
import AppKit
import ImageIO

/// Caché en memoria de thumbnails (keyed por path + maxPixel).
/// Decodifica SOLO el thumbnail vía ImageIO (downsampling), nunca el bitmap completo a RAM.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 512
        cache.totalCostLimit = 64 * 1024 * 1024 // ~64 MB
    }

    func image(for path: String, maxPixel: CGFloat) -> NSImage? {
        let key = "\(Int(maxPixel))|\(path)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let thumb = Self.decodeDownsampled(path: path, maxPixel: maxPixel) else { return nil }
        cache.setObject(thumb, forKey: key, cost: Self.cost(of: thumb))
        return thumb
    }

    func loadAsync(path: String, maxPixel: CGFloat) async -> NSImage? {
        if let hit = image(for: path, maxPixel: maxPixel) { return hit }
        let thumb = await Task.detached(priority: .utility) {
            Self.decodeDownsampled(path: path, maxPixel: maxPixel)
        }.value
        if let thumb = thumb {
            cache.setObject(thumb, forKey: "\(Int(maxPixel))|\(path)" as NSString, cost: Self.cost(of: thumb))
        }
        return thumb
    }

    private static func cost(of img: NSImage) -> Int {
        max(Int(img.size.width), 1) * max(Int(img.size.height), 1) * 4
    }

    nonisolated private static func decodeDownsampled(path: String, maxPixel: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// View SwiftUI: carga async con caché; fallback a icono si no puede decodificar.
struct ThumbnailView: View {
    let path: String
    var maxPixel: CGFloat = 512
    @State private var image: NSImage?
    @State private var didAttempt = false

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else if didAttempt {
                Image(systemName: "photo").font(.system(size: 14)).foregroundColor(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: path) {
            image = await ThumbnailCache.shared.loadAsync(path: path, maxPixel: maxPixel)
            didAttempt = true
        }
    }
}
