import Testing
import Foundation
@testable import Shotput

@Suite @MainActor struct SettingsStoreTests {
    private let cloudKeyAccount = "ollamaCloudKey"

    @Test func freshDefaults() {
        let (defaults, name) = testSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let secrets = InMemorySecretStore()
        let store = SettingsStore(defaults: defaults, secrets: secrets)

        #expect(store.captureFolder.path.hasSuffix("/Desktop"))
        #expect(store.cleanupInterval == .week)
        #expect(store.cleanupAction == .trash)
        #expect(store.keepPinned == true)
        #expect(store.aiEnabled == false)
        #expect(store.aiProvider == .ollamaLocal)
        #expect(store.aiModel == "llava:13b")
        #expect(store.ollamaHost == "http://localhost:11434")
        #expect(store.sendToCloud == false)
        #expect(store.ollamaCloudKey == "")
        #expect(store.cloudKeySaveFailed == false)
        #expect(store.launchAtLogin == false)
        #expect(store.autoCopyOnCapture == true)
        #expect(store.hidesSystemThumbnail == false)
        #expect(store.onboardingComplete == false)
    }

    @Test func roundTrip() {
        let (defaults, name) = testSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let secrets = InMemorySecretStore()
        let first = SettingsStore(defaults: defaults, secrets: secrets)

        first.captureFolder = URL(fileURLWithPath: "/tmp/shots")
        first.cleanupInterval = .month
        first.cleanupAction = .delete
        first.keepPinned = false
        first.aiEnabled = true
        // sendToCloud must go on before .ollamaCloud, or the gate resets it.
        first.sendToCloud = true
        first.aiProvider = .ollamaCloud
        first.aiModel = "custom-model"
        first.ollamaHost = "http://example.com:1234"
        first.ollamaCloudKey = "round-trip-value"
        first.launchAtLogin = true
        first.autoCopyOnCapture = false
        first.hidesSystemThumbnail = true
        first.onboardingComplete = true

        let second = SettingsStore(defaults: defaults, secrets: secrets)
        #expect(second.captureFolder.path == "/tmp/shots")
        #expect(second.cleanupInterval == .month)
        #expect(second.cleanupAction == .delete)
        #expect(second.keepPinned == false)
        #expect(second.aiEnabled == true)
        #expect(second.aiProvider == .ollamaCloud)
        #expect(second.aiModel == "custom-model")
        #expect(second.ollamaHost == "http://example.com:1234")
        #expect(second.sendToCloud == true)
        #expect(second.ollamaCloudKey == "round-trip-value")
        #expect(second.launchAtLogin == true)
        #expect(second.autoCopyOnCapture == false)
        #expect(second.hidesSystemThumbnail == true)
        #expect(second.onboardingComplete == true)
    }

    @Test func badRawValueFallsBack() {
        let (defaults, name) = testSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let secrets = InMemorySecretStore()
        defaults.set("fortnight", forKey: "cleanupInterval")
        defaults.set("gpt", forKey: "aiProvider")

        let store = SettingsStore(defaults: defaults, secrets: secrets)
        #expect(store.cleanupInterval == .week)
        #expect(store.aiProvider == .ollamaLocal)
    }

    @Test func cloudOffRestrictsProviders() {
        let (defaults, name) = testSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let secrets = InMemorySecretStore()
        let store = SettingsStore(defaults: defaults, secrets: secrets)

        store.sendToCloud = false
        #expect(store.availableProviders == [.appleLocal, .ollamaLocal])

        store.sendToCloud = true
        #expect(store.availableProviders == AIProvider.allCases)
    }

    @Test func cloudOffResetsCloudProvider() {
        let (defaults, name) = testSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let secrets = InMemorySecretStore()
        let store = SettingsStore(defaults: defaults, secrets: secrets)

        store.sendToCloud = true
        store.aiProvider = .ollamaCloud
        store.sendToCloud = false
        #expect(store.aiProvider == .ollamaLocal)

        let (otherDefaults, otherName) = testSuite()
        defer { otherDefaults.removePersistentDomain(forName: otherName) }
        let other = SettingsStore(defaults: otherDefaults, secrets: InMemorySecretStore())
        other.sendToCloud = false
        other.aiProvider = .ollamaCloud
        #expect(other.aiProvider == .ollamaLocal)
    }

