import Foundation
import Observation
import os

enum AIProvider: String, CaseIterable, Identifiable {
    case appleLocal, ollamaLocal, ollamaCloud

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleLocal: "Apple on-device"
        case .ollamaLocal: "Ollama (local)"
        case .ollamaCloud: "Ollama Cloud"
        }
    }

    var sendsToCloud: Bool { self == .ollamaCloud }
}

/// UserDefaults-backed app settings. Every property writes itself to
/// `defaults` on set and reads itself back in `init`, so it stays the single
/// source of truth across launches without a separate persistence layer. The
/// cloud key is the one exception: it goes to the injected `SecretStore`.
@Observable
@MainActor
final class SettingsStore {
    private enum Key: String {
        case captureFolder, cleanupInterval, cleanupAction, keepPinned
        case aiEnabled, aiProvider, aiModel, ollamaHost, sendToCloud
        // Names the keychain account, and the stale plist entry the migration
        // in `loadCloudKey` clears out. Nothing else may write to it.
        case ollamaCloudKey
        case launchAtLogin, autoCopyOnCapture, hidesSystemThumbnail, onboardingComplete
        case saveFolderConfirmed, trashAccessVerified
    }

    private static let logger = Logger(subsystem: "com.shotput.app", category: "settings")

    private let defaults: UserDefaults
    private let secrets: SecretStore

    var captureFolder: URL {
        didSet { defaults.set(captureFolder.path, forKey: Key.captureFolder.rawValue) }
    }
    var cleanupInterval: CleanupInterval {
        didSet { defaults.set(cleanupInterval.rawValue, forKey: Key.cleanupInterval.rawValue) }
    }
    var cleanupAction: CleanupAction {
        didSet { defaults.set(cleanupAction.rawValue, forKey: Key.cleanupAction.rawValue) }
    }
    var keepPinned: Bool {
        didSet { defaults.set(keepPinned, forKey: Key.keepPinned.rawValue) }
    }
    var aiEnabled: Bool {
        didSet { defaults.set(aiEnabled, forKey: Key.aiEnabled.rawValue) }
    }
    var aiProvider: AIProvider {
        didSet {
            // Cloud gating: no UI path may leave .ollamaCloud selected while
            // sendToCloud is off, so it lands back on Ollama local here.
            // Assigning here does not re-enter this observer, so the
            // corrected value has to be the one that gets written.
            if aiProvider == .ollamaCloud, !sendToCloud {
                aiProvider = .ollamaLocal
            }
            defaults.set(aiProvider.rawValue, forKey: Key.aiProvider.rawValue)
        }
    }
    var aiModel: String {
        didSet { defaults.set(aiModel, forKey: Key.aiModel.rawValue) }
    }
    var ollamaHost: String {
        didSet { defaults.set(ollamaHost, forKey: Key.ollamaHost.rawValue) }
    }
    var sendToCloud: Bool {
        didSet {
            defaults.set(sendToCloud, forKey: Key.sendToCloud.rawValue)
            if !sendToCloud, aiProvider == .ollamaCloud {
                aiProvider = .ollamaLocal
            }
        }
    }
    /// Read on first use rather than in `init`: the keychain call blocks on
    /// an ACL dialog, and at launch there is no window yet to explain the
    /// wait. Main-actor isolation is what keeps the one-time migration
    /// inside it safe from a second access arriving mid-read.
    @ObservationIgnored private var cloudKeyCache: String?

