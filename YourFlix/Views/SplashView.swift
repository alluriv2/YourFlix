import AVFoundation
import SwiftUI

/// The app's opening moment: letters of the wordmark build in one by one,
/// then the whole thing punches with a brief red glow (the "sting," in the
/// spirit of Netflix's own logo moment) before settling, followed by the
/// tagline ("Your moments, now streaming."), then auto-continuing into the
/// browse screen. Purely passive -- there's no tap-to-skip; it always plays
/// through and advances on its own once ready.
///
/// Since AlbumLoader.loadAlbums() now scans source_media directly instead
/// of reading pre-flattened, pre-cached files, a scan can genuinely take
/// a little while the first time (or after adding a lot of new photos) —
/// see MediaScanner.swift's header. Rather than a fixed timer alone, this
/// view only actually continues into Browse once BOTH its own animation
/// has finished AND the caller reports (via `isReady`) that the scan
/// itself has completed — whichever takes longer. In the normal case
/// (nothing changed since last launch), the scan finishes almost
/// instantly, so this behaves exactly like a fixed-length splash, same as
/// before. If a scan is genuinely still running a few seconds after the
/// animation would normally finish, `showSlowHint` flips on (driven by
/// RootView) and a small, quiet line of text appears so the wait never
/// reads as the app being stuck.
struct SplashView: View {
    /// Set to true by the caller once AlbumLoader.loadAlbums() has
    /// returned. This view won't advance to Browse until this is true,
    /// no matter how long that takes.
    @Binding var isReady: Bool
    /// Set to true by the caller if the scan is taking noticeably longer
    /// than normal — see RootView.runScan(). Purely cosmetic (shows one
    /// extra line of text); never gates anything on its own.
    @Binding var showSlowHint: Bool
    let onFinished: () -> Void

    private let word = Array("YourFlix")
    private let letterStagger: Double = 0.07
    private let letterDuration: Double = 0.4
    private let baseLetterSize: CGFloat = 80
    /// "Y" and "F" (the initials also used in the app icon's monogram)
    /// print a little larger than the rest of the wordmark -- a small
    /// stylized emphasis rather than a uniform-size logotype.
    private let emphasizedLetterSize: CGFloat = 100
    /// Indices into `word` for "Y" (0) and "F" (4) in "YourFlix".
    private let emphasizedLetterIndices: Set<Int> = [0, 4]
    /// Total time the splash stays on screen (from first appearing) before
    /// it's allowed to advance to Browse, regardless of how quickly the
    /// letter/sting/tagline animation itself wraps up. If `isReady` is
    /// still false at this point, it still waits for that too -- see
    /// tryFinish().
    private let minimumDisplayDuration: Double = 5.2

    @State private var lettersVisible = false
    @State private var wordScale: CGFloat = 1.0
    @State private var glowRadius: CGFloat = 0
    @State private var glowOpacity: Double = 0
    @State private var showTagline = false
    @State private var animationFinished = false
    @State private var didFinish = false
    @State private var backgroundFlash: Double = 0
    // Held onto for the player's lifetime -- an AVAudioPlayer with no
    // strong reference gets deallocated (and silently stops) mid-playback.
    @State private var soundPlayer: AVAudioPlayer?

