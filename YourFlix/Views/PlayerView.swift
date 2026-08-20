import AppKit
import AVKit
import SwiftUI

/// Fullscreen playback: sequences an album's photos and videos back-to-back
/// over the looping/ducking background song driven by PlayerViewModel.
///
/// The bottom control bar is Netflix-style: the slider shows/drags this
/// watch's position across the WHOLE album, +-5 skips 5 items forward or
/// back, and restart brings back the title card before jumping back to
/// item 1 -- see PlayerViewModel's header for the full picture. Videos
/// render via SilentVideoPlayerView (not
/// SwiftUI's own VideoPlayer, which has no way to hide its built-in
/// controls) so this custom bar is the only transport UI ever visible.
///
/// The control bar auto-hides after 3 seconds of no mouse movement and no
/// key press (Netflix-style), fading back in the instant either happens.
/// The header (back button/title) hides and reappears right along with
/// it -- both driven by the same `controlsVisible` state -- so the whole
/// UI clears off the photo/video together and comes back together on any
/// activity. The OS mouse pointer itself hides on that same timer too
/// (`NSCursor.setHiddenUntilMouseMoves`), so nothing lingers on screen
/// during an idle stretch of playback -- moving the mouse brings it (and
/// everything else) right back.
///
/// Playback doesn't start the instant this view appears: a title card
/// (TitleCardView) shows first, for a fixed `titleCardDuration` --
/// deliberately NOT skippable, so it always holds for its full length
/// like a movie's opening title rather than being rushed past. On a
/// genuinely first-ever open, background music starts right away
/// (`viewModel.startMusic()` below) and keeps playing straight through
/// the handoff; on a restart, music instead starts in sync with the
/// title card's own "YOURFLIX ORIGINAL" reveal -- see
/// `restartWithTitleCard()`. Either way, only the photo/video sequence
/// itself (`viewModel.start()`) waits for the title card's timer to
/// fire. The title card itself shows no back button or header of its
/// own (TitleCardView already displays the title large and centered) --
/// leaving during the title card still works immediately via Esc
/// (`.onExitCommand` below), since "not skippable" means "can't jump
/// ahead into the slideshow early," not "can't back out."
///
/// "Watch Again" (in `endOverlay`, once the whole album's played through)
/// and the control bar's own circular-arrow restart button both restart
/// the same way opening the player did in the first place -- title card
/// first, then the slideshow -- via the shared `showTitleCard(then:)`
/// helper below, so there's only the one restart experience no matter
/// which of the two you reach for.
struct PlayerView: View {
    @StateObject private var viewModel: PlayerViewModel
    let onExit: () -> Void

    @State private var controlsVisible = true
    @State private var hideWorkItem: DispatchWorkItem?
    @State private var keyMonitor: Any?
    @State private var showingTitleCard = true
    @State private var titleCardWorkItem: DispatchWorkItem?
    /// Flips permanently to true the first time a restart happens --
    /// distinguishes "genuinely first-ever open" (music starts right
    /// away, see onAppear below) from every title card after that
    /// (music instead starts synced to TitleCardView's own reveal, see
    /// restartWithTitleCard()).
    @State private var isRestartTitleCard = false

    private static let autoHideDelay: TimeInterval = 3.0
    private static let titleCardDuration: TimeInterval = 6.5

