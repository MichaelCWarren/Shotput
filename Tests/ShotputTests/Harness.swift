import Foundation

/// Minimal assertion harness. `swift test` cannot run on this machine (see
/// Package.swift), so tests are an executable that exits 1 on any failure.
enum T {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func expect(_ condition: Bool, _ what: String, file: String = #fileID, line: Int = #line) {
        checks += 1
        guard !condition else { return }
        failures += 1
        print("FAIL \(file):\(line) — \(what)")
    }

    static func equal<V: Equatable>(_ got: V, _ want: V, _ what: String, file: String = #fileID, line: Int = #line) {
        expect(got == want, "\(what) — got \(got), want \(want)", file: file, line: line)
    }

    static func finish() -> Never {
        print(failures == 0 ? "PASS \(checks) checks" : "FAILED \(failures) of \(checks) checks")
        exit(failures == 0 ? 0 : 1)
    }
}
