import AuthenticationServices
import SwiftUI
import TeslaLinkCore

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                TeslaLinkMark()
                    .frame(width: 120)
                    .padding(.top, TL.Space.s12)
                VStack(spacing: TL.Space.s3) {
                    Text("TeslaLink").font(TL.Typeface.display(44)).foregroundStyle(TL.Palette.ink)
                    Text("Drives, charging and battery health, logged on your iPhone.")
                        .font(TL.Typeface.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(TL.Palette.inkMuted)
                }
                TopDownCarView(snapshot: nil, paint: TL.Palette.steel)
                    .frame(height: 220)
                VStack(alignment: .leading, spacing: 14) {
                    Label("No server, no Grafana. One database on your phone.", systemImage: "iphone")
                    Label("Read-only access. TeslaLink never sends commands to your car.", systemImage: "lock.shield")
                    Label("Lets your car sleep, like a good logger should.", systemImage: "moon.zzz")
                }
                .font(TL.Typeface.body)
                .foregroundStyle(TL.Palette.ink)
                .frame(maxWidth: 420, alignment: .leading)

                if model.settings.fleetConfig == nil {
                    Text("First add the client ID of your Tesla developer app (developer.tesla.com) in Settings.")
                        .font(TL.Typeface.caption).foregroundStyle(TL.Palette.amber).multilineTextAlignment(.center)
                    NavigationLink("Developer app settings") { DeveloperAppSettingsView() }
                        .buttonStyle(.tlSecondary)
                    demoButton
                } else {
                    Button {
                        Task { await signIn() }
                    } label: {
                        Label(busy ? "Signing in…" : "Sign in with Tesla", systemImage: "person.badge.key")
                            .frame(maxWidth: 320)
                    }
                    .buttonStyle(.tlPrimary)
                    .disabled(busy)
                    Picker("Region", selection: Binding(get: { model.settings.region }, set: { model.settings.region = $0 })) {
                        ForEach(FleetRegion.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    NavigationLink("Developer app settings") { DeveloperAppSettingsView() }.font(.footnote)
                    demoButton
                }
            }
            .padding(TL.Space.s4)
            .frame(maxWidth: .infinity)
        }
        .background(TL.Palette.ground)
    }

    private var demoButton: some View {
        VStack(spacing: TL.Space.s1) {
            Button("Explore with a demo car") { model.enterDemo() }
                .buttonStyle(.tlGhost)
            Text("A month of sample drives and a charge in progress. Nothing is sent anywhere.")
                .font(TL.Typeface.caption).foregroundStyle(TL.Palette.inkMuted).multilineTextAlignment(.center)
        }
        .padding(.top, TL.Space.s2)
    }

    private func signIn() async {
        guard let (url, pkce) = model.beginSignIn(), let config = model.settings.fleetConfig else { return }
        busy = true
        defer { busy = false }
        do {
            let callback: ASWebAuthenticationSession.Callback
            if let redirect = URL(string: config.redirectURI), redirect.scheme == "https", let host = redirect.host() {
                // Universal-link style redirect (needs the Associated Domains entitlement).
                callback = .https(host: host, path: redirect.path())
            } else {
                callback = .customScheme(URL(string: config.redirectURI)?.scheme ?? "teslalink")
            }
            let result = try await webAuth.authenticate(using: url, callback: callback, preferredBrowserSession: .ephemeral, additionalHeaderFields: [:])
            await model.completeSignIn(callback: result, pkce: pkce)
            model.requestNotificationPermission()
        } catch ASWebAuthenticationSessionError.canceledLogin {
            // user closed the sheet
        } catch {
            model.errorMessage = "Sign-in failed: \(error.localizedDescription)"
        }
    }
}
