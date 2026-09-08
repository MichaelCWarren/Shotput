import AppKit
import Quartz

final class QuickLookPreviewer: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// The dropdown floats at `.popUpMenu`, so a preview left at QuickLook's
    /// own level opens behind the list that asked for it. One step above the
    /// dropdown puts the preview in front of every window this app shows.
    static let panelLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)

    var urls: [URL] = []

    func toggle(_ url: URL) {
        toggle([url])
    }

    /// More than one url when the library previews a multi-selection: the
    /// panel's own arrows then step through them.
    func toggle(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() {
            // Only the same files toggle off; a different one swaps the preview
            // so arrowing down a row and pressing space needs one press.
            if panel.isVisible, self.urls == urls {
                panel.orderOut(nil)
                return
            }
        }

        self.urls = urls
        if let panel = QLPreviewPanel.shared() {
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)
            panel.level = Self.panelLevel
        }
    }

    func close() {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() {
            if panel.isVisible {
                panel.orderOut(nil)
            }
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}
