import AppKit
import Combine
import SwiftUI
import os

/// Screen 1f's countdown, kept separate from the panel so the arithmetic is
/// testable without a screen or a real timer: `now` is injected, and
/// `remaining` is computed fresh from `deadline`/`hoverStart` on every read.
@MainActor
@Observable
final class ToastModel {
    private(set) var isVisible = false
    private(set) var screenshot: Screenshot?
    private(set) var appName: String?
    private(set) var copied = false
    private(set) var thumbnail: NSImage?
    private(set) var copyTextLabel = "Copy text"

    private var deadline: Date?
    private var hoverStart: Date?
    private let duration: TimeInterval
    private let now: () -> Date

    init(duration: TimeInterval = 4, now: @escaping () -> Date = Date.init) {
        self.duration = duration
        self.now = now
    }

    /// Seconds left until dismissal. Frozen at the value it held when
    /// hovering began, so leaving resumes the countdown instead of losing
    /// the paused time.
    var remaining: TimeInterval {
        guard let deadline else { return 0 }
        if let hoverStart {
            return max(0, deadline.timeIntervalSince(hoverStart))
        }
        return max(0, deadline.timeIntervalSince(now()))
    }

    func show(_ screenshot: Screenshot, appName: String?, copied: Bool) {
        self.screenshot = screenshot
        self.appName = appName
        self.copied = copied
        thumbnail = nil
        copyTextLabel = "Copy text"
        isVisible = true
        hoverStart = nil
        deadline = now().addingTimeInterval(duration)
    }

    func setHovering(_ hovering: Bool) {
        if hovering {
            guard hoverStart == nil else { return }
            hoverStart = now()
        } else {
            guard let hoverStart else { return }
            let elapsed = now().timeIntervalSince(hoverStart)
            deadline = (deadline ?? now()).addingTimeInterval(elapsed)
            self.hoverStart = nil
        }
    }

    func restartTimer() {
        deadline = now().addingTimeInterval(duration)
        if hoverStart != nil { hoverStart = now() }
    }

    func setThumbnail(_ image: NSImage?) {
        thumbnail = image
    }

    func markCopied() {
        copied = true
    }

    func setCopyTextLabel(_ label: String) {
        copyTextLabel = label
    }

    func dismiss() {
        isVisible = false
        screenshot = nil
        deadline = nil
        hoverStart = nil
    }

    static func metaText(appName: String?, screenshot: Screenshot) -> String {
        let name = appName ?? screenshot.name
        return "\(name) · \(screenshot.timeText) · \(screenshot.sizeText)"
    }
}

struct ToastView: View {
    let model: ToastModel
    let onAnnotate: () -> Void
    let onCopyText: () -> Void
    let onDelete: () -> Void
    let onThumbTap: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.glassBackground(radius: Theme.Radius.toast)

            HStack(spacing: 12) {
                thumb
                VStack(alignment: .leading, spacing: 3) {
                    header
                    if let screenshot = model.screenshot {
                        Text(ToastModel.metaText(appName: model.appName, screenshot: screenshot))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.secondary(0.6))
                            .lineLimit(1)
                    }
                    pills.padding(.top, 3)
                }
                .frame(minWidth: 0)
            }
            .padding(12)
        }
        .frame(width: Theme.Metrics.toastWidth)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.toast))
        .onHover(perform: onHover)
    }

    private var thumb: some View {
        ZStack {
            Color(red: 0xb7 / 255, green: 0xc7 / 255, blue: 0xdd / 255)
            if let thumbnail = model.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: 86, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        .onTapGesture(perform: onThumbTap)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Screenshot captured")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.label)

            if model.copied {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                    Text("copied")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Theme.greenText)
            }
        }
    }

    private var pills: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                PillButton(title: "Annotate", height: 22, fontSize: 10.5, weight: .medium, action: onAnnotate)
                PillButton(title: model.copyTextLabel, height: 22, fontSize: 10.5, weight: .medium, action: onCopyText)
                PillButton(title: "Delete", height: 22, fontSize: 10.5, weight: .medium, action: onDelete)
            }
        }
    }
}

