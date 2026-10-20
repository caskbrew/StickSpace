import Foundation

/// Debug builds are a separate app ("StickSpace Dev", bundle id ending in ".dev") with their own data folder,
/// so they can run next to the installed one without touching its state.
enum AppInfo {
    static var isDev: Bool { Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true }

    static var name: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "StickSpace"
    }

    /// Folder name under Application Support. The name predates the "StickSpace" spelling; it stays so existing data is found.
    static var dataFolder: String { isDev ? "Stickspace Dev" : "Stickspace" }
}
