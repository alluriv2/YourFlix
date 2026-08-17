import SwiftUI

/// A brief title card shown before a title's slideshow actually begins --
/// two quick beats over a softly blurred, dimmed backdrop pulled from the
/// title's own poster photo. First the YourFlix wordmark bumps in and back
/// out (a small studio-ident moment), then dissolves into the actual
/// title: a small red "YOURFLIX ORIGINAL" eyebrow line above the big
/// show/season title. Purely presentational -- how long the WHOLE card
/// stays up and what happens after are PlayerView's call (see its
/// `showingTitleCard`/`titleCardDuration`); this view just runs its own
/// short internal sequence within whatever time it's given, comfortably
/// inside PlayerView's own (longer) hold.
struct TitleCardView: View {
    let album: Album
    /// Fired from right inside this view's OWN reveal timeline, the
    /// instant the "YOURFLIX ORIGINAL" eyebrow + big title start fading
    /// in -- not driven by some separately-scheduled timer in the
    /// caller. PlayerView's restart flow uses this to start a fresh
    /// music track exactly in sync with the visual reveal, no matter how
    /// long this view took to actually appear on screen (a first-time
    /// poster decode can noticeably delay that) -- two independent
    /// timers racing each other would drift; one timeline driving both
    /// can't. `nil` on a genuinely first-ever open, where music instead
    /// starts immediately via PlayerView's own onAppear.
    var onTitleRevealed: (() -> Void)? = nil

    @State private var wordmarkOpacity: Double = 0
    @State private var showWordmark = true
    @State private var titleVisible = false
    @State private var backdropZoomed = false

    private static let wordmarkFadeIn: TimeInterval = 0.5
    private static let wordmarkHold: TimeInterval = 0.6
    private static let wordmarkFadeOut: TimeInterval = 0.4
    // Measured from the moment the wordmark starts fading out (not from
    // t=0) -- gives the title a moment to start rising right as the
    // wordmark finishes dissolving, rather than a dead gap between them.
    private static let titleStartDelay: TimeInterval = 0.5
    private static let backdropZoomDuration: TimeInterval = 6.0

    /// How long after this view appears the "YOURFLIX ORIGINAL" eyebrow +
    /// big title start fading in -- i.e. the wordmark's whole bump-in-
    /// and-out beat, plus its own post-fade-out pause.
    private static let titleRevealDelay: TimeInterval = wordmarkFadeIn + wordmarkHold + titleStartDelay

    // Same cached, downsampled poster AlbumTile/HeroView already use --
    // AlbumLoader.posterImage(for:) is keyed by this album's own id, so
    // this is very likely a cache hit (no extra decode) by the time
    // someone actually presses play.
    private var backdrop: NSImage? {
        AlbumLoader.posterImage(for: album)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let backdrop {
                Image(nsImage: backdrop)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(backdropZoomed ? 1.08 : 1.0)
                    .blur(radius: 46)
                    .clipped()
                    .ignoresSafeArea()

                // Dark scrim over the blurred photo -- keeps every stage
                // of text fully legible regardless of how bright/busy the
                // underlying photo is.
                Color.black.opacity(0.62).ignoresSafeArea()
            }

            if showWordmark {
                Text("YourFlix")
                    .font(.custom("BebasNeueBold", size: 60))
                    .tracking(1.6)
                    .foregroundColor(Theme.red)
                    .opacity(wordmarkOpacity)
            } else {
                VStack(spacing: 10) {
                    Text("YOURFLIX ORIGINAL")
                        .font(.caption.bold())
                        .tracking(3)
                        .foregroundColor(Theme.red)

                    Text(album.title)
                        .font(.custom("BebasNeueBold", size: 96))
                        .tracking(2)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 60)
                }
                .opacity(titleVisible ? 1 : 0)
                .scaleEffect(titleVisible ? 1 : 0.92)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            print("[TitleCard] onAppear at \(Date()), onTitleRevealed is \(onTitleRevealed == nil ? "nil" : "set")")
            // Slow, barely-there drift on the backdrop for the card's
            // whole life -- same spirit as the slideshow's own Ken Burns
            // motion, just heavily blurred/dimmed here so it reads as
            // atmosphere rather than content.
            withAnimation(.linear(duration: Self.backdropZoomDuration)) {
                backdropZoomed = true
            }

            withAnimation(.easeOut(duration: Self.wordmarkFadeIn)) {
                wordmarkOpacity = 1
            }

            let wordmarkFadeOutStart = Self.wordmarkFadeIn + Self.wordmarkHold
            DispatchQueue.main.asyncAfter(deadline: .now() + wordmarkFadeOutStart) {
                withAnimation(.easeInOut(duration: Self.wordmarkFadeOut)) {
                    wordmarkOpacity = 0
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.titleRevealDelay) {
                // By this point wordmarkOpacity has already reached 0
                // (titleStartDelay > wordmarkFadeOut), so swapping away
                // from the wordmark branch is invisible -- nothing pops.
                showWordmark = false
                withAnimation(.easeOut(duration: 0.7)) {
                    titleVisible = true
                }
                print("[TitleCard] reveal fired at \(Date()), calling onTitleRevealed")
                onTitleRevealed?()
            }
        }
    }
}
