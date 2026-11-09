import Foundation

/// Launch arguments for simulator walkthroughs and screenshots. Debug builds only.
///
///     -TLDemo YES          start in demo mode (skips onboarding)
///     -TLTab drives        open on a tab: car, drives, charges, stats, settings
///     -TLGeometry YES      overlay the content size, safe-area insets and hinge state
///
/// Example: `xcrun simctl launch booted <bundle id> -TLDemo YES -TLTab stats`
enum DebugLaunch {
    #if DEBUG
    static let demo = UserDefaults.standard.bool(forKey: "TLDemo")
    static let tab = UserDefaults.standard.string(forKey: "TLTab")
    static let geometry = UserDefaults.standard.bool(forKey: "TLGeometry")
    #else
    static let demo = false
    static let tab: String? = nil
    static let geometry = false
    #endif

    /// The iPad sidebar section matching `tab`.
    static var section: AppSection? {
        switch tab {
        case "drives": .drives
        case "charges": .charging
        case "stats": .insights
        case "settings": .settings
        case "car": .car
        default: nil
        }
    }
}
