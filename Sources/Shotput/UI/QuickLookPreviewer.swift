import AppKit
import Quartz

final class QuickLookPreviewer: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var url: URL?

    func toggle(_ url: URL) {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() {
            // Only the same file toggles off; a different one swaps the preview
            // so arrowing down a row and pressing space needs one press.
            if panel.isVisible, self.url == url {
                panel.orderOut(nil)
                return
            }
        }

        self.url = url
        if let panel = QLPreviewPanel.shared() {
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)
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
        url != nil ? 1 : 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url as NSURL?
    }
}
