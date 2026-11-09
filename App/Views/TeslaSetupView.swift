import SwiftUI
import TeslaLinkCore
import UIKit

/// The Tesla developer app TeslaLink signs in with, set up step by step: create it on
/// developer.tesla.com, register a domain key with the partner script, then paste the setup
/// link the script prints (or type the details). Done once; every linked account uses it.
struct TeslaSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var backTitle = "Back"
    /// Runs after the developer app is saved (Connect carries on into Tesla's sign-in).
    /// nil goes back instead.
    var onDone: (() -> Void)?
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var redirectURI = FleetSetupLink.appRedirectURI
    @State private var pasteProblem: String?
    @State private var finished = false

    var body: some View {
        HingeColumns {
            VStack(alignment: .leading, spacing: TL.Space.s4) {
                ScreenHeader(back: backTitle, label: "One-time setup", title: "Connect to Tesla")
                Text("Tesla only shares car data with apps registered as a developer app. Registering is free and takes about ten minutes, once: every Tesla account you link then signs in through it.")
                    .font(TL.Typeface.body)
                    .foregroundStyle(TL.Palette.inkMuted)
                createStep
                registerStep
            }
            .frame(maxWidth: 560, alignment: .leading)
        } trailing: {
            VStack(alignment: .leading, spacing: TL.Space.s4) {
                addStep
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
        .tlScreen()
        .onAppear(perform: prefill)
        .onChange(of: model.developerApp.clientID) { _, id in
            // A setup link accepted from the review sheet lands here too.
            if !id.isEmpty, model.pendingSetupLink == nil { finish() }
        }
    }

    // MARK: Steps

    private var createStep: some View {
        SetupStep(number: 1, title: "Create a developer app") {
            Text("Sign in at developer.tesla.com and create an application with these settings:")
                .font(TL.Typeface.body).foregroundStyle(TL.Palette.ink)
            SetupValue(label: "Scopes", value: "Vehicle Information, Vehicle Location")
            SetupValue(label: "Redirect URI", value: FleetSetupLink.appRedirectURI, copyable: true)
            SetupValue(label: "Allowed origin", value: "Your domain, like https://yourname.github.io")
            Link(destination: URL(string: "https://developer.tesla.com")!) {
                Label("Open developer.tesla.com", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.tlSecondary)
        }
    }

    private var registerStep: some View {
        SetupStep(number: 2, title: "Register your domain") {
            Text("Tesla wants a public key on a domain you control, even for read-only apps (GitHub Pages works). On your Mac, in the TeslaLink folder, run:")
                .font(TL.Typeface.body).foregroundStyle(TL.Palette.ink)
            SetupValue(label: "Terminal", value: "CLIENT_ID=… CLIENT_SECRET=… DOMAIN=yourname.github.io REGION=\(model.settings.region.rawValue) ./scripts/register-partner.sh",
                       copyable: true, monospaced: true)
            Text("It ends by printing a setup link and a QR code. Scan the code with this phone's camera, or copy the link and paste it in step 3.")
                .font(TL.Typeface.caption).foregroundStyle(TL.Palette.inkMuted)
        }
    }

    private var addStep: some View {
        SetupStep(number: 3, title: "Add it to TeslaLink") {
            if model.developerApp.fromBuild {
                Text("This build already includes a developer app (Config/Secrets.xcconfig). Saving here replaces it on this phone.")
                    .font(TL.Typeface.caption).foregroundStyle(TL.Palette.inkMuted)
            }
            PasteButton(payloadType: String.self) { strings in
                let text = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let url = URL(string: text), let link = FleetSetupLink(url: url) {
                    pasteProblem = nil
                    model.pendingSetupLink = SetupLinkRequest(link: link)
                } else {
                    pasteProblem = "That isn't a TeslaLink setup link. It starts with teslalink://setup."
                }
            }
            .tint(TL.Palette.ion)
            if let pasteProblem {
                Text(pasteProblem).font(TL.Typeface.caption).foregroundStyle(TL.Palette.amber)
            }

            Text("Or enter the details from developer.tesla.com:")
                .font(TL.Typeface.body).foregroundStyle(TL.Palette.ink)
                .padding(.top, TL.Space.s2)
            VStack(spacing: TL.Space.s2) {
                SetupField(label: "Client ID", text: $clientID)
                SetupField(label: "Client secret", text: $clientSecret, secure: true,
                           prompt: model.developerApp.clientSecret.isEmpty || model.developerApp.fromBuild ? "ta-secret…" : "Saved for this client ID; leave empty to keep it")
                SetupField(label: "Redirect URI", text: $redirectURI, keyboard: .URL)
            }
            if let problem = redirectProblem {
                Text(problem).font(TL.Typeface.caption).foregroundStyle(TL.Palette.amber)
            } else if !FleetSetupLink(clientID: "x", clientSecret: nil, redirectURI: trimmed(redirectURI)).returnsToApp {
                Text("An https redirect only works with the Associated Domains entitlement in your build; teslalink://auth/callback needs nothing extra.")
                    .font(TL.Typeface.caption).foregroundStyle(TL.Palette.inkMuted)
            }
            Button("Save and continue") { save() }
                .buttonStyle(.tlPrimary)
                .disabled(trimmed(clientID).isEmpty || redirectProblem != nil)
                .padding(.top, TL.Space.s2)
        }
    }

    // MARK: Actions

    private var redirectProblem: String? {
        FleetSetupLink.isUsableRedirect(trimmed(redirectURI)) ? nil : "Use teslalink://auth/callback (or an https address set up for the app)."
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func prefill() {
        let app = model.developerApp
        if clientID.isEmpty { clientID = app.clientID }
        if !app.redirectURI.isEmpty { redirectURI = app.redirectURI }
    }

    private func save() {
        let id = trimmed(clientID)
        let typed = trimmed(clientSecret)
        let current = model.developerApp
        // An empty field keeps the saved secret, but only for the same client ID, and never
        // copies a secret that came with the build.
        let keep = typed.isEmpty && id == current.clientID && !current.fromBuild && !current.clientSecret.isEmpty
        model.saveDeveloperApp(clientID: id, clientSecret: keep ? current.clientSecret : (typed.isEmpty ? nil : typed),
                               redirectURI: trimmed(redirectURI))
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        if let onDone { onDone() } else { dismiss() }
    }
}

/// A numbered card in the setup.
private struct SetupStep<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        Card(title: "Step \(number) · \(title)", lightbar: false) {
            VStack(alignment: .leading, spacing: TL.Space.s3) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A value to type into Tesla's portal or the terminal, with a copy button.
private struct SetupValue: View {
    let label: String
    let value: String
    var copyable = false
    var monospaced = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: TL.Space.s2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).tlLabel()
                Text(value)
                    .font(monospaced ? TL.Typeface.mono(12) : TL.Typeface.sans(14, .semibold))
                    .foregroundStyle(TL.Palette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if copyable {
                Button {
                    UIPasteboard.general.string = value
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TL.Palette.ion)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Copied" : "Copy \(label)")
            }
        }
    }
}

/// A labelled text field on a steel face.
private struct SetupField: View {
    let label: String
    @Binding var text: String
    var secure = false
    var keyboard: UIKeyboardType = .asciiCapable
    var prompt: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).tlLabel()
            Group {
                if secure {
                    SecureField(label, text: $text, prompt: prompt.map { Text($0) })
                } else {
                    TextField(label, text: $text, prompt: prompt.map { Text($0) })
                        .keyboardType(keyboard)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(TL.Typeface.sans(15, .semibold))
            .foregroundStyle(TL.Palette.ink)
            .padding(.horizontal, TL.Space.s3)
            .frame(minHeight: 44)
            .background(ChamferedRectangle(cut: TL.Chamfer.sm).fill(TL.Palette.surface2))
        }
    }
}

/// What a setup link would change, shown before anything changes. The link can come from any
/// app or web page, and it decides where Tesla sends your sign-in, so it's never applied
/// silently and a redirect that doesn't come back to the app is called out.
struct SetupLinkReview: View {
    @Environment(AppModel.self) private var model
    let link: FleetSetupLink

    var body: some View {
        HingeColumns {
            VStack(alignment: .leading, spacing: TL.Space.s4) {
                ScreenHeader(label: "Setup link", title: "Use this developer app?")
                Text("A link wants to set TeslaLink up with the Tesla developer app shown here. Accept only links you made yourself with scripts/register-partner.sh.")
                    .font(TL.Typeface.body)
                    .foregroundStyle(TL.Palette.inkMuted)
                if !current.clientID.isEmpty, current.clientID != link.clientID {
                    Text("It replaces the developer app in use (client ID \(Self.short(current.clientID))). Linked accounts will need to reconnect.")
                        .font(TL.Typeface.caption)
                        .foregroundStyle(TL.Palette.amber)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
        } trailing: {
            VStack(alignment: .leading, spacing: TL.Space.s4) {
                Card(title: "Developer app", lightbar: false) {
                    VStack(alignment: .leading, spacing: TL.Space.s3) {
                        SetupValue(label: "Client ID", value: link.clientID)
                        SetupValue(label: "Client secret", value: link.clientSecret.map { "Included, ending \(String($0.suffix(4)))" } ?? "Not included")
                        SetupValue(label: "Sign-in returns to", value: link.redirectURI)
                        if let region = link.region { SetupValue(label: "Tesla region", value: region.displayName) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if link.returnsToApp {
                    Button("Use this developer app") { accept() }
                        .buttonStyle(.tlPrimary)
                    Button("Cancel") { model.pendingSetupLink = nil }
                        .buttonStyle(.tlGhost)
                } else {
                    Label {
                        Text("Sign-in would go to \(URLComponents(string: link.redirectURI)?.host ?? link.redirectURI), not back to this app. Whoever runs that address receives your Tesla sign-in code. Accept only if it's your own domain, set up for TeslaLink.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(TL.Typeface.caption)
                    .foregroundStyle(TL.Palette.taillight)
                    Button("Cancel") { model.pendingSetupLink = nil }
                        .buttonStyle(.tlPrimary)
                    Button("Use it anyway") { accept() }
                        .buttonStyle(.tlSecondary)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
        .background(TL.Palette.ground.ignoresSafeArea())
    }

    private var current: (clientID: String, clientSecret: String, redirectURI: String, fromBuild: Bool) { model.developerApp }

    private func accept() {
        model.saveDeveloperApp(clientID: link.clientID, clientSecret: link.clientSecret, redirectURI: link.redirectURI, region: link.region)
        model.pendingSetupLink = nil
    }

    /// "1b4e…a427": enough to recognise a client ID.
    static func short(_ id: String) -> String {
        id.count > 10 ? "\(id.prefix(4))…\(id.suffix(4))" : id
    }
}
