import Testing
@testable import Shotput

@Suite @MainActor struct HotkeyTests {
    @Test func controlShiftSConstants() {
        #expect(Hotkey.controlShiftS.keyCode == 1)
        #expect(Hotkey.controlShiftS.modifiers == 4608)
    }

    @Test func registersAndUnregisters() throws {
        // Carbon rejects a duplicate RegisterEventHotKey for a combo already
        // held in this process, so the two live registrations here use
        // different combos.
        var a: Hotkey? = try #require(Hotkey(keyCode: 1, modifiers: 4608) {})
        #expect(a?.isRegistered == true)

        let b = try #require(Hotkey(keyCode: 2, modifiers: 4608) {})
        #expect(b.isRegistered == true)

        // Hotkey has no explicit unregister(); deinit calls
        // UnregisterEventHotKey, which frees the combo for reuse.
        a = nil

        let again = try #require(Hotkey(keyCode: 1, modifiers: 4608) {})
        #expect(again.isRegistered == true)
    }
}
