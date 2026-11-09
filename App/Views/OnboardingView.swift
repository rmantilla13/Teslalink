import SwiftUI
import TeslaLinkCore

/// The welcome screen: what TeslaLink is, one button to connect a Tesla account, and the demo.
/// On the open Duo the story sits left of the hinge and the actions right of it.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HingeColumns {
            VStack(spacing: 28) {
                TeslaLinkMark()
                    .frame(width: 120)
                    .padding(.top, TL.Space.s8)
                VStack(spacing: TL.Space.s3) {
                    Text("TeslaLink").font(TL.Typeface.display(44)).foregroundStyle(TL.Palette.ink)
                    Text("Drives, charging and battery health, logged on your iPhone.")
                        .font(TL.Typeface.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(TL.Palette.inkMuted)
                }
                TopDownCarView(snapshot: nil, paint: TL.Palette.steel)
                    .frame(height: 200)
            }
        } trailing: {
            VStack(spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    Label("No server, no Grafana. One database on your phone.", systemImage: "iphone")
                    Label("Read-only access. TeslaLink never sends commands to your car.", systemImage: "lock.shield")
                    Label("Lets your car sleep, like a good logger should.", systemImage: "moon.zzz")
                }
                .font(TL.Typeface.body)
                .foregroundStyle(TL.Palette.ink)
                .frame(maxWidth: 420, alignment: .leading)

                VStack(spacing: TL.Space.s3) {
                    ConnectTeslaButton()
                    if !model.hasDeveloperApp {
                        Text("First time? TeslaLink walks you through the one-time Tesla developer setup.")
                            .font(TL.Typeface.caption)
                            .foregroundStyle(TL.Palette.inkMuted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(spacing: TL.Space.s1) {
                    Button("Explore with a demo car") { model.enterDemo() }
                        .buttonStyle(.tlGhost)
                    Text("A month of sample drives and a charge in progress. Nothing is sent anywhere.")
                        .font(TL.Typeface.caption).foregroundStyle(TL.Palette.inkMuted).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(TL.Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}
