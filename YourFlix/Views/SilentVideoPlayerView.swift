import AVKit
import SwiftUI

/// A minimal AVPlayerView wrapper with native playback controls turned off
/// entirely. SwiftUI's own `VideoPlayer` (AVKit) does NOT expose any way
/// to hide its built-in scrubber/controls -- there's no modifier for it --
/// so this bypasses `VideoPlayer` and talks to `AVPlayerView` (the real
/// underlying AppKit control it wraps) directly, setting
/// `controlsStyle = .none` to disable that chrome completely. PlayerView's
/// own bottom control bar is the only transport UI ever visible as a
/// result.
struct SilentVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
