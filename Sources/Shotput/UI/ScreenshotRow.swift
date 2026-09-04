import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ScreenshotRow: View {
    let shot: Screenshot
    let meta: String
    let isHighlighted: Bool
    let isCopied: Bool
    let onCopy: () -> Void
    let onCopyText: () -> Void
    let onAnnotate: () -> Void

    @State private var loadedThumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            ScreenshotThumbnail(shot: shot, style: .row, loaded: $loadedThumbnail)

            VStack(alignment: .leading, spacing: 1) {
                Text(shot.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)

                Text(meta)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondary(0.55))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowActions(.trailing) {
                ScreenshotRowActions(
                    isHighlighted: isHighlighted,
                    isCopied: isCopied,
                    onCopy: onCopy,
                    onCopyText: onCopyText,
                    onAnnotate: onAnnotate
                )
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            isHighlighted ? Theme.neutral(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: Theme.Radius.row)
        )
        .onTapGesture {
            onCopy()
        }
        .screenshotDrag(shot, thumbnail: loadedThumbnail)
    }
}

struct ScreenshotRowActions: View {
    let isHighlighted: Bool
    let isCopied: Bool
    var aiAction: AIRowAction = .none
    let onCopy: () -> Void
    let onCopyText: () -> Void
    let onAnnotate: () -> Void
    var onAIAction: () -> Void = {}

    var body: some View {
        if isCopied {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                Text("Copied")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .glassEffect(.regular.tint(Theme.green.opacity(0.9)), in: .capsule)
        } else if isHighlighted {
            GlassEffectContainer(spacing: 5) {
                HStack(spacing: 5) {
                    PillButton(
                        title: "Copy",
                        systemImage: "doc.on.doc",
                        prominent: true,
                        fontSize: 10.5,
                        action: onCopy
                    )

                    CircleIconButton(systemImage: "pencil", diameter: 24, action: onAnnotate)
                        .help("Annotate")

                    CircleIconButton(text: "T", diameter: 24, action: onCopyText)
                        .help("Copy text (OCR)")

                    if let help = aiAction.help {
                        CircleIconButton(systemImage: "arrow.clockwise", diameter: 24, action: onAIAction)
                            .help(help)
                    }
                }
                .fixedSize()
            }
        }
    }
}

/// Hangs a row's action cluster over its text rather than beside it. Laid
/// out in the row's HStack, the cluster took its width out of the text
/// column, so highlighting a row re-truncated the title and everything
/// after it shifted. The text that would run under the buttons fades out
/// instead.
private struct RowActionsOverlay<Actions: View>: ViewModifier {
    let alignment: Alignment
    let actions: Actions

    /// Zero while the cluster draws nothing, which is also how the row knows
    /// it has no text to fade.
    @State private var actionsWidth: CGFloat = 0

    /// The spacing the rows put between the text column and the cluster,
    /// kept clear so the fade ends where the buttons begin.
    private let gap: CGFloat = 10
    private let fadeWidth: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .mask { fade }
            .overlay(alignment: alignment) {
                actions.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { actionsWidth = $0 }
            }
    }

    private var fade: some View {
        HStack(spacing: 0) {
            Color.black
            if actionsWidth > 0 {
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: fadeWidth)
                Color.clear
                    .frame(width: actionsWidth + gap)
            }
        }
    }
}

extension View {
    func rowActions(_ alignment: Alignment, @ViewBuilder actions: () -> some View) -> some View {
        modifier(RowActionsOverlay(alignment: alignment, actions: actions()))
    }
}

/// Names a dragged screenshot after its AI title instead of the capture
/// timestamp. Two knobs, not one: a receiver that asks for the PNG
/// representation names the file after `suggestedName` (and calls it
/// "PNG image.png" when that is nil), while one that reads the file URL
/// names it after the file on disk, so the drag also hands out a copy that
/// already carries the name.
@MainActor
enum ScreenshotDrag {
    /// Room for the extension and a collision suffix inside the 255-byte
    /// limit even when every character of the title is multi-byte.
    static let maxNameLength = 60

    /// A name handed out this recently still counts as taken.
    static let collisionWindow: TimeInterval = 2

    private static var recentNames: [String: Date] = [:]

    static func provider(for shot: Screenshot) -> NSItemProvider {
        // Built before it is registered: `register` takes an autoclosure it
        // may run off the main actor, where staging the clone can't go.
        let item = DraggedScreenshot(shot: shot)
        let provider = NSItemProvider()
        provider.register(item)
        return provider
    }

    /// The file a drag hands over and the name it goes by: a clone under the
    /// chosen name, or the screenshot itself when it is already called that
    /// and when neither cloning nor copying works.
    static func draggedFile(for shot: Screenshot) -> (url: URL, name: String) {
        let name = claim(fileName(for: shot))
        guard name != shot.url.lastPathComponent else { return (shot.url, name) }
        return (staged(shot.url, as: name) ?? shot.url, name)
    }

