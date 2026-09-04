import Testing
import Foundation
@testable import Shotput

@Suite @MainActor struct SettingsViewModelTests {
    @Test func aiSectionTitleUsesProviderLabel() {
        let (settings, defaults, name) = testSettingsWithSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let viewModel = SettingsViewModel(settings: settings)

        settings.aiEnabled = false
        #expect(viewModel.aiSectionTitle == "AI")

        settings.aiEnabled = true
        settings.aiModel = "llava:13b"
        settings.sendToCloud = true
        settings.aiProvider = .ollamaCloud
        #expect(viewModel.aiSectionTitle == "AI · " + AIProvider.ollamaCloud.label.uppercased())
        #expect(!viewModel.aiSectionTitle.contains("LLAVA"))

        settings.aiProvider = .appleLocal
        #expect(viewModel.aiSectionTitle == "AI · " + AIProvider.appleLocal.label.uppercased())
    }

    @Test func selectedChoiceTracksProvider() {
        let (settings, defaults, name) = testSettingsWithSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let viewModel = SettingsViewModel(settings: settings)

        settings.sendToCloud = true
        settings.aiModel = "llava:13b"
        settings.aiProvider = .ollamaCloud

        #expect(viewModel.selectedChoice.id == .ollamaCloud)
        #expect(viewModel.selectedChoice.displayName == "llava:13b · Ollama Cloud")
    }

    @Test func cloudChoiceDisabledWhenCloudOff() {
        let (settings, defaults, name) = testSettingsWithSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let viewModel = SettingsViewModel(settings: settings)

        settings.sendToCloud = false
        #expect(viewModel.choices.map(\.id) == AIProvider.allCases)
        let cloudChoice = viewModel.choices.first { $0.id == .ollamaCloud }!
        #expect(cloudChoice.isEnabled == false)
        #expect(cloudChoice.disabledReason != nil)
        let localChoice = viewModel.choices.first { $0.id == .ollamaLocal }!
        #expect(localChoice.isEnabled == true)

        settings.sendToCloud = true
        let enabledCloudChoice = viewModel.choices.first { $0.id == .ollamaCloud }!
        #expect(enabledCloudChoice.isEnabled == true)
    }

    @Test func conditionalRows() {
        let (settings, defaults, name) = testSettingsWithSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let viewModel = SettingsViewModel(settings: settings)

        settings.aiProvider = .appleLocal
        #expect(viewModel.showsModelNameRow == false)
        #expect(viewModel.showsOllamaHostRow == false)
        #expect(viewModel.showsCloudKeyRow == false)

        settings.aiProvider = .ollamaLocal
        #expect(viewModel.showsModelNameRow == true)
        #expect(viewModel.showsOllamaHostRow == true)
        #expect(viewModel.showsCloudKeyRow == false)

        settings.sendToCloud = true
        settings.aiProvider = .ollamaCloud
        #expect(viewModel.showsModelNameRow == true)
        #expect(viewModel.showsOllamaHostRow == false)
        #expect(viewModel.showsCloudKeyRow == true)
    }

    @Test func cleanupSubtitleOnlyForTrash() {
        let (settings, defaults, name) = testSettingsWithSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let viewModel = SettingsViewModel(settings: settings)

        settings.cleanupAction = .trash
        #expect(viewModel.cleanupSubtitle == "Recoverable from Trash for 30 more days")

        settings.cleanupAction = .delete
        #expect(viewModel.cleanupSubtitle == nil)
    }

    @Test func cleanupSettingsRoundTrip() {
        let (settings, defaults, name) = testSettingsWithSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        _ = SettingsViewModel(settings: settings)

        settings.cleanupInterval = .month
        settings.cleanupAction = .delete

        let second = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        #expect(second.cleanupInterval == .month)
        #expect(second.cleanupAction == .delete)

        let secondViewModel = SettingsViewModel(settings: second)
        #expect(secondViewModel.cleanupSubtitle == nil)
    }

    @Test func syncFolderAdoptsSystemValue() {
        let (settings, defaults, name) = testSettingsWithSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let systemFolder = URL(fileURLWithPath: "/tmp/elsewhere")
        let viewModel = SettingsViewModel(settings: settings, readLocation: { systemFolder })

        #expect(settings.captureFolder.path.hasSuffix("/Desktop"))
        viewModel.syncFolder()
        #expect(settings.captureFolder.path == "/tmp/elsewhere")
    }

    @Test func applyFolderWritesSystemThenStore() {
        let (settings, defaults, name) = testSettingsWithSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        var written: [URL] = []
        let viewModel = SettingsViewModel(settings: settings, writeLocation: { written.append($0) })

        let target = URL(fileURLWithPath: "/tmp/shots")
        viewModel.applyFolder(target)

        #expect(written == [target])
        #expect(settings.captureFolder == target)
        #expect(viewModel.lastError == nil)
    }