    var ollamaCloudKey: String {
        get {
            access(keyPath: \.ollamaCloudKey)
            if let cloudKeyCache { return cloudKeyCache }
            let key = Self.loadCloudKey(defaults: defaults, secrets: secrets)
            cloudKeyCache = key
            return key
        }
        set {
            withMutation(keyPath: \.ollamaCloudKey) {
                cloudKeyCache = newValue
                let account = Key.ollamaCloudKey.rawValue
                let saved = newValue.isEmpty
                    ? secrets.removeSecret(for: account)
                    : secrets.setSecret(newValue, for: account)
                if saved {
                    // A key stored before anything reads one never runs the
                    // migration, and its cleartext copy would outlive it.
                    defaults.removeObject(forKey: account)
                } else {
                    Self.logger.error("Keychain refused the cloud key; it will not survive quit")
                }
                cloudKeySaveFailed = !saved
            }
        }
    }
    /// The keychain refused the last write, so what the field shows is only
    /// in memory and dies with the process. Reachable in practice: the app
    /// is ad-hoc signed, so every rebuild is an unrecognised caller and the
    /// user gets an ACL prompt they can deny.
    private(set) var cloudKeySaveFailed = false
    var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin.rawValue) }
    }
    var autoCopyOnCapture: Bool {
        didSet { defaults.set(autoCopyOnCapture, forKey: Key.autoCopyOnCapture.rawValue) }
    }
    var hidesSystemThumbnail: Bool {
        didSet { defaults.set(hidesSystemThumbnail, forKey: Key.hidesSystemThumbnail.rawValue) }
    }
    var onboardingComplete: Bool {
        didSet { defaults.set(onboardingComplete, forKey: Key.onboardingComplete.rawValue) }
    }
    var saveFolderConfirmed: Bool {
        didSet { defaults.set(saveFolderConfirmed, forKey: Key.saveFolderConfirmed.rawValue) }
    }
    var trashAccessVerified: Bool {
        didSet { defaults.set(trashAccessVerified, forKey: Key.trashAccessVerified.rawValue) }
    }

    /// Providers the cloud gate allows right now. Setting `sendToCloud` and
    /// `aiProvider` above enforces the same rule, so this is the only place
    /// UI needs to read.
    var availableProviders: [AIProvider] {
        sendToCloud ? AIProvider.allCases : [.appleLocal, .ollamaLocal]
    }

    init(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets

        let path = defaults.string(forKey: Key.captureFolder.rawValue)
        captureFolder = path.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")

        cleanupInterval = defaults.string(forKey: Key.cleanupInterval.rawValue)
            .flatMap(CleanupInterval.init(rawValue:)) ?? .week
        cleanupAction = defaults.string(forKey: Key.cleanupAction.rawValue)
            .flatMap(CleanupAction.init(rawValue:)) ?? .trash
        keepPinned = defaults.object(forKey: Key.keepPinned.rawValue) as? Bool ?? true
        aiEnabled = defaults.object(forKey: Key.aiEnabled.rawValue) as? Bool ?? false
        // Both read into locals first: an `@Observable` property's getter
        // touches `self`, which init can't do until every stored property
        // has a value.
        let cloudAllowed = defaults.object(forKey: Key.sendToCloud.rawValue) as? Bool ?? false
        let storedProvider = defaults.string(forKey: Key.aiProvider.rawValue)
            .flatMap(AIProvider.init(rawValue:)) ?? .ollamaLocal
        sendToCloud = cloudAllowed
        // Observers don't run during init, so the cloud gate the setter
        // enforces is applied to the stored pair by hand: a plist holding
        // .ollamaCloud with sendToCloud off must not load with the
        // invariant already broken.
        aiProvider = storedProvider == .ollamaCloud && !cloudAllowed ? .ollamaLocal : storedProvider
        aiModel = defaults.string(forKey: Key.aiModel.rawValue) ?? "llava:13b"
        ollamaHost = defaults.string(forKey: Key.ollamaHost.rawValue) ?? "http://localhost:11434"
        launchAtLogin = defaults.object(forKey: Key.launchAtLogin.rawValue) as? Bool ?? false
        autoCopyOnCapture = defaults.object(forKey: Key.autoCopyOnCapture.rawValue) as? Bool ?? true
        hidesSystemThumbnail = defaults.object(forKey: Key.hidesSystemThumbnail.rawValue) as? Bool ?? false
        onboardingComplete = defaults.object(forKey: Key.onboardingComplete.rawValue) as? Bool ?? false
        saveFolderConfirmed = defaults.object(forKey: Key.saveFolderConfirmed.rawValue) as? Bool ?? false
        trashAccessVerified = defaults.object(forKey: Key.trashAccessVerified.rawValue) as? Bool ?? false
    }

    /// The keychain wins: nothing but this migration writes the plist entry,
    /// so a stored key is always at least as fresh, and a plist copy that
    /// outlived its migration (the removal flushes through cfprefsd
    /// asynchronously) would otherwise overwrite a newer key. When the
    /// keychain is empty the plist value moves across, but only loses its
    /// cleartext copy once the write reads back.
    private static func loadCloudKey(defaults: UserDefaults, secrets: SecretStore) -> String {
        let account = Key.ollamaCloudKey.rawValue
        if let stored = secrets.secret(for: account), !stored.isEmpty {
            defaults.removeObject(forKey: account)
            return stored
        }
        guard let stale = defaults.string(forKey: account), !stale.isEmpty else { return "" }
        secrets.setSecret(stale, for: account)
        if secrets.secret(for: account) == stale {
            defaults.removeObject(forKey: account)
        }
        return stale
    }
}
