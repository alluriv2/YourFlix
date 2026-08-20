import AVFoundation
import Combine
import Foundation
import SwiftUI

/// Drives playback of one album: sequences photos and videos back-to-back,
/// with one continuous music playlist running underneath the whole watch
/// -- title card AND slideshow alike, a single uninterrupted stream of
/// music rather than a handoff between two differently-styled tracks a
/// couple seconds apart. Videos play back muted (no audio of their own),
/// so the music never has to duck for them -- it only fades in once,
/// right at the very start (see startMusic()/playNextTrack(isFirst:)),
/// and fades out at the very end of the album. Each track is a random
/// pick from `slideshow_music/` (see AlbumLoader.randomSlideshowTrack());
/// when one finishes before the watch is over, another random pick
/// chains right in automatically (see handleTrackFinished(_:)), so the
/// music simply never runs dry no matter how many tracks that takes --
/// and two watches of the same title can still land on a different
/// sequence of tracks each time.
///
/// Netflix-style transport controls, all in PlayerView's bottom bar:
/// - `overallProgress` (0...1) is this watch's position across the WHOLE
///   album (all ~100-115 items), not just the current one -- what the
///   bottom slider shows and drags. Dragging it jumps to a different item
///   in the sequence (see seek(toFraction:)).
/// - `skip(byItems:)` moves +-N items forward/back (not seconds) --
///   clamped to the first/last item, never wrapping and never triggering
///   the end-of-show overlay on its own.
/// - `togglePause()` freezes/resumes whatever's currently showing (a
///   photo's own advance timer, or the video player) plus the background
///   song, together.
/// - Restart is just `replay()` -- back to item 1, same as "Watch Again".
///   Music for a restart is a separate concern entirely, owned by
///   PlayerView -- see replay()'s own doc comment below.
///
/// `itemAnimationProgress` (0...1) is a SEPARATE, purely cosmetic value:
/// progress through the current item's own display time, used only to
/// drive KenBurnsImageView's zoom/pan so it stays in sync with pausing.
/// It has no bearing on the slider.
///
/// Item-to-item handoffs are a single plain crossfade (see
/// `crossfadeDuration` below) -- an earlier attempt at 10 shuffled
/// transition styles (slides, zooms, blur, etc., in ItemTransitions.swift)
/// was pulled back out: some styles could still expose a flash of the
/// black background between items, and one (a 3D tilt) read as an old
/// overhead-projector twist rather than a clean cut. A plain crossfade
/// can't produce either problem -- both items stay anchored in place the
/// whole time, just swapping opacity -- and KenBurnsMotion.swift now
/// carries most of the visual variety anyway (see KenBurnsImageView).
@MainActor
final class PlayerViewModel: NSObject, ObservableObject {
    /// How long a photo shows at 1x speed -- see `currentPhotoDuration`
    /// below for how `playbackSpeed` scales this down.
    private static let basePhotoDuration: TimeInterval = 5.0
    private static let photoTickInterval: TimeInterval = 0.05
    /// The choices offered by the speed control in PlayerView's control bar.
    static let availableSpeeds: [Double] = [1.0, 1.25, 1.5, 2.0]
    /// How long the item-to-item crossfade animates for. Applied via an
    /// explicit withAnimation(...) around each currentIndex change below,
    /// rather than a `.animation(_:value:)` modifier in PlayerView --
    /// that modifier is unreliable when paired with a `.id()` keyed off
    /// the very same value (the id change resets what the modifier has
    /// to compare against), and most item changes originate from a Timer
    /// or NotificationCenter callback rather than a SwiftUI action, which
    /// never had an animated context to begin with either way.
    private static let crossfadeDuration: TimeInterval = 1.0

    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var isFinished: Bool = false
    @Published private(set) var videoPlayer: AVPlayer?
    @Published private(set) var isPaused: Bool = false
    /// Applies live to whatever's on screen right now, not just future
    /// items -- a video's `rate` is reassigned immediately (see
    /// setPlaybackSpeed(_:)), and a photo's remaining time recomputes on
    /// its very next tick since tickPhoto() reads `currentPhotoDuration`
    /// fresh every 0.05s rather than latching a duration at the start of
    /// the item. The background song is deliberately NOT affected --
    /// speeding up audio shifts its pitch, and there was no ask to speed
    /// up the music, only the photos/videos themselves.
    @Published private(set) var playbackSpeed: Double = 1.0
    /// 0...1 progress through the CURRENT item only -- feeds
    /// KenBurnsImageView's zoom/pan. NOT what the slider shows.
    @Published private(set) var itemAnimationProgress: Double = 0
    /// 0...1 progress across the WHOLE album -- what PlayerView's bottom
    /// slider binds to and drags.
    @Published private(set) var overallProgress: Double = 0
    /// The CURRENT item's like/dislike state, if any -- nil means
    /// neutral (never rated, or cleared back to neutral by tapping the
    /// same rating twice). Kept in sync inside showCurrentItem(), the
    /// one choke point every currentIndex change already passes through,
    /// so this is always accurate for whatever's on screen right now
    /// without PlayerView having to look it up separately. See rate(_:)
    /// below for how a tap actually changes it, and
    /// MediaRatingStore/AlbumLoader.curatedPlaylist(...) for how a
    /// dislike then keeps that file out of future watches.
    @Published private(set) var currentItemRating: MediaRating?

