import SwiftUI
import UIKit

/// UIKit-backed chrome (navigation and tab bars) styled with TeslaLink tokens.
enum Appearance {
    @MainActor
    static func apply() {
        let ink = UIColor(TL.Palette.ink)
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.backgroundColor = UIColor(TL.Palette.ground).withAlphaComponent(0.92)
        nav.shadowColor = UIColor(TL.Palette.edge)
        if let large = UIFont(name: "ChakraPetch-SemiBold", size: 34) { nav.largeTitleTextAttributes = [.font: large, .foregroundColor: ink] }
        if let inline = UIFont(name: "ChakraPetch-SemiBold", size: 17) { nav.titleTextAttributes = [.font: inline, .foregroundColor: ink] }
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav

        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        tab.backgroundColor = UIColor(TL.Palette.ground).withAlphaComponent(0.92)
        tab.shadowColor = UIColor(TL.Palette.edge)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}

extension View {
    /// Lists and forms on the graphite ground with steel rows.
    func tlListStyle() -> some View {
        scrollContentBackground(.hidden)
            .background(TL.Palette.ground)
            .listRowBackground(TL.Palette.surface1)
            .listRowSeparatorTint(TL.Palette.edge)
    }
}