    @Test func applyFolderKeepsOldFolderOnWriteError() {
        let (settings, defaults, name) = testSettingsWithSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let originalFolder = settings.captureFolder
        let viewModel = SettingsViewModel(settings: settings, writeLocation: { _ in throw CaptureLocationError.syncFailed })

        viewModel.applyFolder(URL(fileURLWithPath: "/tmp/shots"))

        #expect(settings.captureFolder == originalFolder)
        #expect(viewModel.lastError != nil)
    }

    @Test func syncThumbnailAdoptsSystemValue() {
        let (settings, defaults, name) = testSettingsWithSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        var systemShowsThumbnail = false
        let viewModel = SettingsViewModel(settings: settings, readShowsThumbnail: { systemShowsThumbnail })

        #expect(settings.hidesSystemThumbnail == false)
        viewModel.syncThumbnail()
        #expect(settings.hidesSystemThumbnail == true)

        systemShowsThumbnail = true
        viewModel.syncThumbnail()
        #expect(settings.hidesSystemThumbnail == false)
    }

    @Test func hidingThumbnailWritesSystemThenStore() {
        let (settings, defaults, name) = testSettingsWithSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        var written: [Bool] = []
        let viewModel = SettingsViewModel(settings: settings, writeShowsThumbnail: { written.append($0) })

        viewModel.setHidesSystemThumbnail(true)
        #expect(written == [false])
        #expect(settings.hidesSystemThumbnail == true)
        #expect(viewModel.lastError == nil)

        viewModel.setHidesSystemThumbnail(false)
        #expect(written == [false, true])
        #expect(settings.hidesSystemThumbnail == false)
    }

    @Test func thumbnailKeepsStoreOnWriteError() {
        let (settings, defaults, name) = testSettingsWithSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let viewModel = SettingsViewModel(
            settings: settings,
            writeShowsThumbnail: { _ in throw CaptureLocationError.syncFailed }
        )

        viewModel.setHidesSystemThumbnail(true)

        #expect(settings.hidesSystemThumbnail == false)
        #expect(viewModel.lastError != nil)
    }

    @Test func launchAtLoginRevertsOnError() {
        let (settings, defaults, name) = testSettingsWithSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        struct LoginItemError: Error {}
        var recorded: [Bool] = []
        var shouldThrow = true
        let viewModel = SettingsViewModel(settings: settings, setLoginItem: { on in
            recorded.append(on)
            if shouldThrow { throw LoginItemError() }
        })

        viewModel.setLaunchAtLogin(true)
        #expect(settings.launchAtLogin == false)
        #expect(viewModel.lastError != nil)

        shouldThrow = false
        viewModel.setLaunchAtLogin(true)
        #expect(settings.launchAtLogin == true)
        #expect(recorded == [true, true])
    }

    // MARK: - AI status

    @Test func statusHeadlineCountsEveryScreenshotTheQueueKnowsAbout() {
        #expect(SettingsViewModel.statusHeadline(status(described: 140, pending: 8, failed: 2)) == "140 of 150 described")
        #expect(SettingsViewModel.statusHeadline(status(described: 1, pending: 0, failed: 0)) == "1 of 1 described")
        #expect(SettingsViewModel.statusHeadline(status()) == "Nothing described yet")
    }

    @Test func statusDetailNamesWhatTheQueueIsDoing() {
        #expect(SettingsViewModel.statusDetail(status(described: 5), aiEnabled: false) == "AI is off")
        #expect(SettingsViewModel.statusDetail(status(pending: 3), aiEnabled: false) == "AI is off · 3 pending")
        #expect(SettingsViewModel.statusDetail(status(pending: 3, blockedReason: "no key"), aiEnabled: true) == "Paused · 3 pending")
        #expect(SettingsViewModel.statusDetail(status(pending: 3, isRunning: true), aiEnabled: true) == "Describing now · 3 pending")
        #expect(SettingsViewModel.statusDetail(status(pending: 3), aiEnabled: true) == "Waiting to start · 3 pending")
        #expect(SettingsViewModel.statusDetail(status(described: 9, failed: 2), aiEnabled: true) == "Nothing pending")
        #expect(SettingsViewModel.statusDetail(status(described: 9), aiEnabled: true) == "Up to date")
    }

    @Test func statusNotePrefersTheBlockedReason() {
        let both = status(blockedReason: "Add an Ollama Cloud API key in Settings", lastError: "Server returned 500")
        #expect(SettingsViewModel.statusNote(both, aiEnabled: true) == "Add an Ollama Cloud API key in Settings")
        #expect(SettingsViewModel.statusNote(status(lastError: "Server returned 500"), aiEnabled: true) == "Server returned 500")
        #expect(SettingsViewModel.statusNote(status(), aiEnabled: true) == nil)
        // Off is not a problem to report: the detail line already says it.
        #expect(SettingsViewModel.statusNote(both, aiEnabled: false) == nil)
    }