    @Test func cloudKeyRoundTripsThroughSecretStore() {
        let (defaults, name) = testSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let secrets = InMemorySecretStore()

        let first = SettingsStore(defaults: defaults, secrets: secrets)
        first.ollamaCloudKey = "stored-value"

        #expect(secrets.secret(for: cloudKeyAccount) == "stored-value")
        #expect(defaults.string(forKey: cloudKeyAccount) == nil)

        let second = SettingsStore(defaults: defaults, secrets: secrets)
        #expect(second.ollamaCloudKey == "stored-value")
    }

    @Test func clearingCloudKeyDropsTheSecret() {
        let (defaults, name) = testSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let secrets = InMemorySecretStore([cloudKeyAccount: "stored-value"])

        let store = SettingsStore(defaults: defaults, secrets: secrets)
        store.ollamaCloudKey = ""

        #expect(secrets.secret(for: cloudKeyAccount) == nil)
        #expect(SettingsStore(defaults: defaults, secrets: secrets).ollamaCloudKey == "")
    }

    @Test func migratesCloudKeyOutOfDefaults() {
        let (defaults, name) = testSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("migrated-value", forKey: cloudKeyAccount)
        let secrets = InMemorySecretStore()

        let store = SettingsStore(defaults: defaults, secrets: secrets)

        #expect(store.ollamaCloudKey == "migrated-value")
        #expect(secrets.secret(for: cloudKeyAccount) == "migrated-value")
        #expect(defaults.string(forKey: cloudKeyAccount) == nil)
    }

    @Test func failedSecretWriteLeavesTheDefaultsCopyInPlace() {
        let (defaults, name) = testSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("migrated-value", forKey: cloudKeyAccount)
        let secrets = InMemorySecretStore()
        secrets.writesFail = true

        let store = SettingsStore(defaults: defaults, secrets: secrets)

        #expect(store.ollamaCloudKey == "migrated-value")
        #expect(defaults.string(forKey: cloudKeyAccount) == "migrated-value")
        #expect(secrets.secret(for: cloudKeyAccount) == nil)
    }

    @Test func secondLaunchLeavesTheStoredKeyAlone() {
        let (defaults, name) = testSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let secrets = InMemorySecretStore([cloudKeyAccount: "kept-value"])

        let store = SettingsStore(defaults: defaults, secrets: secrets)

        #expect(store.ollamaCloudKey == "kept-value")
        #expect(secrets.secret(for: cloudKeyAccount) == "kept-value")
        #expect(secrets.writeCount == 0)
    }

    @Test func aRefusedWriteFlagsTheKeyUntilOneSucceeds() {
        let (defaults, name) = testSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let secrets = InMemorySecretStore()
        let store = SettingsStore(defaults: defaults, secrets: secrets)

        secrets.writesFail = true
        store.ollamaCloudKey = "stored-value"
        #expect(store.cloudKeySaveFailed == true)
        #expect(secrets.secret(for: cloudKeyAccount) == nil)

        secrets.writesFail = false
        store.ollamaCloudKey = "second-value"
        #expect(store.cloudKeySaveFailed == false)
        #expect(secrets.secret(for: cloudKeyAccount) == "second-value")
    }

    @Test func storedKeyBeatsAStalePlistCopy() {
        let (defaults, name) = testSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("stale-value", forKey: cloudKeyAccount)
        let secrets = InMemorySecretStore([cloudKeyAccount: "kept-value"])

        let store = SettingsStore(defaults: defaults, secrets: secrets)

        #expect(store.ollamaCloudKey == "kept-value")
        #expect(secrets.secret(for: cloudKeyAccount) == "kept-value")
        #expect(secrets.writeCount == 0)
        #expect(defaults.string(forKey: cloudKeyAccount) == nil)
    }