    static func fileName(for shot: Screenshot) -> String {
        let original = shot.url.lastPathComponent
        let ext = shot.url.pathExtension
        // With AI off there is no title, and the capture name it falls back
        // to is itself full of spaces and dots.
        let base = shot.title ?? (ext.isEmpty ? original : (original as NSString).deletingPathExtension)
        let cleaned = sanitized(base)
        guard !cleaned.isEmpty else { return original }
        return ext.isEmpty ? cleaned : "\(cleaned).\(ext)"
    }

    /// Lowercase kebab: a model can answer with slashes, colons, newlines and
    /// a paragraph of text, and a capture is named with spaces and dots,
    /// none of which belong in a name a receiver has to type or quote.
    /// Alphanumerics survive as they are, so an accented or CJK title stays
    /// readable rather than folding away to nothing.
    static func sanitized(_ title: String) -> String {
        var out = ""
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if !out.isEmpty, !out.hasSuffix("-") {
                out.append("-")
            }
        }

        if out.count > maxNameLength {
            let clipped = String(out.prefix(maxNameLength))
            if let lastDash = clipped.lastIndex(of: "-"), clipped.distance(from: clipped.startIndex, to: lastDash) > maxNameLength / 2 {
                out = String(clipped[..<lastDash])
            } else {
                out = clipped
            }
        }

        // Trailing punctuation ("Stripe dashboard...") has already written
        // its dash by the time the loop runs out. A leading one can't
        // happen, and a dot never survives at all, so neither the hidden
        // ".name" nor the "name." Finder refuses can come out of here.
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// Two screenshots can be described alike, and a multi-item drag would
    /// then hand the receiver two files with one name. The second becomes
    /// "…-2", still kebab.
    static func claim(_ name: String, now: Date = Date()) -> String {
        prune(now: now)
        guard recentNames[name] != nil else {
            recentNames[name] = now
            return name
        }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            if recentNames[candidate] == nil {
                recentNames[candidate] = now
                return candidate
            }
            index += 1
        }
    }

    private static func prune(now: Date = Date()) {
        recentNames = recentNames.filter { now.timeIntervalSince($0.value) < collisionWindow }
    }

    private static var stagingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Shotput-drag", isDirectory: true)
    }

    private static func staged(_ url: URL, as name: String) -> URL? {
        pruneStaged()
        let box = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)) != nil else { return nil }
        let destination = box.appendingPathComponent(name)
        // A clone is free on APFS and, unlike a hard link, is a file of its
        // own: a receiver that edits what it took cannot write through to
        // the screenshot still sitting in the capture folder.
        if clonefile(url.path, destination.path, 0) == 0 { return destination }
        guard (try? FileManager.default.copyItem(at: url, to: destination)) != nil else { return nil }
        return destination
    }

    /// A drag that is never dropped still leaves its staged copy behind.
    private static func pruneStaged(now: Date = Date(), maxAge: TimeInterval = 3600) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if now.timeIntervalSince(created) > maxAge {
                try? manager.removeItem(at: entry)
            }
        }
    }
}

/// One screenshot on its way out of the app. Both surfaces hand this over:
/// the dropdown rows register it in an `NSItemProvider`, and the Library's
/// multi-item drag carries it directly, because SwiftUI's `dragContainer`
/// takes `Transferable` values and not providers.
struct DraggedScreenshot: Identifiable, Transferable, Sendable {
    let shot: Screenshot
    /// The staged clone, or the screenshot itself when it already goes by
    /// the right name. Resolved once, when the drag starts, so a receiver
    /// reading the file URL sees the name too and two screenshots described
    /// alike don't both arrive as one file.
    let file: URL
    let fileName: String

    var id: URL { shot.url }

    @MainActor
    init(shot: Screenshot) {
        let dragged = ScreenshotDrag.draggedFile(for: shot)
        self.shot = shot
        file = dragged.url
        fileName = dragged.name
    }

    /// The file's own type comes first so a receiver asking for image bytes
    /// is never handed a jpeg labelled png, and the URL comes last for the
    /// receivers that take the file straight off disk.
    static var transferRepresentation: some TransferRepresentation {
        representation(.png)
        representation(.jpeg)
        representation(.heic)
        representation(.tiff)
        representation(.gif)
        ProxyRepresentation(exporting: \.file)
    }

    private static func representation(_ type: UTType) -> some TransferRepresentation<Self> {
        FileRepresentation(exportedContentType: type) {
            SentTransferredFile($0.file)
        }
        .exportingCondition { $0.contentType == type }
        .suggestedFileName { $0.fileName }
    }

    private var contentType: UTType? {
        UTType(filenameExtension: shot.url.pathExtension.lowercased())
    }
}

extension View {
    func screenshotDrag(_ shot: Screenshot, thumbnail: NSImage?) -> some View {
        self.onDrag {
            ScreenshotDrag.provider(for: shot)
        } preview: {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.neutral(0.14))
                    .frame(width: 56, height: 36)
            }
        }
    }
}