    @Test func failureTextCountsAndAges() {
        #expect(SettingsViewModel.failureSummary(count: 1) == "1 screenshot gave up")
        #expect(SettingsViewModel.failureSummary(count: 4) == "4 screenshots gave up")

        let now = Date()
        let item = AIFailureItem(
            url: URL(fileURLWithPath: "/tmp/shot.png"),
            reason: "Can't reach http://127.0.0.1:11434",
            failedAt: now.addingTimeInterval(-7200),
            attempts: 3
        )
        #expect(SettingsViewModel.failureDetail(item, now: now) == "Can't reach http://127.0.0.1:11434 · 2 h ago")
    }

    @Test func reindexWarningWarnsAboutUploadsOnlyForCloud() {
        let local = SettingsViewModel.reindexWarning(describedCount: 12, provider: "Apple on-device", isCloud: false)
        #expect(local == "This throws away the 12 descriptions Shotput already has and asks Apple on-device for new ones.")
        #expect(!local.contains("uploaded"))

        let cloud = SettingsViewModel.reindexWarning(describedCount: 12, provider: "llava:13b · Ollama Cloud", isCloud: true)
        #expect(cloud.contains("llava:13b · Ollama Cloud"))
        #expect(cloud.hasSuffix("Every screenshot is uploaded again."))

        #expect(SettingsViewModel.reindexWarning(describedCount: 1, provider: "p", isCloud: false)
            .contains("the 1 description Shotput already has"))
    }

    @Test func failureListIsCappedNewestFirst() throws {
        let (settings, defaults, name) = testSettingsWithSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let dir = try makeTempDir("ai-status")
        defer { try? FileManager.default.removeItem(at: dir) }

        let ai = makeCoordinator(settings: settings, dir: dir, failures: 7)
        let viewModel = SettingsViewModel(settings: settings, ai: ai)

        #expect(viewModel.aiFailures.count == 7)
        #expect(viewModel.listedFailures.count == SettingsViewModel.maxListedFailures)
        #expect(viewModel.hiddenFailureCount == 7 - SettingsViewModel.maxListedFailures)
        // Newest first: failure i is i hours old, so 0 is the freshest.
        #expect(viewModel.listedFailures.map { $0.url.lastPathComponent } == ["failed-0.png", "failed-1.png", "failed-2.png"])

        let few = makeCoordinator(settings: settings, dir: dir, failures: 2)
        let fewModel = SettingsViewModel(settings: settings, ai: few)
        #expect(fewModel.listedFailures.count == 2)
        #expect(fewModel.hiddenFailureCount == 0)
    }

    @Test func reindexOfferedOnlyWhenTheQueueCouldReplaceDescriptions() throws {
        let (settings, defaults, name) = testSettingsWithSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let dir = try makeTempDir("ai-status-reindex")
        defer { try? FileManager.default.removeItem(at: dir) }
        settings.aiEnabled = true
        settings.aiProvider = .appleLocal

        let ready = SettingsViewModel(settings: settings, ai: makeCoordinator(settings: settings, dir: dir, described: 3))
        #expect(ready.canReindexAll)

        settings.aiEnabled = false
        #expect(!ready.canReindexAll)
        settings.aiEnabled = true

        let empty = SettingsViewModel(settings: settings, ai: makeCoordinator(settings: settings, dir: dir))
        #expect(!empty.canReindexAll)

        let blocked = SettingsViewModel(
            settings: settings,
            ai: makeCoordinator(settings: settings, dir: dir, described: 3, appleAvailable: false)
        )
        #expect(!blocked.canReindexAll)
        #expect(blocked.aiStatusNote == "Apple Intelligence is off")
    }

    @Test func isDescribingOnlyWhileTheQueueCanActuallyRun() throws {
        let (settings, defaults, name) = testSettingsWithSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let dir = try makeTempDir("ai-status-describing")
        defer { try? FileManager.default.removeItem(at: dir) }
        settings.aiEnabled = true
        settings.aiProvider = .appleLocal

        let ai = makeCoordinator(settings: settings, dir: dir, described: 2)
        let viewModel = SettingsViewModel(settings: settings, ai: ai)
        #expect(!viewModel.isDescribing)

        // `kick` turns isRunning on before its worker gets a turn, which is
        // the state a busy queue is rendered in.
        ai.queue.kick()
        #expect(viewModel.isDescribing)

        // Running but with nowhere to send the images: the registry blocks
        // it, so the spinner must not claim work is happening.
        settings.sendToCloud = true
        settings.aiProvider = .ollamaCloud
        #expect(viewModel.aiStatus?.isRunning == true)
        #expect(viewModel.aiStatus?.blockedReason != nil)
        #expect(!viewModel.isDescribing)
    }

    @Test func retryingSendsFailuresBackThroughTheQueue() throws {
        let (settings, defaults, name) = testSettingsWithSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let dir = try makeTempDir("ai-status-retry")
        defer { try? FileManager.default.removeItem(at: dir) }

        let ai = makeCoordinator(settings: settings, dir: dir, failures: 3)
        let viewModel = SettingsViewModel(settings: settings, ai: ai)

        let first = try #require(viewModel.aiFailures.first)
        viewModel.retryFailure(first.url)
        #expect(viewModel.aiFailures.count == 2)
        #expect(!viewModel.aiFailures.contains { $0.url == first.url })

        viewModel.retryAllFailed()
        #expect(viewModel.aiFailures.isEmpty)
        #expect(viewModel.aiStatus?.failedCount == 0)
    }

    @Test func noCoordinatorMeansNoStatusSection() {
        let (settings, defaults, name) = testSettingsWithSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let viewModel = SettingsViewModel(settings: settings)

        #expect(viewModel.aiStatus == nil)
        #expect(viewModel.aiFailures.isEmpty)
        #expect(viewModel.listedFailures.isEmpty)
        #expect(viewModel.hiddenFailureCount == 0)
        #expect(viewModel.aiStatusHeadline.isEmpty)
        #expect(viewModel.aiStatusNote == nil)
        #expect(!viewModel.isDescribing)
        #expect(!viewModel.canReindexAll)
    }

    @Test func commitCloudKeyWritesOncePerChange() {
        let (defaults, name) = testSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let secrets = InMemorySecretStore()
        let settings = SettingsStore(defaults: defaults, secrets: secrets)
        let viewModel = SettingsViewModel(settings: settings)

        viewModel.commitCloudKey("stored-value")
        #expect(settings.ollamaCloudKey == "stored-value")
        #expect(secrets.writeCount == 1)

        viewModel.commitCloudKey("stored-value")
        #expect(secrets.writeCount == 1)

        viewModel.commitCloudKey("second-value")
        #expect(settings.ollamaCloudKey == "second-value")
        #expect(secrets.writeCount == 2)
    }

    @Test func cloudKeySubtitleReportsARefusedWrite() {
        let (defaults, name) = testSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let secrets = InMemorySecretStore()
        let settings = SettingsStore(defaults: defaults, secrets: secrets)
        let viewModel = SettingsViewModel(settings: settings)

        settings.ollamaCloudKey = "stored-value"
        #expect(viewModel.cloudKeySubtitle == "Sent as a Bearer token to ollama.com")

        secrets.writesFail = true
        settings.ollamaCloudKey = "second-value"
        #expect(viewModel.cloudKeySubtitle.hasPrefix("Not saved."))

        secrets.writesFail = false
        settings.ollamaCloudKey = "third-value"
        #expect(viewModel.cloudKeySubtitle == "Sent as a Bearer token to ollama.com")
    }
}

