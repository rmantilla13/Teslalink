import AuthenticationServices
import SwiftUI
import TeslaLinkCore

extension EnvironmentValues {
    /// The open Duo's hinge, in points from the leading edge, for full-width screens (welcome,
    /// setup, a setup link's review) that split there. nil everywhere else.
    @Entry var duoSplit: CGFloat?
}

/// Two columns meeting at the open Duo's hinge, each scrolling on its own and centred in its
/// half; one scrolling column on anything else.
struct HingeColumns<Leading: View, Trailing: View>: View {
    @Environment(\.duoSplit) private var split
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        if let split {
            HStack(spacing: 0) {
                column(leading).frame(width: split)
                Rectangle().fill(TL.Palette.edge).frame(width: 1).ignoresSafeArea()
                column(trailing).frame(maxWidth: .infinity)
            }
        } else {
            ScrollView {
                VStack(spacing: 28) {
                    leading
                    trailing
                }
                .padding(TL.Space.s4)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func column(_ content: some View) -> some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 28) { content }
                    .padding(TL.Space.s6)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
    }
}

/// The one button that links a Tesla account: Tesla's sign-in in a browser sheet, back in the
/// app, cars loaded. Without a developer app it opens the guided setup first. When Tesla keeps
/// the account in another region, it says so and the next tap signs in there.
struct ConnectTeslaButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth
    var title = "Connect Tesla account"
    /// Renews this account's sign-in instead of linking a new one.
    var reconnecting: TeslaAccount?
    var style: TLButtonStyle = .tlPrimary
    /// Runs once the account is linked (Add account goes back to Settings).
    var onLinked: (() -> Void)?
    @State private var busy = false
    /// Set after Tesla said the account lives elsewhere: the one retry goes there.
    @State private var retryRegion: FleetRegion?
    @State private var showSetup = false
    /// Setup just finished: say the next tap signs in (if the sheet didn't open by itself).
    @State private var setupReady = false
    /// Bumped when setup finishes; the live view then opens Tesla's sign-in by itself.
    @State private var autoConnect = 0

    var body: some View {
        VStack(spacing: TL.Space.s2) {
            Button {
                Task { await connect() }
            } label: {
                Label(label, systemImage: "person.badge.key")
                    .frame(maxWidth: 320)
            }
            .buttonStyle(style)
            .disabled(busy)

            if setupReady, retryRegion == nil {
                Text("Developer app ready. Connect your Tesla account to finish.")
                    .font(TL.Typeface.caption)
                    .foregroundStyle(TL.Palette.charge)
                    .multilineTextAlignment(.center)
            }
            if let retryRegion {
                Text("Your Tesla account is in \(retryRegion.displayName). Sign in once more to finish.")
                    .font(TL.Typeface.caption)
                    .foregroundStyle(TL.Palette.amber)
                    .multilineTextAlignment(.center)
            } else if reconnecting == nil {
                regionMenu
            }
        }
        .navigationDestination(isPresented: $showSetup) {
            TeslaSetupView {
                showSetup = false
                setupReady = true
                autoConnect += 1
            }
        }
        .task(id: autoConnect) {
            guard autoConnect > 0 else { return }
            // Let a setup link's review close and setup pop (UIKit runs them one after the
            // other): Tesla's sign-in sheet needs a settled window to present from.
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            await connect(afterSetup: true)
        }
    }

    private var label: String {
        if busy { return "Waiting for Tesla…" }
        if let retryRegion { return "Sign in to Tesla \(retryRegion.shortName)" }
        return title
    }

    /// Where a new account signs in: from the phone's country, changeable here.
    private var regionMenu: some View {
        Menu {
            Picker("Tesla region", selection: Binding(get: { model.settings.region }, set: { model.settings.region = $0 })) {
                ForEach(FleetRegion.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        } label: {
            (Text("Tesla region: ") + Text(model.settings.region.displayName).foregroundColor(TL.Palette.ink)
                + Text("  Change").foregroundColor(TL.Palette.ion))
                .font(TL.Typeface.caption)
                .foregroundStyle(TL.Palette.inkMuted)
                .multilineTextAlignment(.center)
        }
        .accessibilityLabel("Tesla region, \(model.settings.region.displayName)")
        .accessibilityHint("Changes where a new account signs in")
    }

    private func connect(afterSetup: Bool = false) async {
        guard model.hasDeveloperApp else {
            showSetup = true
            return
        }
        let region = retryRegion ?? reconnecting?.region ?? model.settings.region
        guard let url = model.beginSignIn(region: region, reconnecting: reconnecting?.id, isRegionRetry: retryRegion != nil),
              let redirect = model.signInRedirectURI else { return }
        busy = true
        defer { busy = false }
        let callbackURL: URL
        do {
            // Ephemeral, so a second account isn't signed in as the first one again.
            callbackURL = try await webAuth.authenticate(using: url, callback: Self.callback(for: redirect),
                                                         preferredBrowserSession: .ephemeral, additionalHeaderFields: [:])
        } catch ASWebAuthenticationSessionError.canceledLogin {
            model.cancelSignIn()
            return
        } catch let error as ASWebAuthenticationSessionError where afterSetup && error.code != .canceledLogin {
            // Straight after setup the screen may still be moving; the button is ready to tap.
            model.cancelSignIn()
            return
        } catch {
            model.cancelSignIn()
            model.errorMessage = "Couldn't open Tesla's sign-in: \(error.localizedDescription)"
            return
        }
        switch await model.completeSignIn(callback: callbackURL) {
        case .linked:
            retryRegion = nil
            setupReady = false
            model.requestNotificationPermission()
            onLinked?()
        case .wrongRegion(let home):
            retryRegion = home
            if reconnecting == nil { model.settings.region = home }
        case .failed(let message):
            retryRegion = nil
            model.errorMessage = message
        }
    }

    /// `teslalink://…` comes back through the app's URL scheme; an https redirect through a
    /// universal link (needs the Associated Domains entitlement).
    static func callback(for redirectURI: String) -> ASWebAuthenticationSession.Callback {
        if let url = URL(string: redirectURI), url.scheme == "https", let host = url.host() {
            return .https(host: host, path: url.path())
        }
        return .customScheme(URL(string: redirectURI)?.scheme ?? FleetSetupLink.scheme)
    }
}

extension FleetRegion {
    /// "North America", "Europe", "China": for buttons.
    var shortName: String {
        switch self {
        case .northAmericaAsiaPacific: "North America"
        case .europeMiddleEastAfrica: "Europe"
        case .china: "China"
        }
    }
}
