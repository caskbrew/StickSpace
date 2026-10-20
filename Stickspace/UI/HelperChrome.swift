import SwiftUI

/// Frame for helper windows: the same glass surface as the sticks, a compact title row and a close button.
struct AppWindowChrome<Content: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                HStack {
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.icon(scheme))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close (Esc)")
                    .accessibilityLabel("Close")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            Rectangle().fill(Palette.separator(scheme)).frame(height: 0.5)
            content.padding(14)
        }
        .foregroundStyle(Palette.text(scheme))
        .stickSurface(radius: 12)
    }
}

struct AppTextField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focused)
            .onSubmit(onSubmit)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(scheme == .dark ? Color.black.opacity(0.25) : Color.white.opacity(0.9)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Palette.blue : Palette.separator(scheme).opacity(2),
                                                                    lineWidth: focused ? 1.5 : 0.5))
            .onAppear {
                focused = true
                DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil) }
            }
    }
}

struct AppButton: View {
    enum Style { case primary, secondary }
    let title: String
    var style = Style.secondary
    var enabled = true
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: style == .primary ? .medium : .regular))
                .foregroundStyle(style == .primary ? Color.white : Palette.text(scheme))
                .padding(.horizontal, 14)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(style == .primary ? Palette.blue : Color.primary.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.separator(scheme), lineWidth: style == .primary ? 0 : 0.5))
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
    }
}

/// Segmented pills in the same look as the section type picker.
struct AppSegmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                let selected = selection == value
                Button { selection = value } label: {
                    Text(title)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? Color.white : Palette.text(scheme))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(selected ? Palette.blue : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.separator(scheme).opacity(2), lineWidth: 0.5))
    }
}

struct AppCheckbox: View {
    let title: String
    @Binding var isOn: Bool

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isOn ? Palette.blue : Palette.icon(scheme))
                Text(title).font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
    }
}

/// Inset code area with a hairline border, used for JSON.
struct AppCodeBox<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: 6).fill(scheme == .dark ? Color.black.opacity(0.25) : Color.white.opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.separator(scheme).opacity(2), lineWidth: 0.5))
    }
}

struct AppNotice: View {
    enum Kind { case error, warning }
    let kind: Kind
    let message: String

    var body: some View {
        let color: Color = kind == .error ? .red : .orange
        Label(message, systemImage: kind == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 12))
            .foregroundStyle(color)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.14)))
    }
}