private func status(
    described: Int = 0,
    pending: Int = 0,
    failed: Int = 0,
    isRunning: Bool = false,
    blockedReason: String? = nil,
    lastError: String? = nil
) -> AIStatus {
    AIStatus(
        describedCount: described,
        pendingCount: pending,
        failedCount: failed,
        isRunning: isRunning,
        blockedReason: blockedReason,
        lastError: lastError
    )
}

/// A coordinator over a throwaway index, seeded straight into the index so
/// no provider ever has to run.
@MainActor
private func makeCoordinator(
    settings: SettingsStore,
    dir: URL,
    described: Int = 0,
    failures: Int = 0,
    appleAvailable: Bool = true
) -> AICoordinator {
    var registry = ProviderRegistry()
    registry.appleAvailable = { appleAvailable }
    registry.appleUnavailableReason = { "Apple Intelligence is off" }

    let index = AIIndex(fileURL: dir.appendingPathComponent("\(UUID().uuidString).json"))
    let store = ScreenshotStore(settings: settings, pinsFile: dir.appendingPathComponent("pins.json"))
    let ai = AICoordinator(settings: settings, store: store, index: index, registry: registry)

    for i in 0..<described {
        index.set(
            AIRecord(title: "t\(i)", summary: "s\(i)", describedBy: "m", describedAt: Date(), embedderID: nil, vector: nil),
            for: dir.appendingPathComponent("described-\(i).png")
        )
    }
    for i in 0..<failures {
        index.setFailure(
            AIFailure(reason: "Can't reach http://127.0.0.1:11434", failedAt: Date().addingTimeInterval(-3600 * Double(i)), attempts: 3),
            for: dir.appendingPathComponent("failed-\(i).png")
        )
    }
    return ai
}