    var body: some View {
        ZStack {
            SplashBackground(stingFlash: backgroundFlash, spreadDuration: minimumDisplayDuration)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    ForEach(Array(word.enumerated()), id: \.offset) { index, letter in
                        Text(String(letter))
                            .font(
                                .custom(
                                    "BebasNeueBold",
                                    size: emphasizedLetterIndices.contains(index) ? emphasizedLetterSize : baseLetterSize
                                )
                            )
                            .tracking(2)
                            .foregroundColor(Theme.red)
                            .opacity(lettersVisible ? 1 : 0)
                            .offset(y: lettersVisible ? 0 : 10)
                            .animation(
                                .easeOut(duration: letterDuration).delay(Double(index) * letterStagger),
                                value: lettersVisible
                            )
                    }
                }
                .scaleEffect(wordScale)
                .shadow(color: Theme.red.opacity(glowOpacity), radius: glowRadius)

                if showTagline {
                    // Apple Chancery -- ships with every Mac, no custom font
                    // registration needed, and reads as a cursive script
                    // without the heavy fully-connected loops of something
                    // like Snell Roundhand.
                    Text("Your moments, now streaming.")
                        .font(.custom("Apple Chancery", size: 24))
                        .foregroundColor(.white.opacity(0.85))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if showSlowHint {
                    Text("Getting everything ready...")
                        .font(.caption)
                        .foregroundColor(Theme.textFaint)
                        .transition(.opacity)
                }
            }
        }
        .onAppear { runSequence() }
        .onChange(of: isReady) { _, ready in
            if ready { tryFinish() }
        }
        // Belt-and-suspenders alongside the AppDelegate fix in
        // YourFlixApp.swift (which makes the whole app quit when its
        // window closes, so nothing can keep playing after that point):
        // this stops the sound explicitly the moment SplashView itself
        // leaves the hierarchy -- e.g. the normal splash -> Browse handoff
        // -- rather than relying on AVAudioPlayer happening to notice it
        // has no more strong references and stopping on its own.
        .onDisappear { stopSplashSound() }
    }

    private func runSequence() {
        // 1. Letters build in, one by one, left to right.
        lettersVisible = true
        let revealDuration = Double(word.count - 1) * letterStagger + letterDuration

        // 2. Once fully revealed, a brief red glow "sting" — a quick scale
        // punch and bloom, then settle to a soft ambient glow.
        DispatchQueue.main.asyncAfter(deadline: .now() + revealDuration + 0.1) {
            playSplashSound()
            withAnimation(.easeOut(duration: 0.22)) {
                wordScale = 1.08
                glowRadius = 24
                glowOpacity = 0.9
                backgroundFlash = 1.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                withAnimation(.easeInOut(duration: 0.6)) {
                    wordScale = 1.0
                    glowRadius = 8
                    glowOpacity = 0.35
                    backgroundFlash = 0
                }
            }
        }

        // 3. Tagline slides up from the bottom + fades in, timed to land
        // about 1s after the "tudum" sting sound starts (which fires at
        // revealDuration + 0.1 above) -- not tied to when the sting's own
        // visual settle animation happens to finish.
        DispatchQueue.main.asyncAfter(deadline: .now() + revealDuration + 0.1 + 1.0) {
            withAnimation(.easeInOut(duration: 0.8)) {
                showTagline = true
            }
        }

        // 4. Animation's own part is done -- try to continue into Browse
        // (only actually happens once isReady is also true). Held to at
        // least minimumDisplayDuration total, even though the letter/sting/
        // tagline beats above wrap up well before that on their own.
        DispatchQueue.main.asyncAfter(deadline: .now() + minimumDisplayDuration) {
            animationFinished = true
            tryFinish()
        }
    }

    private func tryFinish() {
        guard animationFinished, isReady, !didFinish else { return }
        didFinish = true
        onFinished()
    }

    /// Plays once, timed to the wordmark's "sting" punch above -- silently
    /// does nothing until a real `source_media/splash_sound.<ext>` file
    /// exists (see AlbumLoader.splashSoundURL()'s header for why there's
    /// no bundled placeholder).
    private func playSplashSound() {
        guard let url = AlbumLoader.splashSoundURL() else { return }
        soundPlayer = try? AVAudioPlayer(contentsOf: url)
        soundPlayer?.play()
    }

    /// See the onDisappear comment above -- explicitly halts playback
    /// rather than just dropping the reference, so there's no window
    /// (window-close, fast re-launch, etc.) where the sting sound could
    /// keep audibly playing after this view is done with it.
    private func stopSplashSound() {
        soundPlayer?.stop()
        soundPlayer = nil
    }
}