    let album: Album

    private var songPlayer: AVAudioPlayer?
    /// The track `songPlayer` is currently (or was most recently)
    /// playing -- passed to randomSlideshowTrack(excluding:) when
    /// chaining to the next track, so back-to-back picks don't repeat
    /// the same song two times in a row.
    private var lastTrackURL: URL?
    private var photoTickTimer: Timer?
    private var photoElapsed: TimeInterval = 0
    private var fadeTimer: Timer?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    /// Whether the CURRENT video is long enough to actually speed up --
    /// short videos (<= MediaScanner.shortVideoMaxDuration, e.g. Live
    /// Photos) always play at their normal 1x regardless of the selected
    /// `playbackSpeed`, since speeding up a ~1-2s clip makes it barely
    /// perceptible. A video's real duration isn't known synchronously
    /// when it starts (AVPlayer loads it asynchronously), so this starts
    /// false/undetermined and gets set for real the first time the
    /// periodic time observer below sees a valid duration -- see
    /// `hasAppliedInitialVideoRate` and `applyVideoRateIfNeeded()`.
    private var currentVideoQualifiesForSpeedUp = false
    /// Guards `applyVideoRateIfNeeded()`'s duration-based decision so it
    /// only runs ONCE per video (the first periodic-time-observer tick
    /// that reports a valid duration), rather than re-deciding on every
    /// tick for the rest of that video's playback.
    private var hasAppliedInitialVideoRate = false

    init(album: Album) {
        self.album = album
        super.init()
    }

    var currentItem: MediaItem? {
        guard album.media.indices.contains(currentIndex) else { return nil }
        return album.media[currentIndex]
    }

    /// Starts the continuous music playlist -- called by PlayerView as
    /// soon as the title card appears, so the same music plays
    /// underneath both the title card and (once its timer fires) the
    /// slideshow itself, with no handoff to a differently-styled track a
    /// couple seconds in. Keeps chaining to a fresh random pick for as
    /// long as playback continues -- see playNextTrack(isFirst:)/
    /// handleTrackFinished(_:) -- however many tracks that takes.
    func startMusic() {
        print("[Music] startMusic() called at \(Date())")
        playNextTrack(isFirst: true)
    }

    func start() {
        // Music is already playing -- see startMusic(), called by
        // PlayerView as soon as the title card appeared -- so there's
        // nothing to set up here, just start the photo/video sequence.
        // The same track keeps rolling right through this handoff, which
        // is the whole point: no seam between the title card's music and
        // the slideshow's.
        showCurrentItem()
    }

    func stop() {
        photoTickTimer?.invalidate()
        fadeTimer?.invalidate()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        removeTimeObserver()
        videoPlayer?.pause()
        videoPlayer = nil
        // Clears the delegate first -- otherwise a finish callback for
        // whatever track was still playing could fire right as this
        // tears down and chain into yet another track nobody's there to
        // hear.
        songPlayer?.delegate = nil
        songPlayer?.stop()
        songPlayer = nil
        lastTrackURL = nil
    }

    /// Hard-cuts whatever's currently playing, right now, with no fade --
    /// called the instant a restart begins (PlayerView's
    /// restartWithTitleCard(), for both "Watch Again" and the control
    /// bar's restart button), so the OLD track drops out immediately
    /// instead of continuing to play under the wordmark beat the way
    /// music does on a genuinely first-ever open. `lastTrackURL` is
    /// deliberately left set (not cleared, unlike stop()) so the next
    /// startMusic() call still avoids immediately repeating the very
    /// track that just got cut off.
    func stopMusicImmediately() {
        print("[Music] stopMusicImmediately() called at \(Date()), had songPlayer=\(songPlayer != nil)")
        fadeTimer?.invalidate()
        songPlayer?.delegate = nil
        songPlayer?.stop()
        songPlayer = nil
    }