/// Subscribes to `ScreenshotStore.newCapture`, the app's one sanctioned
/// Combine publisher, and owns the panel that shows for every capture. Built
/// once in the delegate's `applicationDidFinishLaunching`, before the
/// store's first capture can arrive.
@MainActor
final class ToastController {
    /// `showing` covers the slide-in as well as the settled card, because a
    /// capture arriving during either one is the same content swap. `dismissing`
    /// is distinct from `hidden` only for the 0.2 s the slide-out runs, and it
    /// is what tells a capture in that window to slide the panel back in rather
    /// than reposition a panel that is on its way offscreen.
    private enum Phase {
        case hidden, showing, dismissing
    }

    private let store: ScreenshotStore
    private let settings: SettingsStore
    private let model = ToastModel()
    private var panel: ToastPanel!
    private var phase = Phase.hidden
    private var cancellables = Set<AnyCancellable>()
    private var dismissWork: DispatchWorkItem?
    private let logger = Logger(subsystem: "com.shotput.app", category: "toast")

    init(store: ScreenshotStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        panel = ToastPanel(rootView: ToastView(
            model: model,
            onAnnotate: { [weak self] in self?.annotate() },
            onCopyText: { [weak self] in self?.copyText() },
            onDelete: { [weak self] in self?.delete() },
            onThumbTap: { [weak self] in self?.copyImage() },
            onHover: { [weak self] hovering in self?.setHovering(hovering) }
        ))

        store.newCapture
            .sink { [weak self] shot in self?.handle(shot) }
            .store(in: &cancellables)
    }

    private func handle(_ screenshot: Screenshot) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName
        let appName = (frontmost == nil || frontmost == "Shotput") ? nil : frontmost

        var copied = false
        if settings.autoCopyOnCapture {
            copied = Clipboard.copyImages([screenshot.url])
        }

        let onScreen = phase == .showing
        model.show(screenshot, appName: appName, copied: copied)
        phase = .showing
        scheduleDismiss()

        if onScreen {
            panel.reposition()
        } else {
            panel.present()
        }

        Task { [weak self] in
            let image = await ThumbnailCache.shared.thumbnail(for: screenshot.url)
            guard let self, self.model.screenshot?.id == screenshot.id else { return }
            self.model.setThumbnail(image)
        }
    }

    private func annotate() {
        guard let url = model.screenshot?.url else { return }
        ScreenshotActions.annotate(url)
        performDismiss()
    }

    private func copyImage() {
        guard let url = model.screenshot?.url else { return }
        if Clipboard.copyImages([url]) {
            model.markCopied()
        }
    }

    private func copyText() {
        guard let screenshot = model.screenshot else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await OCR.recognizeText(in: screenshot.url)
                if text.isEmpty {
                    self.model.setCopyTextLabel("No text")
                } else {
                    Clipboard.copyText(text)
                    self.model.markCopied()
                    self.model.setCopyTextLabel("Text copied")
                }
            } catch {
                self.model.setCopyTextLabel("No text")
                self.logger.error("OCR failed for \(screenshot.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            self.model.restartTimer()
            self.scheduleDismiss()
        }
    }

    private func delete() {
        guard let url = model.screenshot?.url else { return }
        do {
            try ScreenshotActions.trash([url])
            store.remove([url])
        } catch {
            logger.error("Failed to trash \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        performDismiss()
    }

    private func setHovering(_ hovering: Bool) {
        model.setHovering(hovering)
        if hovering {
            dismissWork?.cancel()
        } else {
            scheduleDismiss()
        }
    }

    private func scheduleDismiss() {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performDismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, model.remaining), execute: work)
    }

    private func performDismiss() {
        dismissWork?.cancel()
        guard phase == .showing else { return }
        phase = .dismissing
        panel.dismiss { [weak self] in
            self?.phase = .hidden
            self?.model.dismiss()
        }
    }
}