/// The animated backdrop behind the wordmark: a breathing dark vignette,
/// a handful of slow, blurred red light beams drifting like Netflix's own
/// intro rays, and one central glow that punches bright at the wordmark's
/// "sting" (driven by `stingFlash`, 0 -> 1 -> settled-ambient) and keeps
/// slowly expanding outward for the whole splash duration -- by the time
/// `spreadDuration` elapses (matched to SplashView's minimumDisplayDuration,
/// so it lands right as the splash hands off to Browse) it's grown to just
/// under the nearest screen edge, never fully touching it.
private struct SplashBackground: View {
    var stingFlash: Double
    var spreadDuration: Double

    @State private var breathe = false
    /// 0 -> 1 over `spreadDuration`, driving the central glow's radius.
    @State private var spreadProgress: CGFloat = 0
    /// The glow's resting brightness once the sting has fired -- set once
    /// (via onChange below) and never reset, so the glow stays visible
    /// while it keeps growing, instead of fading back out like the sting
    /// itself does.
    @State private var ambientGlowOpacity: Double = 0

    /// Fraction of the distance from center to the nearest screen edge the
    /// glow grows to by the end of spreadDuration -- kept just under 1 so
    /// it visibly approaches the edge without ever fully reaching it.
    private let maxSpreadFraction: CGFloat = 0.92
    private let minGlowRadius: CGFloat = 70

    var body: some View {
        GeometryReader { geo in
            let edgeDistance = min(geo.size.width, geo.size.height) / 2
            let maxGlowRadius = edgeDistance * maxSpreadFraction
            let currentGlowRadius = minGlowRadius + (maxGlowRadius - minGlowRadius) * spreadProgress

            ZStack {
                // Base vignette: charcoal center fading to near-black edges,
                // slowly breathing in place of a static fill.
                RadialGradient(
                    colors: [Theme.background, Color.black],
                    center: .center,
                    startRadius: breathe ? 40 : 10,
                    endRadius: max(geo.size.width, geo.size.height)
                )

                AnimatedBeams()
                    .blendMode(.plusLighter)
                    .opacity(0.55)

                // Central glow behind the logo: bright punch at the sting,
                // settling to a soft ambient level, while its radius keeps
                // slowly growing the entire time.
                RadialGradient(
                    colors: [Theme.red.opacity(0.42), Theme.red.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: currentGlowRadius
                )
                .blendMode(.plusLighter)
                .opacity(max(ambientGlowOpacity, stingFlash))
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) {
                breathe = true
            }
            withAnimation(.linear(duration: spreadDuration)) {
                spreadProgress = 1
            }
        }
        .onChange(of: stingFlash) { _, flash in
            guard flash > 0, ambientGlowOpacity == 0 else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                ambientGlowOpacity = 0.4
            }
        }
    }
}

/// A small fixed set of long, thin, heavily-blurred red gradient bars,
/// each rotated to its own angle and independently pulsing
/// scale/opacity on a slow repeating loop -- deliberately understated
/// (this sits *behind* the wordmark) rather than a literal recreation of
/// Netflix's converging title beams.
private struct AnimatedBeams: View {
    private struct Beam {
        let angle: Double
        let length: CGFloat
        let thickness: CGFloat
        let duration: Double
        let delay: Double
    }

    private let beams: [Beam] = [
        Beam(angle: -35, length: 900, thickness: 150, duration: 6.5, delay: 0.0),
        Beam(angle: 18, length: 1100, thickness: 90, duration: 5.5, delay: 0.8),
        Beam(angle: 60, length: 800, thickness: 120, duration: 7.0, delay: 1.4),
        Beam(angle: -75, length: 950, thickness: 70, duration: 6.0, delay: 0.4),
    ]

    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(Array(beams.enumerated()), id: \.offset) { _, beam in
                RoundedRectangle(cornerRadius: beam.thickness / 2)
                    .fill(
                        LinearGradient(
                            colors: [Theme.red.opacity(0), Theme.red.opacity(0.4), Theme.red.opacity(0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: beam.length, height: beam.thickness)
                    .rotationEffect(.degrees(beam.angle))
                    .blur(radius: 55)
                    .opacity(animate ? 0.9 : 0.25)
                    .scaleEffect(animate ? 1.06 : 0.9)
                    .animation(
                        .easeInOut(duration: beam.duration).repeatForever(autoreverses: true).delay(beam.delay),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}
