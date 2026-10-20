import SwiftUI

private struct ZoomKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    /// Per-group scale. Every size in the group UI is multiplied by this instead of using scaleEffect, so text stays crisp.
    var zoom: CGFloat {
        get { self[ZoomKey.self] }
        set { self[ZoomKey.self] = newValue }
    }
}

enum Metrics {
    static let width: CGFloat = 320
    /// Gap between sticks inside a group.
    static let gap: CGFloat = 2
    /// Transparent margin above/below the stack.
    static let edge: CGFloat = 0
    /// Extra transparent margin around the window while a stick is dragged.
    static let dragMargin: CGFloat = 60
    static let headerHeight: CGFloat = 26
    static let rowHeight: CGFloat = 28
    static let radius: CGFloat = 9
}

enum Palette {
    static let blue = Color(red: 0.0, green: 0.478, blue: 1.0)

    static func link(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.40, green: 0.67, blue: 1.0) : Color(red: 0.04, green: 0.40, blue: 0.86)
    }

    static func separator(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.09)
    }

    static func text(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.95) : Color.black.opacity(0.88)
    }

    static func icon(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.82) : Color.black.opacity(0.72)
    }
}

/// Liquid Glass on macOS 26+, standard material on older systems, solid when Reduce Transparency is on.
struct StickSurface: ViewModifier {
    /// Corner radius in points; nil = the stick radius scaled by the group zoom.
    var radius: CGFloat?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.zoom) private var z

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? Metrics.radius * z, style: .continuous)
        let dark = scheme == .dark
        let tint = dark ? Color(red: 0.08, green: 0.10, blue: 0.16) : Color.white

        Group {
            if reduceTransparency {
                content.background(shape.fill(dark ? Color(red: 0.16, green: 0.17, blue: 0.21) : Color(white: 0.97)))
            } else if #available(macOS 26.0, *) {
                // Glass adapts to what is behind it; a fixed base fill keeps text readable on any wallpaper.
                content
                    .background(shape.fill(tint.opacity(dark ? 0.40 : 0.62)))
                    .glassEffect(.regular, in: shape)
            } else {
                content
                    .background(shape.fill(.regularMaterial))
                    .background(shape.fill(tint.opacity(dark ? 0.30 : 0.35)))
            }
        }
        .overlay(shape.strokeBorder(dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08), lineWidth: 0.5))
        .clipShape(shape)
    }
}

extension View {
    func stickSurface(radius: CGFloat? = nil) -> some View { modifier(StickSurface(radius: radius)) }
}

/// Compact icon button with a comfortable hit target.
struct IconButton: View {
    let symbol: String
    let label: String
    var help: String?
    var tint: Color?
    var enabled = true
    let action: () -> Void

    @Environment(\.zoom) private var z
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12 * z, weight: .regular))
                .foregroundStyle(tint ?? Palette.icon(scheme))
                .frame(width: 22 * z, height: 22 * z)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
        .help(help ?? label)
        .accessibilityLabel(label)
    }
}