    /// Resets the photo/video sequence back to item 1 -- does NOT touch
    /// `songPlayer` at all. Music for a restart is handled entirely by
    /// PlayerView (stopMusicImmediately() the instant the restart's
    /// tapped, startMusic() synced to the title card's own reveal
    /// timeline via TitleCardView.onTitleRevealed) -- this used to also
    /// rewind/replay whatever was in `songPlayer`, but that fought with
    /// the newer title-card-timed track, audibly restarting the music a
    /// second time right as the slideshow itself began.
    func replay() {
        isFinished = false
        withAnimation(.easeInOut(duration: Self.crossfadeDuration)) {
            currentIndex = 0
            showCurrentItem()
        }
    }

    // MARK: - Transport controls

    /// Toggles play/pause for whatever the current item is -- a photo's
    /// own advance timer, or the video player. The background song pauses
    /// and resumes right alongside it, so the whole watch genuinely
    /// freezes rather than just the visual.
    func togglePause() {
        isPaused.toggle()
        if isPaused {
            videoPlayer?.pause()
            songPlayer?.pause()
        } else {
            // Resuming via `.play()` would silently reset rate to 1x,
            // undoing whatever speed was selected -- setting `rate`
            // directly both resumes playback AND keeps the chosen speed
            // (or 1x, if this video is short enough to be exempt -- see
            // applyVideoRateIfNeeded()).
            applyVideoRateIfNeeded()
            songPlayer?.play()
        }
    }

