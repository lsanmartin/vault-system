import Foundation
import AppKit
import QuickLookUI

/// Singleton que controla el panel QuickLook nativo (QLPreviewPanel).
/// Se usa para previsualizar cualquier archivo no-`.md` (imágenes, PDF, video, audio).
final class QuickLookManager: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookManager()
    private var urls: [URL] = []
    private var currentIndex = 0

    private override init() {}

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as QLPreviewItem
    }

    @discardableResult
    func present(url: URL) -> Bool {
        urls = [url]
        currentIndex = 0
        guard let panel = QLPreviewPanel.shared() else { return false }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = currentIndex
        if !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func toggle(url: URL) {
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            present(url: url)
        }
    }
}
