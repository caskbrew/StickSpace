import SwiftUI

/// Three-icon appearance switch for the menu bar menu. No visible text: tooltips and accessibility labels only.
struct ThemeSwitch: View {
    @ObservedObject var store: AppStore

    private let options: [(ThemeChoice, String, String)] = [
        (.system, "desktopcomputer", "Match System Appearance"),
        (.light, "sun.max.fill", "Light Appearance"),
        (.dark, "moon.fill", "Dark Appearance"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { choice, symbol, label in
                let selected = store.state.theme == choice
                Button { store.setTheme(choice) } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: 20)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Palette.blue : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(label)
                .accessibilityLabel(label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)))
        .frame(width: 190)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3)
    }
}

/// "Stick deleted · Undo ⌘Z ×" notice. Shown in a non-activating panel so it never steals focus.
struct ToastView: View {
    let message: String
    let undo: () -> Void
    let dismiss: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.green)
                .accessibilityHidden(true)
            Text(message)
            Rectangle().fill(Palette.separator(scheme)).frame(width: 1, height: 16)
            Button(action: undo) {
                Text("Undo").foregroundStyle(Palette.blue)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Undo")
            Text("⌘Z").foregroundStyle(.secondary).font(.callout)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08), lineWidth: 0.5))
        .padding(12)
        .accessibilityElement(children: .contain)
    }
}