    init(album: Album, onExit: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: PlayerViewModel(album: album))
        self.onExit = onExit
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if showingTitleCard {
                // No back button/header here at all -- TitleCardView
                // already shows the title itself; leaving during this
                // phase still works instantly via Esc
                // (`.onExitCommand` below).
                TitleCardView(
                    album: viewModel.album,
                    onTitleRevealed: isRestartTitleCard ? { viewModel.startMusic() } : nil
                )
                .transition(.opacity)
            } else {
                if let item = viewModel.currentItem {
                    Group {
                        switch item.kind {
                        case .photo:
                            KenBurnsImageView(url: item.url, progress: viewModel.itemAnimationProgress)
                        case .video:
                            if let player = viewModel.videoPlayer {
                                SilentVideoPlayerView(player: player)
                            }
                        }
                    }
                    .id(viewModel.currentIndex)
                    .transition(.opacity)
                    // Tap anywhere on the photo/video itself to
                    // play/pause -- not just the control bar's dedicated
                    // button. Sits BELOW the header/control-bar VStack in
                    // this ZStack, so a tap that actually lands on a
                    // button, the scrubber, or the back pill is caught by
                    // that control first and never reaches this gesture;
                    // only genuinely empty screen space (which is most of
                    // it) falls through to toggle pause here. Also treated
                    // as activity, same as a mouse move, so the controls
                    // surface briefly to confirm the new paused/playing
                    // state instead of the tap seeming to do nothing.
                    .contentShape(Rectangle())
                    .onTapGesture {
                        registerActivity()
                        viewModel.togglePause()
                    }
                }

                VStack {
                    if controlsVisible {
                        header
                            .transition(.opacity)
                    }
                    Spacer()
                    if controlsVisible {
                        controlBar
                            .padding(.bottom, 18)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 26)
                .animation(.easeInOut(duration: 0.25), value: controlsVisible)

                if viewModel.isFinished {
                    endOverlay
                }
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active = phase {
                registerActivity()
            }
        }
        .onAppear {
            viewModel.startMusic()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
                registerActivity()
                return event
            }
            showTitleCard { viewModel.start() }
        }
        .onDisappear {
            titleCardWorkItem?.cancel()
            viewModel.stop()
            hideWorkItem?.cancel()
            // Guarantees the pointer is never left hidden once back on
            // Browse, regardless of whether it was mid-hidden right when
            // the player closed.
            NSCursor.setHiddenUntilMouseMoves(false)
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
        }
        .onExitCommand { close() } // Esc key -- works even during the title card
    }

    /// Shows the title card, holds for `titleCardDuration`, then runs
    /// `afterTitleCard` and resumes the normal auto-hide countdown --
    /// shared by both the initial `onAppear` and `restartWithTitleCard()`
    /// below, so opening the player fresh and hitting "Watch Again" go
    /// through the exact same sequence. Setting `showingTitleCard = true`
    /// when it's already true (the very first call, right on appear) is
    /// a harmless no-op -- SwiftUI doesn't animate a value that didn't
    /// actually change.
    private func showTitleCard(then afterTitleCard: @escaping () -> Void) {
        titleCardWorkItem?.cancel()
        withAnimation(.easeInOut(duration: 0.4)) {
            showingTitleCard = true
        }
        let workItem = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.4)) {
                showingTitleCard = false
            }
            afterTitleCard()
            scheduleAutoHide()
        }
        titleCardWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.titleCardDuration, execute: workItem)
    }

    /// Shared restart action -- used by both "Watch Again" (endOverlay)
    /// and the control bar's circular-arrow restart button, so either one
    /// brings back the title card before jumping back to item 1.
    ///
    /// Unlike a genuinely first-ever open (where music fades in right as
    /// the title card appears), a restart hard-cuts whatever's currently
    /// playing the instant the button's tapped -- then `isRestartTitleCard`
    /// makes the TitleCardView built in `body` pass a fresh
    /// `onTitleRevealed` closure, so a new track starts exactly in sync
    /// with the title card's own "YOURFLIX ORIGINAL" reveal instead of on
    /// some separately-scheduled timer that could drift out of step with
    /// what's actually on screen (see TitleCardView's own doc comment on
    /// `onTitleRevealed`).
    private func restartWithTitleCard() {
        print("[Restart] restartWithTitleCard() tapped at \(Date())")
        viewModel.stopMusicImmediately()
        isRestartTitleCard = true
        showTitleCard { viewModel.replay() }
    }

    /// Any mouse movement or key press calls this: shows the control bar
    /// immediately if it was hidden, and restarts the 3-second countdown
    /// to hide it again.
    private func registerActivity() {
        if !controlsVisible {
            controlsVisible = true
            // Explicitly cancels any pending cursor-hide -- covers the
            // keypress case below, where the OS's own "show again on
            // mouse move" behavior wouldn't otherwise fire.
            NSCursor.setHiddenUntilMouseMoves(false)
        }
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            controlsVisible = false
            // Hides the OS pointer itself, same trigger/timing as the
            // controls -- macOS automatically shows it again the instant
            // the mouse actually moves, so no matching "unhide" call is
            // needed on that path (registerActivity() above still
            // explicitly clears it for the keypress-only case).
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoHideDelay, execute: workItem)
    }

    private var header: some View {
        HStack(spacing: 20) {
            backButton

            Text(viewModel.album.title)
                .font(.headline)
                .foregroundColor(.white)

            Spacer()
        }
    }

    /// Just the "← Back" pill -- factored out of `header` so the title
    /// card (which doesn't show the rest of the header, to avoid
    /// duplicating the big title it's already displaying) can still
    /// offer the same way out.
    private var backButton: some View {
        Button(action: close) {
            Text("← Back")
                .font(.callout.bold())
        }
        .buttonStyle(.plain)
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Netflix-style control bar

    private var controlBar: some View {
        VStack(spacing: 12) {
            scrubber
            HStack(spacing: 28) {
                transportButton("backward.fill") { viewModel.skip(byItems: -5) }
                transportButton(viewModel.isPaused ? "play.fill" : "pause.fill") { viewModel.togglePause() }
                transportButton("forward.fill") { viewModel.skip(byItems: 5) }
                transportButton("arrow.counterclockwise") { restartWithTitleCard() }
                speedButton
                ratingButtons
            }
        }
    }

    /// Tapping shows a menu listing every PlayerViewModel.availableSpeeds
    /// choice (1x/1.25x/1.5x/2x/3x); picking one applies live to whatever
    /// is currently on screen -- see PlayerViewModel.setPlaybackSpeed(_:).
    /// The label itself is a capsule (not transportButton()'s fixed-size
    /// circle), since its width varies ("1x" vs "1.25x") where every
    /// other button here is a single, constant-width SF Symbol.
    /// `.menuStyle(.borderlessButton)` strips macOS's default menu-button
    /// chrome so the label reads like this row's other custom buttons
    /// instead of a system dropdown.
    private var speedButton: some View {
        Menu {
            ForEach(PlayerViewModel.availableSpeeds, id: \.self) { speed in
                Button(speedLabel(for: speed)) {
                    registerActivity()
                    viewModel.setPlaybackSpeed(speed)
                }
            }
        } label: {
            Text(speedLabel(for: viewModel.playbackSpeed))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .frame(minWidth: 38, minHeight: 38)
                .padding(.horizontal, 6)
                .background(Color.white.opacity(0.12))
                .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// "1x"/"2x"/"3x" for whole numbers, "1.25x"/"1.5x" otherwise -- every
    /// value in PlayerViewModel.availableSpeeds happens to be an exact
    /// binary fraction (quarters), so plain string interpolation never
    /// produces floating-point noise here.
    private func speedLabel(for speed: Double) -> String {
        if speed == speed.rounded() {
            return "\(Int(speed))x"
        }
        return "\(speed)x"
    }

    private func transportButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// Like/dislike for whatever photo or video is CURRENTLY on screen --
    /// sits right after the restart button, in the same transport-button
    /// row (still under the scrubber, same as before -- see controlBar).
    /// A dislike is the one that actually changes future playback: see
    /// PlayerViewModel.rate(_:) and AlbumLoader.curatedPlaylist(...) for
    /// how it permanently keeps that file out of every watch from here
    /// on, across launches, not just skipped for the rest of this one.
    /// Tapping whichever one's already active clears it back to neutral
    /// (a toggle, not a one-way switch) -- registerActivity() keeps this
    /// row's taps counted as activity like every other control, so
    /// rating a photo doesn't itself start the auto-hide countdown early.
    private var ratingButtons: some View {
        HStack(spacing: 16) {
            ratingButton(
                "hand.thumbsup.fill",
                isActive: viewModel.currentItemRating == .liked
            ) {
                registerActivity()
                viewModel.rate(.liked)
            }
            ratingButton(
                "hand.thumbsdown.fill",
                isActive: viewModel.currentItemRating == .disliked
            ) {
                registerActivity()
                viewModel.rate(.disliked)
            }
        }
    }

    private func ratingButton(_ systemImage: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isActive ? .white : .white.opacity(0.65))
                .frame(width: 28, height: 28)
                .background(isActive ? Theme.red : Color.white.opacity(0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// Progress across the WHOLE album (not just the current item) --
    /// draggable to jump to a different photo/video in the sequence.
    /// Netflix-style: a single thin line for the full track, with progress
    /// as a thin red line and a small red dot riding its leading edge --
    /// NOT a thick bar. The visible line/dot are small; the draggable hit
    /// area around them (`scrubberHitHeight`) is taller than what's drawn,
    /// purely so it's still comfortable to grab with a mouse.
    private var scrubber: some View {
        GeometryReader { geo in
            let fraction = viewModel.overallProgress
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: trackThickness)
                Capsule()
                    .fill(Theme.red)
                    .frame(width: max(0, geo.size.width * fraction), height: trackThickness)
                Circle()
                    .fill(Theme.red)
                    .frame(width: knobDiameter, height: knobDiameter)
                    .offset(x: max(0, min(geo.size.width - knobDiameter, geo.size.width * fraction - knobDiameter / 2)))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        registerActivity()
                        let dragged = min(1, max(0, value.location.x / geo.size.width))
                        viewModel.seek(toFraction: dragged)
                    }
            )
        }
        .frame(height: scrubberHitHeight)
    }

    private let trackThickness: CGFloat = 3
    private let knobDiameter: CGFloat = 10
    private let scrubberHitHeight: CGFloat = 18

    private var endOverlay: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 22) {
                Text("You've reached the end of \"\(viewModel.album.title)\"")
                    .font(.title2.bold())
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)

                HStack(spacing: 16) {
                    Button("↻ Watch Again") { restartWithTitleCard() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.red)

                    Button("Back to Browse") { close() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
            }
        }
    }

    private func close() {
        onExit()
    }
}