    @Test func buildingAStoreDoesNotTouchTheSecretStore() {
        let (defaults, name) = testSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("stale-value", forKey: cloudKeyAccount)
        let secrets = InMemorySecretStore([cloudKeyAccount: "kept-value"])

        let store = SettingsStore(defaults: defaults, secrets: secrets)
        #expect(secrets.readCount == 0)
        #expect(secrets.writeCount == 0)

        #expect(store.ollamaCloudKey == "kept-value")
        #expect(secrets.readCount > 0)
    }

    @Test func theKeyIsReadFromTheSecretStoreOnlyOnce() {
        let (defaults, name) = testSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let secrets = InMemorySecretStore([cloudKeyAccount: "kept-value"])
        let store = SettingsStore(defaults: defaults, secrets: secrets)

        #expect(store.ollamaCloudKey == "kept-value")
        #expect(store.ollamaCloudKey == "kept-value")
        #expect(secrets.readCount == 1)
    }

    /// The property is hand-rolled rather than a stored one, so the wiring
    /// that makes a new key restart the describe queue is worth its own test.
    @Test func changingTheKeyNotifiesObservers() async throws {
        let (defaults, name) = testSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        var changes = 0
        let token = ObservationLoop.track {
            _ = store.ollamaCloudKey
        } onChange: {
            changes += 1
        }
        defer { token.cancel() }

        store.ollamaCloudKey = "stored-value"
        #expect(await poll { changes == 1 })
    }

    /// `AIQueue` reads `store.ai` from `ShotputApp.init()`, before there is
    /// a window to explain a keychain ACL prompt, so only the provider that
    /// needs the key may pay for the read.
    @Test func aiSettingsReadTheKeychainOnlyForTheCloudProvider() {
        let (defaults, name) = testSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let secrets = InMemorySecretStore([cloudKeyAccount: "kept-value"])
        let store = SettingsStore(defaults: defaults, secrets: secrets)

        store.aiProvider = .ollamaLocal
        #expect(store.ai.cloudKey == "")
        #expect(secrets.readCount == 0)

        store.sendToCloud = true
        store.aiProvider = .ollamaCloud
        #expect(store.ai.cloudKey == "kept-value")
        #expect(secrets.readCount == 1)
    }

    @Test func theCloudGateWritesTheProviderItFellBackTo() {
        let (defaults, name) = testSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())

        store.aiProvider = .ollamaCloud

        #expect(store.aiProvider == .ollamaLocal)
        #expect(defaults.string(forKey: "aiProvider") == "ollamaLocal")
    }

    @Test func aStoredCloudProviderLoadsGatedWhenCloudIsOff() {
        let (defaults, name) = testSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("ollamaCloud", forKey: "aiProvider")
        defaults.set(false, forKey: "sendToCloud")

        #expect(SettingsStore(defaults: defaults, secrets: InMemorySecretStore()).aiProvider == .ollamaLocal)

        defaults.set(true, forKey: "sendToCloud")
        #expect(SettingsStore(defaults: defaults, secrets: InMemorySecretStore()).aiProvider == .ollamaCloud)
    }

    @Test func aKeySetBeforeAnyReadStillClearsTheCleartextCopy() {
        let (defaults, name) = testSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("stale-value", forKey: cloudKeyAccount)
        let secrets = InMemorySecretStore()

        let store = SettingsStore(defaults: defaults, secrets: secrets)
        store.ollamaCloudKey = "second-value"

        #expect(defaults.string(forKey: cloudKeyAccount) == nil)
        #expect(secrets.secret(for: cloudKeyAccount) == "second-value")
    }
}

/// Covers the two attribute dictionaries `KeychainSecretStore` hands to
/// `SecItemUpdate` and `SecItemAdd`. Pure builders, so nothing here goes
/// near a real keychain.
@Suite struct KeychainSecretStoreTests {
    private let data = Data("stored-value".utf8)

    @Test func updateCarriesTheSecretAndNothingElse() {
        let attributes = KeychainSecretStore.updateAttributes(data)

        #expect(attributes[kSecValueData as String] as? Data == data)
        #expect(attributes[kSecAttrAccessible as String] == nil)
        #expect(attributes.count == 1)
    }

    @Test func addSetsAccessibilityOnTheNewItem() {
        let attributes = KeychainSecretStore.addAttributes(data)

        #expect(attributes[kSecValueData as String] as? Data == data)
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
    }
}
