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
                TopDownCarView(snapshot: nil, paint: .paint("deepblue"))
                    .frame(height: 260)
                    .padding(.top, 24)
                VStack(spacing: 10) {
                    Text("TeslaLink").font(.largeTitle.bold())
                    Text("Your drives, charges and battery health, logged and analysed entirely on this device.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Label("No server, no Grafana. One database on your phone.", systemImage: "iphone")
                    Label("Read-only access. TeslaLink never sends commands to your car.", systemImage: "lock.shield")
                    Label("Lets your car sleep, like a good logger should.", systemImage: "moon.zzz")
                }
                .frame(maxWidth: 420, alignment: .leading)

                if model.settings.fleetConfig == nil {
                    Text("First add the client ID of your Tesla developer app (developer.tesla.com) in Settings.")
                        .font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                    NavigationLink("Developer app settings") { DeveloperAppSettingsView() }
                        .buttonStyle(.bordered)
                } else {
                    Button {
                        Task { await signIn() }
                    } label: {
                        Label(busy ? "Signing in…" : "Sign in with Tesla", systemImage: "person.badge.key")
                            .frame(maxWidth: 360)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(busy)
                    Picker("Region", selection: Binding(get: { model.settings.region }, set: { model.settings.region = $0 })) {
                        ForEach(FleetRegion.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    NavigationLink("Developer app settings") { DeveloperAppSettingsView() }.font(.footnote)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
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
