import Combine
import Foundation
import Observation

@Observable
@MainActor
final class ScreenshotStore {
    nonisolated static var defaultPinsFile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Shotput", isDirectory: true).appendingPathComponent("pins.json")
    }

    private(set) var shots: [Screenshot] = []
    private(set) var days: [ScreenshotDay] = []
    private(set) var pinnedURLs: Set<URL> = []

    @ObservationIgnored let newCapture = PassthroughSubject<Screenshot, Never>()

    private let settings: SettingsStore
    private let pinsFile: URL
    private var watcher: FolderWatcher?
    private var watchedFolder: URL?
    private var folderObservationToken: ObservationToken?
    /// The scan done by `start()` and the one right after a folder change
    /// must not announce every existing file as a new capture; every other
    /// rescan (a real FSEvents callback) should.
    private var suppressNextCapture = true
    @ObservationIgnored private var shotIndex: [URL: Int] = [:]
    @ObservationIgnored private var dayLabels: [Date: String] = [:]
    @ObservationIgnored private var dayLabelsDay: Date?

    init(settings: SettingsStore, pinsFile: URL = ScreenshotStore.defaultPinsFile) {
        self.settings = settings
        self.pinsFile = pinsFile
        pinnedURLs = Self.loadPins(from: pinsFile)
    }

    var countText: String {
        "\(shots.count) on \(settings.captureFolder.lastPathComponent)"
    }

    func start() {
        rescan()
        watchFolder(settings.captureFolder)
        folderObservationToken = ObservationLoop.track { [settings] in
            _ = settings.captureFolder
        } onChange: { [weak self] in
            guard let self else { return }
            watchFolder(settings.captureFolder)
            suppressNextCapture = true
            rescan()
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        watchedFolder = nil
        folderObservationToken?.cancel()
        folderObservationToken = nil
    }

    func rescan() {
        let folder = settings.captureFolder
        let previous = Dictionary(uniqueKeysWithValues: shots.map { ($0.url, $0) })
        let fileManager = FileManager.default

        let urls = (try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var found: [Screenshot] = []
        for url in urls where ScreenshotDetection.hasImageExtension(url) {
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
            let created = values?.creationDate ?? values?.contentModificationDate ?? Date()
            let byteSize = Int64(values?.fileSize ?? 0)

            // getxattr is the one per-file syscall the directory listing
            // can't supply, and a known path whose size and creation date
            // both still match is the same file, so it needs no second look.
            let existing = previous[url]
            let unchanged = existing.map { $0.created == created && $0.byteSize == byteSize } ?? false
            guard unchanged || ScreenshotDetection.isScreenshot(url) else { continue }

            var shot = Screenshot(url: url, created: created, byteSize: byteSize)
            if let existing {
                shot.title = existing.title
                shot.summary = existing.summary
                shot.describedBy = existing.describedBy
            }
            shot.isPinned = pinnedURLs.contains(url)
            found.append(shot)
        }

        // Rescan runs on every FSEvents callback, and pins rarely change,
        // so the file is only rewritten when the set actually shrank.
        let foundURLs = Set(found.map(\.url))
        let stillPresent = pinnedURLs.intersection(foundURLs)
        if stillPresent != pinnedURLs {
            pinnedURLs = stillPresent
            savePins()
        }

        let shouldEmit = !suppressNextCapture
        suppressNextCapture = false
        shots = found.sorted { $0.created > $1.created }
        shotsDidChange()

        guard shouldEmit else { return }
        for shot in found where previous[shot.url] == nil {
            newCapture.send(shot)
        }
    }

    func shot(for url: URL) -> Screenshot? {
        shots.first { $0.url == url }
    }

    func applyDescription(for url: URL, title: String, summary: String, describedBy: String) {
        guard let index = shotIndex[url] else { return }
        shots[index].title = title
        shots[index].summary = summary
        shots[index].describedBy = describedBy
        shotsDidChange()
    }

    /// The bulk form: a relaunch has a stored description for every shot,
    /// and one pass here costs one rebuild instead of one per screenshot.
    func applyDescriptions(_ descriptions: [URL: (title: String, summary: String, describedBy: String)]) {
        var updated = shots
        var changed = false
        for index in updated.indices {
            guard let description = descriptions[updated[index].url] else { continue }
            updated[index].title = description.title
            updated[index].summary = description.summary
            updated[index].describedBy = description.describedBy
            changed = true
        }
        guard changed else { return }
        shots = updated
        shotsDidChange()
    }

    func togglePin(_ url: URL) {
        if pinnedURLs.contains(url) {
            setPinned(false, for: [url])
        } else {
            setPinned(true, for: [url])
        }
    }

    func setPinned(_ pinned: Bool, for urls: [URL]) {
        for url in urls {
            if pinned {
                pinnedURLs.insert(url)
            } else {
                pinnedURLs.remove(url)
            }
            if let index = shotIndex[url] {
                shots[index].isPinned = pinned
            }
        }
        shotsDidChange()
        savePins()
    }

    func remove(_ urls: [URL]) {
        let urlSet = Set(urls)
        shots.removeAll { urlSet.contains($0.url) }
        shotsDidChange()
        pinnedURLs.subtract(urlSet)
        savePins()
        for url in urls {
            ThumbnailCache.shared.evict(url)
        }
    }

    private func watchFolder(_ folder: URL) {
        guard watchedFolder != folder else { return }
        watcher?.stop()
        watchedFolder = folder
        let newWatcher = FolderWatcher(folder: folder) { [weak self] in
            self?.rescan()
        }
        newWatcher.start()
        watcher = newWatcher
    }

    private func savePins() {
        let directory = pinsFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let paths = pinnedURLs.map(\.path)
        guard let data = try? JSONEncoder().encode(paths) else { return }
        try? data.write(to: pinsFile, options: .atomic)
    }

    private static func loadPins(from file: URL) -> Set<URL> {
        guard let data = try? Data(contentsOf: file),
              let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(paths.map { URL(fileURLWithPath: $0) })
    }

    /// Everything derived from `shots` is rebuilt here, so there is one
    /// place a new mutation has to remember to call.
    private func shotsDidChange() {
        shotIndex = Dictionary(uniqueKeysWithValues: shots.enumerated().map { ($1.url, $0) })

        let calendar = Calendar.current
        let grouped = Dictionary(grouping: shots) { calendar.startOfDay(for: $0.created) }
        days = grouped.keys.sorted(by: >).map { day in
            ScreenshotDay(id: day, label: cachedLabel(for: day, calendar: calendar), shots: grouped[day] ?? [])
        }
    }

    private func cachedLabel(for day: Date, calendar: Calendar) -> String {
        // "Today" and "Yesterday" are only right relative to the day the
        // labels were made, so the cache is dropped when that day rolls over.
        let today = calendar.startOfDay(for: Date())
        if dayLabelsDay != today {
            dayLabels.removeAll()
            dayLabelsDay = today
        }
        if let cached = dayLabels[day] { return cached }
        let label = Self.label(for: day, calendar: calendar)
        dayLabels[day] = label
        return label
    }

    private static func label(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return dayFormatter.string(from: day)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f
    }()
}