    /// Sets playback speed directly to one of `availableSpeeds` -- called
    /// from the menu PlayerView's speed button opens, where the person
    /// picks a specific speed rather than stepping through them one at a
    /// time. Applies immediately: a playing video's `rate` is reassigned
    /// right here (a paused video picks up the new speed on the next
    /// `togglePause()` resume, same as any other resume), and a photo's
    /// own tick loop picks it up on its very next tick -- see
    /// `currentPhotoDuration`/`tickPhoto()`. Deliberately leaves
    /// `songPlayer` untouched either way -- only the photos/videos speed
    /// up, never the music.
    func setPlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
        applyVideoRateIfNeeded()
    }

    /// Applies `playbackSpeed` to `videoPlayer` -- but only when the
    /// CURRENT video has been determined to be long enough to qualify
    /// (see `currentVideoQualifiesForSpeedUp`'s doc comment); a short
    /// video always gets 1x here instead, regardless of the selected
    /// speed. A no-op while paused, same as before -- a paused video
    /// picks up the right rate on its next `togglePause()` resume.
    private func applyVideoRateIfNeeded() {
        guard !isPaused, videoPlayer != nil else { return }
        videoPlayer?.rate = currentVideoQualifiesForSpeedUp ? Float(playbackSpeed) : 1.0
    }

    /// Skips +-`delta` ITEMS in the sequence (a photo or a video counts
    /// as one item each) -- NOT seconds. Clamped to the first/last item:
    /// skipping forward past the end just lands on the last item rather
    /// than triggering the end-of-show overlay, and skipping backward
    /// past the start lands on the first item.
    func skip(byItems delta: Int) {
        let total = album.media.count
        guard total > 0 else { return }
        let target = max(0, min(total - 1, currentIndex + delta))
        guard target != currentIndex else { return }
        withAnimation(.easeInOut(duration: Self.crossfadeDuration)) {
            currentIndex = target
            showCurrentItem()
        }
    }

    /// Rates the item CURRENTLY on screen -- tapping the same rating it
    /// already has clears it back to neutral (see
    /// MediaRatingStore.toggle(_:for:)'s own doc comment for the exact
    /// toggle semantics), tapping the other one switches straight over.
    /// A dislike is the half that actually changes playback: it
    /// permanently excludes this file from every watch's selection from
    /// now on, across launches -- see AlbumLoader.curatedPlaylist(...).
    /// A like is recorded with the same permanence and reflected in the
    /// UI, but doesn't currently bias selection towards it.
    func rate(_ rating: MediaRating) {
        guard let item = currentItem else { return }
        currentItemRating = MediaRatingStore.shared.toggle(rating, for: item.url)
    }

    /// Scrubs to `fraction` (0...1) of the WHOLE album -- what
    /// PlayerView's draggable slider calls as the user drags. Jumps
    /// straight to whichever item that fraction lands on.
    func seek(toFraction fraction: Double) {
        let total = album.media.count
        guard total > 0 else { return }
        let clamped = min(1, max(0, fraction))
        let target = min(total - 1, Int(clamped * Double(total)))
        guard target != currentIndex else { return }
        withAnimation(.easeInOut(duration: Self.crossfadeDuration)) {
            currentIndex = target
            showCurrentItem()
        }
    }

    // MARK: - Internal sequencing

    /// Plays one random track from slideshow_music/ (excluding whichever
    /// track just finished, if any) and hands playback off to it.
    /// `isFirst` controls whether this is the very first track of the
    /// watch (called from startMusic(), fades in from silence via
    /// fade(to:duration:)) or a mid-watch chain-to-next (called from
    /// handleTrackFinished(_:), starts right at full volume since
    /// there's no silence to fade out of). Deliberately does NOT set
    /// `numberOfLoops` -- leaving it at its default of 0 (play once) is
    /// what lets `audioPlayerDidFinishPlaying` fire and chain to the next
    /// track below, instead of looping the same one forever.
    private func playNextTrack(isFirst: Bool = false) {
        guard let url = AlbumLoader.randomSlideshowTrack(excluding: lastTrackURL) else {
            print("[Music] playNextTrack: no track found in slideshow_music/ at \(Date())")
            return
        }
        lastTrackURL = url
        let player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        player?.volume = isFirst ? 0 : 0.85
        let playSucceeded = player?.play() ?? false
        print("[Music] playNextTrack isFirst=\(isFirst) url=\(url.lastPathComponent) playerCreated=\(player != nil) playSucceeded=\(playSucceeded) at \(Date())")
        songPlayer = player
        if isFirst {
            fade(to: 0.85, duration: 0.5)
        }
    }

    /// Hopped back to the main actor from audioPlayerDidFinishPlaying
    /// below -- chains straight into another random pick from the same
    /// pool, so the music never actually stops for as long as the title
    /// card + slideshow are on screen, even though any single track is
    /// almost certainly shorter than the whole watch. Guarded against
    /// `player` no longer being the live `songPlayer` -- e.g. if stop()
    /// already tore things down right as this track's finish callback
    /// was already in flight.
    private func handleTrackFinished(_ player: AVAudioPlayer) {
        guard player === songPlayer else { return }
        playNextTrack()
    }

    private func showCurrentItem() {
        photoTickTimer?.invalidate()
        photoElapsed = 0
        itemAnimationProgress = 0
        updateOverallProgress()
        isPaused = false
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        removeTimeObserver()
        videoPlayer?.pause()
        videoPlayer = nil

        guard let item = currentItem else {
            currentItemRating = nil
            finish()
            return
        }
        currentItemRating = MediaRatingStore.shared.rating(for: item.url)

        switch item.kind {
        case .photo:
            fade(to: 0.85, duration: 0.5)
            photoTickTimer = Timer.scheduledTimer(withTimeInterval: Self.photoTickInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tickPhoto() }
            }

        case .video:
            // Videos play muted -- the background music keeps playing at the
            // same steady volume as it does over photos, instead of ducking
            // down for the video's own (now silenced) audio track.
            fade(to: 0.85, duration: 0.5)
            let player = AVPlayer(url: item.url)
            player.isMuted = true
            videoPlayer = player
            // This video's real duration isn't known synchronously yet --
            // start at a plain 1x via `.play()` and let the periodic time
            // observer below apply the real rate (chosen speed, or 1x if
            // this turns out to be a short video) the moment its duration
            // becomes available, via applyVideoRateIfNeeded().
            currentVideoQualifiesForSpeedUp = false
            hasAppliedInitialVideoRate = false
            player.play()
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.advance() }
            }
            let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
                guard let self, let player, let duration = player.currentItem?.duration,
                      duration.isValid, !duration.isIndefinite else { return }
                let totalSeconds = CMTimeGetSeconds(duration)
                guard totalSeconds > 0 else { return }
                if !self.hasAppliedInitialVideoRate {
                    self.hasAppliedInitialVideoRate = true
                    self.currentVideoQualifiesForSpeedUp = totalSeconds > MediaScanner.shortVideoMaxDuration
                    self.applyVideoRateIfNeeded()
                }
                self.itemAnimationProgress = min(1, max(0, CMTimeGetSeconds(time) / totalSeconds))
                self.updateOverallProgress()
            }
        }
    }

    /// How long the CURRENT photo shows for, at whatever `playbackSpeed`
    /// is right now -- recomputed on every call rather than latched once
    /// per item, so a mid-photo speed change (see cyclePlaybackSpeed())
    /// takes effect on the very next tick instead of waiting for the next
    /// item to start.
    private var currentPhotoDuration: TimeInterval {
        Self.basePhotoDuration / playbackSpeed
    }

    private func tickPhoto() {
        guard !isPaused else { return }
        photoElapsed += Self.photoTickInterval
        itemAnimationProgress = min(1, photoElapsed / currentPhotoDuration)
        updateOverallProgress()
        if photoElapsed >= currentPhotoDuration {
            advance()
        }
    }

    /// Recomputes `overallProgress` (whole-album position) from
    /// `currentIndex` and how far into that item we are. Called any time
    /// either input changes -- item transitions, photo ticks, and video
    /// time-observer updates alike -- so the bottom slider creeps forward
    /// smoothly rather than only jumping at item boundaries.
    private func updateOverallProgress() {
        let total = album.media.count
        guard total > 0 else {
            overallProgress = 0
            return
        }
        overallProgress = (Double(currentIndex) + itemAnimationProgress) / Double(total)
    }

    private func removeTimeObserver() {
        if let observer = timeObserver {
            videoPlayer?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    private func advance() {
        let next = currentIndex + 1
        if next >= album.media.count {
            currentIndex = next
            finish()
        } else {
            withAnimation(.easeInOut(duration: Self.crossfadeDuration)) {
                currentIndex = next
                showCurrentItem()
            }
        }
    }

    private func finish() {
        isFinished = true
        // Fully stops the player once it's faded down, rather than
        // leaving it sitting there "playing" at volume 0 for however
        // long the person lingers on the end screen before tapping
        // Watch Again -- possibly a long while. A silent AVAudioPlayer
        // idling in the background for an extended stretch is exactly
        // the kind of state macOS's power management can deprioritize,
        // and there's no guarantee it comes back cleanly the instant a
        // brand new player tries to start playing again later. Stopping
        // it outright (same as stopMusicImmediately(), which a restart
        // calls right away regardless) removes that whole class of risk
        // rather than leaving two different "how did we get to silence"
        // histories for the two restart paths to diverge on.
        fade(to: 0, duration: 0.6) { [weak self] in
            self?.songPlayer?.stop()
            self?.songPlayer = nil
        }
    }

    /// Ramps the song's volume to `target` over `duration` seconds, then
    /// calls `completion` (if given). Runs on the main run loop's Timer,
    /// touching only the locally-captured AVAudioPlayer (not `self`), so
    /// it's safe outside the @MainActor hop -- `completion` runs from
    /// that same Timer closure once the ramp's last step lands, so it
    /// naturally never fires if a later `fade(...)`/`stopMusicImmediately()`
    /// call invalidates this timer first.
    ///
    /// This went through two other designs in between -- AVAudioPlayer's
    /// own native `setVolume(_:fadeDuration:)` (flaky when called
    /// repeatedly on the same player: tracks would start fine and then
    /// cut to silence out of nowhere partway through a watch), and a
    /// hand-rolled ramp scheduled via chained `DispatchQueue.global()
    /// .asyncAfter` calls on a background queue (regressed further --
    /// no music at all, and the end-of-slideshow fade-out/stop stopped
    /// firing too). Both are reverted. This plain main-thread Timer is
    /// the version that was actually confirmed audible in practice; its
    /// one known issue is a fade-in that can occasionally lag behind the
    /// title card's reveal on a restart, when TitleCardView's synchronous
    /// poster-backdrop decode is stalling the main thread at that exact
    /// moment -- a real but narrower problem than total silence, and one
    /// worth tackling by getting that decode off the main thread /
    /// pre-warming the cache earlier, not by continuing to swap out this
    /// fade mechanism.
    private func fade(to target: Float, duration: TimeInterval, completion: (() -> Void)? = nil) {
        fadeTimer?.invalidate()
        guard let player = songPlayer else { return }
        let steps = 12
        let stepDuration = duration / Double(steps)
        let startVolume = player.volume
        let delta = (target - startVolume) / Float(steps)
        var completed = 0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: stepDuration, repeats: true) { timer in
            completed += 1
            player.volume = max(0, min(1, startVolume + delta * Float(completed)))
            if completed >= steps {
                timer.invalidate()
                completion?()
            }
        }
    }

}

/// Conformance lives in its own extension so the delegate callback stays
/// visually separate from PlayerViewModel's own API -- AVAudioPlayer
/// calls this off in its own time, not necessarily from the main actor,
/// so it's marked `nonisolated` and hops back over to
/// handleTrackFinished(_:) above for the actual chaining logic.
extension PlayerViewModel: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.handleTrackFinished(player)
        }
    }
}
