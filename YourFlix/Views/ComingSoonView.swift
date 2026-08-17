import SwiftUI

/// Full-screen placeholder shown in place of real playback until the
/// content pipeline ships real season-tagged media.
struct ComingSoonView: View {
    let titleText: String
    let seasonText: String?
    let onExit: () -> Void

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 18) {
                Text("COMING SOON")
                    .font(.custom("BebasNeueBold", size: 56))
                    .tracking(3)
                    .foregroundColor(Theme.red)
                    .shadow(color: Theme.red.opacity(0.5), radius: 18)

                VStack(spacing: 4) {
                    Text(titleText)
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    if let seasonText {
                        Text(seasonText)
                            .font(.headline)
                            .foregroundColor(Theme.textDim)
                    }
                }

                Button("← Back to Browse", action: onExit)
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .padding(.top, 14)
            }
        }
        .onExitCommand { onExit() } // Esc key
    }
}
