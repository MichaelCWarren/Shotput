import SwiftUI

/// Sits under `DropdownHeader` whenever AI is on. Arrows, return and
/// option-return go to `onKey` so row selection and copy keep working while
/// the field has focus; Escape clears the text, gives up focus and calls
/// `onEscape`. Spec 05 lists space as forwarded too, but this is a
/// natural-language field, so space stays a character: forwarding it would
/// type "login screen" as "loginscreen" and toggle the preview on the way.
struct SemanticSearchField: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    let onEscape: () -> Void
    let onKey: (DropdownKey) -> Void

    /// Space is the one key spec 05 forwards that this field keeps, so the
    /// rule lives here where a test can call it.
    static func forwardedKey(_ key: KeyEquivalent, modifiers: EventModifiers) -> DropdownKey? {
        if key == .space {
            return nil
        }
        return DropdownKey.action(key: key, modifiers: modifiers)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary(0.6))

            TextField("", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.label)
                .focused(focused)
                .onKeyPress(phases: .down) { press in
                    if press.key == .escape {
                        query = ""
                        focused.wrappedValue = false
                        onEscape()
                        return .handled
                    }
                    if let key = Self.forwardedKey(press.key, modifiers: press.modifiers) {
                        onKey(key)
                        return .handled
                    }
                    return .ignored
                }

            HStack(spacing: 4) {
                Image(systemName: "sparkle")
                    .font(.system(size: 10, weight: .semibold))
                Text("semantic")
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(Theme.ai)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Theme.neutral(0.14), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
