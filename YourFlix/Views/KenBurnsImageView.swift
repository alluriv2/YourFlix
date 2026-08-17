import SwiftUI

/// A slow zoom + drift on a still photo, in the spirit of the browse
/// screen's cinematic feel. Each photo randomly rolls its own motion the
/// instant it appears -- see KenBurnsMotion.swift for the exact axes and
/// odds (zoom amount/direction, pan direction, easing curve, or
/// occasionally none at all) -- so a sequence of stills doesn't feel
/// mechanically repetitive.
///
/// Driven externally by `progress` (0...1, PlayerViewModel.itemProgress)
/// rather than a self-contained SwiftUI `withAnimation` -- so pausing
/// playback visibly freezes the zoom/pan too, not just the advance
/// countdown, and scrubbing the slider moves the zoom/pan to match.
struct KenBurnsImageView: View {
    let url: URL
    /// 0...1 progress through this photo's display.
    let progress: Double

    // @State, not plain `let`: `progress` changes ~20x/second (driven by
    // PlayerViewModel's tick timer), which reconstructs this struct just
    // as often. A plain `let` initialized from KenBurnsMotion.random()
    // would re-randomize on every single one of those reconstructions --
    // visible jitter instead of a smooth, consistent drift. @State is
    // SwiftUI's per-identity persistent storage: its random initial
    // value is only evaluated once (the first time this view's identity
    // -- PlayerView's outer `.id(currentIndex)` -- appears) and stays
    // fixed across every subsequent re-render for that same photo.
    @State private var motion = KenBurnsMotion.random()
    // Same reasoning as `motion` above: `content` used to call
    // NSImage(contentsOf:) directly, decoding the image fresh every time
    // body was evaluated. That was harmless when body only re-ran on real
    // state changes, but now it re-runs ~20x/second right along with
    // progress -- so the decoded image is loaded once here (on first
    // appearance of this photo's identity) and reused across every
    // subsequent tick, instead of re-decoding a full-resolution image
    // from disk 20 times a second.
    @State private var loadedImage: NSImage?

    var body: some View {
        GeometryReader { geo in
            let eased = motion.easing.apply(to: progress)
            content
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(motion.scale(at: eased))
                .offset(motion.offset(at: eased))
        }
        .onAppear {
            if loadedImage == nil {
                loadedImage = NSImage(contentsOf: url)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let loadedImage {
            Image(nsImage: loadedImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Color.gray.opacity(0.25)
        }
    }
}
