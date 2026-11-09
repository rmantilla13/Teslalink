import SwiftUI
import UIKit

// The app's own chrome. The design has no system navigation or tab bars: every screen starts
// with a header (optional back link, uppercase label, Chakra Petch title), and the iPhone has
// a flat steel tab bar whose selected item carries a glowing ion underline. On iOS 26 and later
// the system bars are Liquid Glass, which the brand ("flat steel, light only for live state")
// rules out; the owner chose the flat bar on 2026-11-08.

/// The top of a screen. Scrolls with the content, like the artboards.
struct ScreenHeader<Trailing: View>: View {
    /// Title of the screen to go back to ("Drives"); nil on a tab's root.
    var back: String?
    var label: String?
    let title: Text
    var titleSize: CGFloat = 34
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let back {
                Button { dismiss() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                        Text(back).font(TL.Typeface.sans(15, .semibold))
                    }
                    .foregroundStyle(TL.Palette.ion)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to \(back)")
            }
            HStack(alignment: .bottom, spacing: TL.Space.s3) {
                VStack(alignment: .leading, spacing: 2) {
                    if let label { Text(label).tlLabel().lineLimit(1) }
                    title
                        .font(TL.Typeface.display(titleSize))
                        .foregroundStyle(TL.Palette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 0)
                trailing()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, back == nil ? TL.Space.s3 : 0)
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(back: String? = nil, label: String? = nil, title: Text, titleSize: CGFloat = 34) {
        self.init(back: back, label: label, title: title, titleSize: titleSize) { EmptyView() }
    }

    init(back: String? = nil, label: String? = nil, title: String, titleSize: CGFloat = 34) {
        self.init(back: back, label: label, title: Text(title), titleSize: titleSize) { EmptyView() }
    }
}

extension View {
    /// Hides the system navigation bar; the screen draws a `ScreenHeader` instead.
    func tlScreen() -> some View {
        toolbar(.hidden, for: .navigationBar)
            .background(SwipeBackEnabler().frame(width: 0, height: 0).accessibilityHidden(true))
            .background(TL.Palette.ground.ignoresSafeArea())
    }
}

/// Hiding the navigation bar also turns off UIKit's edge-swipe back gesture. This zero-size
/// probe turns it back on for the stack its screen is in, and only that stack: Settings' pushed
/// forms and system sheets keep UIKit's own handling. (A global `UINavigationController`
/// category override would replace UIKit's `viewDidLoad` for every navigation controller.)
private struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ controller: Probe, context: Context) {}

    final class Probe: UIViewController {
        /// One delegate per navigation controller, released with it: recognizers hold delegates weakly.
        private static let delegates = NSMapTable<UINavigationController, PopGestureDelegate>.weakToStrongObjects()

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let nav = navigationController, let pop = nav.interactivePopGestureRecognizer else { return }
            let delegate = Self.delegates.object(forKey: nav) ?? {
                let d = PopGestureDelegate(navigationController: nav)
                Self.delegates.setObject(d, forKey: nav)
                return d
            }()
            if pop.delegate !== delegate { pop.delegate = delegate }
            pop.isEnabled = true
        }
    }
}

@MainActor
private final class PopGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var navigationController: UINavigationController?

    init(navigationController: UINavigationController) {
        self.navigationController = navigationController
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        (navigationController?.viewControllers.count ?? 0) > 1
    }
}

/// A chamfered group of list rows split by 1 px `edge` rules (Drives artboard). Replaces the
/// system List, whose iOS 26 sections are rounded.
struct RowGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 1) { content }
            .background(TL.Palette.edge)
            .clipShape(ChamferedRectangle(cut: TL.Chamfer.md))
    }
}

extension View {
    /// One row in a `RowGroup`: steel face, optionally tinted (the live drive, a live charge).
    func tlRow(highlight: Color? = nil) -> some View {
        padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    TL.Palette.surface1
                    if let highlight { highlight.opacity(0.08) }
                }
            }
            .contentShape(Rectangle())
    }
}

/// Amber chip shown in headers while the app runs on the simulated demo car.
struct DemoBadge: View {
    var body: some View {
        Text("Demo").tlLabel().foregroundStyle(TL.Palette.amber)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(ChamferedRectangle(cut: 4).fill(TL.Palette.amber.opacity(0.14)))
            .accessibilityLabel("Demo mode")
    }
}

/// The iPhone's bottom bar: five sections, flat steel, the selected one in ion with a glowing
/// underline along the top edge (Car artboard).
struct TLTabBar: View {
    @Binding var selection: AppSection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppSection.allCases) { section in
                let on = section == selection
                Button { selection = section } label: {
                    VStack(spacing: 3) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 19, weight: .semibold))
                            .frame(height: 24)
                        Text(section.title)
                            .font(TL.Typeface.sans(10, .semibold))
                            .tracking(0.4)
                    }
                    .foregroundStyle(on ? TL.Palette.ion : TL.Palette.inkMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) {
                        if on {
                            Rectangle().fill(TL.Palette.ion)
                                .frame(height: 2)
                                .padding(.horizontal, 17)
                                .tlGlow(radius: 6)
                                .offset(y: -1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(height: 62)
        .background(alignment: .top) { Rectangle().fill(TL.Palette.edge).frame(height: 1) }
        // Opaque, and extended under the home indicator. (The design's 94% let scrolled
        // content read through clearly once iOS composited it.)
        .background(TL.Palette.ground, ignoresSafeAreaEdges: .bottom)
    }
}

extension EnvironmentValues {
    /// False for a tab kept alive behind the selected one (`PhoneRoot`), so its data loading
    /// can pause instead of rerunning on every poll.
    @Entry var tabIsActive = true
}
