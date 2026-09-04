import AppKit

enum Clipboard {
    /// One `NSPasteboardItem` per URL, so "Copy 2" pastes as two files into
    /// Finder and as two images into an app that reads every item.
    @discardableResult
    static func copyImages(_ urls: [URL], to pasteboard: NSPasteboard = .general) -> Bool {
        guard !urls.isEmpty else { return false }

        // Every file is read before the pasteboard is touched: one file
        // trashed since the last rescan must leave what the user already had
        // on the clipboard alone.
        var items: [NSPasteboardItem] = []
        for url in urls {
            guard let data = imageData(for: url) else { return false }
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setData(data.data, forType: data.type)
            items.append(item)
        }

        pasteboard.clearContents()
        return pasteboard.writeObjects(items)
    }

    static func copyText(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func imageData(for url: URL) -> (data: Data, type: NSPasteboard.PasteboardType)? {
        if url.pathExtension.lowercased() == "png", let data = try? Data(contentsOf: url) {
            return (data, .png)
        }
        guard let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation else { return nil }
        return (tiff, .tiff)
    }
}
