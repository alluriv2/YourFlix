import AVFoundation
import AppKit
import Foundation
import ImageIO

/// Every title (movie/slideshow) in the app is discovered directly from
/// the folder structure under `source_media/images/` -- no manually
/// authored title list. See MediaScanner.swift's header for the full
/// picture of how a folder becomes a flat title vs. a multi-season show,
/// how season order/captions get decided, and the minimum-item filter.
/// `source_media/titles.json` still exists, but purely as an output --
/// MediaScanner rewrites it fresh on every scan as a human-readable
/// record of what got discovered; nothing in this app reads it as input
/// anymore.
///
/// Optional per-title customization: "<folder name>.info.json" /
/// "<folder name>.cover.<ext>" as loose files, sitting directly in
/// source_media, override that title's display name/blurb/tags and
/// poster (a single, deliberately-fixed image -- never randomized).
/// For a curated POOL instead of one fixed image, LIKE photos during a
/// normal watch (the player's thumbs-up button) instead -- see
/// MediaRatingStore.swift's header. Poster resolution order, per title
/// or season, is: explicit `.cover.<ext>` file (if any) > a random pick
/// among that title/season's own LIKED photos (if it has any) > a random
/// photo from the whole title/season. Every random tier is picked once
/// per app run and stays fixed for that run -- see
/// pickPosterSource(id:coverURL:media:) below.
/// Background music is NOT per-title -- see
/// randomSlideshowTrack() below, which picks randomly from one shared
/// pool (`source_media/music/slideshow/`) used for both the title card
/// and the slideshow (any leftover "<title>.song.<ext>" files are simply
/// ignored now). The splash screen's one-time chime is separate --
/// see splashSoundURL() below, which looks in `source_media/music/hero/`.
enum AlbumLoader {
    static let photoExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]

    /// The key MediaScanner uses in an Album/Season's internal grouping
    /// for a flat title's own (only) group, since a title with no seasons
    /// still needs a group to hang its buckets on.
    static let allBucketsKey = "__all__"

    /// Finds `source_media` and hands off to MediaScanner.scanAlbums(...)
    /// for the real work. This is a plain (non-async) function that does
    /// real file I/O and can take real time on a cache miss -- see
    /// MediaScanner.swift's header -- so callers should run it off the
    /// main thread (RootView does this via `Task.detached`), never call
    /// it directly from a view body.
    ///
    /// Media is intentionally NOT bundled inside the .app -- Xcode's
    /// build system copies every bundle resource into the built product
    /// on every build, and a real library here can run tens of GB, which
    /// would blow through available disk space on every single build.
    /// Instead the app reads straight from a "source_media" folder sitting
    /// as a PLAIN FOLDER on disk (a sibling of the repo, or, for a fresh
    /// clone, a sibling of YourFlix.xcodeproj itself -- see
    /// resolveSourceRoot() below), never as an Xcode bundle resource, so
    /// nothing ever gets copied into the build at all.
    static func loadAlbums() -> [Album] {
        guard let sourceRoot = resolveSourceRoot() else {
            print("AlbumLoader: couldn't find a source_media folder in any known location.")
            return []
        }
        return MediaScanner.scanAlbums(sourceRoot: sourceRoot)
    }

    /// Finds `source_media` on disk -- factored out of loadAlbums() above
    /// so the music-library lookups below (splashSoundURL, etc.) can
    /// locate it too, without each duplicating this same search.
    static func resolveSourceRoot() -> URL? {
        var roots: [URL] = []
        let fm = FileManager.default

        func addIfDir(_ url: URL?) {
            guard let url else { return }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                roots.append(url)
            }
        }

        // 1. Explicit override, e.g. to point at a different media folder
        //    for testing — set YOURFLIX_MEDIA_PATH in the Xcode scheme's
        //    "Environment Variables" (Product -> Scheme -> Edit Scheme),
        //    or when launching the built app from Terminal.
        if let override = ProcessInfo.processInfo.environment["YOURFLIX_MEDIA_PATH"] {
            addIfDir(URL(fileURLWithPath: override, isDirectory: true))
        }

        // 2. Sibling of the .app itself — the shipped layout: a folder
        //    containing both "YourFlix.app" and "source_media/" side by
        //    side (that pair together is the actual gift — zip/AirDrop
        //    them as one folder).
        addIfDir(
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("source_media", isDirectory: true)
        )

        // 3. Repo-root sibling, derived from THIS SOURCE FILE's own
        //    on-disk location -- no hardcoded absolute path anywhere.
        //    This is what makes Cmd+R in Xcode work with zero setup, on
        //    ANY machine, including this project's own dev machine:
        //    Xcode's build product lives deep inside DerivedData,
        //    nowhere near the actual project folder, so (2) above won't
        //    find `source_media` there during development -- but
        //    #filePath always resolves to THIS file's real absolute path
        //    on whichever machine compiled it, and this file always
        //    lives at "<repo root>/YourFlix/Services/AlbumLoader.swift",
        //    so walking up three path components (the filename, then
        //    Services/, then YourFlix/) lands back on the repo root no
        //    matter whose machine, or where on disk, that particular
        //    checkout sits. The repo ships a `source_media/` scaffold
        //    right there (empty `images/`, `music/hero/`,
        //    `music/slideshow/`, each holding just a `.gitkeep`
        //    placeholder plus the real bundled music, and
        //    `source_media/README.md`) so this path always exists and
        //    has somewhere for real content to live -- see the repo's
        //    own .gitignore for how that real content then stays out of
        //    version control. For local development, drop your own
        //    library directly into THIS repo's own `source_media/`
        //    folder (or point (1) above at wherever it actually lives via
        //    YOURFLIX_MEDIA_PATH) -- no path to hardcode, no rebuild
        //    needed either way.
        addIfDir(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // Services/
                .deletingLastPathComponent() // YourFlix/
                .deletingLastPathComponent() // repo root
                .appendingPathComponent("source_media", isDirectory: true)
        )

        // 4. Legacy fallback: a "media" folder actually bundled inside
        //    the app's own Resources, in case that's ever intentionally
        //    done again.
        if let resourceURL = Bundle.main.resourceURL {
            addIfDir(resourceURL)
            addIfDir(resourceURL.appendingPathComponent("media", isDirectory: true))
        }

        return roots.first
    }

    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "caf"]

    /// A single fixed sound played once when the splash screen appears --
    /// any file inside `source_media/music/hero/` named "splash_sound.<ext>".
    /// Deliberately stays a single fixed file (not a random pool like
    /// randomSlideshowTrack() below) -- the hero/splash beat is a
    /// consistent studio-ident moment every time, not something that
    /// should vary watch to watch. Not shipped with the app (Netflix's
    /// own startup chime is a trademarked sound, not something to
    /// reproduce) -- returns nil, and SplashView just plays nothing,
    /// until a real file is dropped in.
    static func splashSoundURL() -> URL? {
        guard let sourceRoot = resolveSourceRoot() else { return nil }
        let folder = sourceRoot.appendingPathComponent("music/hero", isDirectory: true)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return nil
        }
        return entries.first {
            $0.deletingPathExtension().lastPathComponent == "splash_sound"
                && audioExtensions.contains($0.pathExtension.lowercased())
        }
    }

    /// Every audio file directly inside `source_media/music/<folderName>`
    /// (not recursive) -- the shared implementation behind
    /// randomSlideshowTrack() below.
    private static func audioFiles(in folderName: String) -> [URL] {
        guard let sourceRoot = resolveSourceRoot() else { return [] }
        let folder = sourceRoot.appendingPathComponent("music/\(folderName)", isDirectory: true)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// A random track from `source_media/music/slideshow/` -- this single
    /// pool now scores BOTH the title card and the slideshow that follows
    /// it (see PlayerViewModel.startMusic()/playNextTrack()): using one
    /// shared pool for both means the music already playing under the
    /// title card just keeps going right into the slideshow, instead of
    /// handing off to a differently-styled track a couple seconds in.
    /// Replaces the old per-title `<title>.song.<ext>` companion file
    /// entirely: every watch of every title gets a fresh random pick,
    /// rather than one fixed song per title. Pass `excluding` (the track
    /// that just finished) to avoid immediately repeating it when chaining
    /// to the next one -- falls back to allowing a repeat if the pool only
    /// has that one track. nil (silence) until tracks actually exist in
    /// that folder.
    static func randomSlideshowTrack(excluding: URL? = nil) -> URL? {
        let tracks = audioFiles(in: "slideshow")
        guard let excluding, tracks.count > 1 else { return tracks.randomElement() }
        let remaining = tracks.filter { $0 != excluding }
        return remaining.randomElement() ?? tracks.randomElement()
    }

    /// Builds one watch's worth of curated playback media: up to
    /// `photoCap` true photos, up to `shortVideoCap` short (<=5s) videos
    /// (Live Photos land here), and up to `longVideoCap` longer videos —
    /// each pool picked one-per-time-bucket so its own timeline is
    /// covered evenly rather than front-loaded. The picked photos and
    /// videos are then woven together with `interleave(photos:videos:)`
    /// (not a plain shuffle) so that no two videos ever land back-to-back
    /// — short-short, short-long, and long-long are all kept apart by at
    /// least one photo. Call this fresh every time playback starts (not
    /// once at app launch), so watching the same title/season twice gives
    /// two different cuts.
    ///
    /// If some buckets came up short on their first pass (a sparse
    /// stretch of the timeline, or simply not enough distinct files in
    /// that time-slice), extra passes loop back to the first bucket of
    /// that pool and keep pulling from whatever still has candidates
    /// left, until either the cap is reached or the whole pool really is
    /// exhausted.
    ///
    /// Falls back to `fullMedia`, still shuffled (never left in filename/
    /// chronological order), if `buckets` is nil or empty -- e.g.
    /// MediaScanner found no files for this group. Playback never comes
    /// up empty just because curation data is missing.
    ///
    /// Every disliked file (MediaRatingStore.shared.dislikedPaths -- see
    /// PlayerViewModel.rate(_:)) is filtered out BEFORE any of the above
    /// picking happens, from `fullMedia` and from every individual bucket
    /// alike, so a dislike is a genuine permanent exclusion from every
    /// future watch, not just something that could still get picked back
    /// in by a later bucket pass.
    static func curatedPlaylist(
        fullMedia: [MediaItem],
        buckets: MediaBucketGroup?,
        photoCap: Int = 100,
        shortVideoCap: Int = 10,
        longVideoCap: Int = 5
    ) -> [MediaItem] {
        let dislikedPaths = MediaRatingStore.shared.dislikedPaths

        func excludingDisliked(_ items: [MediaItem]) -> [MediaItem] {
            guard !dislikedPaths.isEmpty else { return items }
            return items.filter { !dislikedPaths.contains($0.url.path) }
        }

        func excludingDisliked(_ groups: [[MediaItem]]) -> [[MediaItem]] {
            guard !dislikedPaths.isEmpty else { return groups }
            return groups.map { excludingDisliked($0) }
        }

        guard let buckets, !buckets.photoBuckets.isEmpty else {
            return excludingDisliked(fullMedia).shuffled()
        }

        func pickRoundRobin(_ source: [[MediaItem]], cap: Int) -> [MediaItem] {
            guard cap > 0, !source.isEmpty else { return [] }
            var remaining = source
            var picked: [MediaItem] = []
            var madeProgress = true
            while picked.count < cap && madeProgress {
                madeProgress = false
                for i in remaining.indices {
                    guard picked.count < cap else { break }
                    guard !remaining[i].isEmpty else { continue }
                    let choice = Int.random(in: 0..<remaining[i].count)
                    picked.append(remaining[i].remove(at: choice))
                    madeProgress = true
                }
            }
            return picked
        }

        let photos = pickRoundRobin(excludingDisliked(buckets.photoBuckets), cap: photoCap).shuffled()
        let shortVideos = pickRoundRobin(excludingDisliked(buckets.shortVideoBuckets), cap: shortVideoCap)
        let longVideos = pickRoundRobin(excludingDisliked(buckets.longVideoBuckets), cap: longVideoCap)
        let videos = (shortVideos + longVideos).shuffled()

        return interleave(photos: photos, videos: videos)
    }

    /// Places `videos` into the gaps around `photos` (before the first
    /// photo, between each consecutive pair, and after the last one) so
    /// that no two videos ever end up adjacent in the returned sequence:
    /// every gap gets at most one video, and any two distinct gaps
    /// always have at least one photo sitting between them by
    /// construction. `photos` and `videos` should already be shuffled —
    /// this only decides WHERE each video lands, not the order within
    /// each group.
    ///
    /// The only way two videos can still end up back-to-back is if there
    /// are literally more videos than gaps (gaps == photos.count + 1) —
    /// only possible for a very photo-sparse title/season. In that rare
    /// case, extra videos cycle round-robin through the same gaps rather
    /// than piling every overflow video into a single spot, and if there
    /// are no photos at all, videos are simply returned as-is (already
    /// shuffled) since there's nothing to separate them with.
    private static func interleave(photos: [MediaItem], videos: [MediaItem]) -> [MediaItem] {
        guard !videos.isEmpty else { return photos }
        guard !photos.isEmpty else { return videos }

        let gapCount = photos.count + 1
        let gapOrder = Array(0..<gapCount).shuffled()
        var videosByGap: [Int: [MediaItem]] = [:]

        if videos.count <= gapCount {
            for (i, video) in videos.enumerated() {
                videosByGap[gapOrder[i], default: []].append(video)
            }
        } else {
            for (i, video) in videos.enumerated() {
                let gap = gapOrder[i % gapCount]
                videosByGap[gap, default: []].append(video)
            }
        }

        var result: [MediaItem] = []
        for gap in 0..<gapCount {
            if let vids = videosByGap[gap] {
                result.append(contentsOf: vids)
            }
            if gap < photos.count {
                result.append(photos[gap])
            }
        }
        return result
    }

    /// Decoded/downsampled poster images, keyed by "<albumID>-<pixelSize>"
    /// (grid tiles and the hero banner want different sizes from the same
    /// album, so both live in here side by side). Purely a perf cache --
    /// an eviction under memory pressure just means the next call
    /// re-generates from `pickedSource` below, not a re-roll of *which*
    /// photo gets shown.
    private static let posterCache = NSCache<NSString, NSImage>()

    /// Which specific media file backs a given album's poster THIS run,
    /// once decided -- see `pickPosterSource(for:)`. Deliberately a plain
    /// dictionary, not part of `posterCache`: it has to survive an
    /// `NSCache` eviction and stay stable for the whole app session, or an
    /// album's tile photo could visibly change under you mid-browse if the
    /// system reclaims the decoded-image cache and something re-picks.
    private static var pickedSource: [String: MediaItem] = [:]
    private static let pickLock = NSLock()

    /// The pool a poster should actually be picked from: whichever of a
    /// group's own `media` are currently LIKED (see MediaRatingStore),
    /// when at least one is, otherwise the group's full media. This is
    /// what replaced the old feature_image/-folder curated-pool
    /// mechanism -- liking a good photo during a normal watch is what
    /// curates a title/season's thumbnail pool now, so there's no
    /// separate folder to drop duplicate copies of images into. Shared
    /// by every call site below so "liked pool if present, else
    /// everything" is decided in exactly one place rather than
    /// re-implemented per caller. Deliberately NOT cached itself --
    /// MediaRatingStore.shared.likedPaths is a cheap in-memory lookup, so
    /// this is safe to recompute on every call; only the actual RANDOM
    /// PICK from within it gets cached, in `pickedSource` below.
    private static func posterCandidates(media: [MediaItem]) -> [MediaItem] {
        let liked = MediaRatingStore.shared.likedPaths
        guard !liked.isEmpty else { return media }
        let likedItems = media.filter { liked.contains($0.url.path) }
        return likedItems.isEmpty ? media : likedItems
    }

    /// Poster *source* resolution -- decides which file to use, not how
    /// it's rendered. An explicit `<title>.cover.<ext>` always wins (a
    /// deliberate curated choice, so it never gets randomized away).
    /// Otherwise: a random photo from `media` (already narrowed to this
    /// group's own liked photos when it has any -- see
    /// posterCandidates(media:) above), chosen once per app run and
    /// cached in `pickedSource` so it stays put for
    /// scrolling/re-renders/revisits and only reshuffles on the next
    /// launch. Falls back to a random video (frame-extracted by the
    /// caller) only for the rare all-video album; nil if there's truly no
    /// media at all, in which case the view falls back to a text-only
    /// gradient tile.
    /// Generic form behind pickPosterSource(for: Album) and
    /// pickPosterSource(for: Season) below -- both an Album and a Season
    /// have an id, an optional explicit cover, and a flat media list, so
    /// there's nothing season-specific here at all; `pickedSource` is
    /// keyed by whichever id gets passed in, so an album and its own
    /// seasons never collide with each other's cached pick.
    private static func pickPosterSource(id: String, coverURL: URL?, media: [MediaItem]) -> MediaItem? {
        if let cover = coverURL {
            return MediaItem(kind: .photo, url: cover, name: cover.lastPathComponent)
        }

        pickLock.lock()
        defer { pickLock.unlock() }
        if let cached = pickedSource[id] {
            return cached
        }

        let photos = media.filter { $0.kind == .photo }
        let chosen = photos.randomElement() ?? media.filter { $0.kind == .video }.randomElement()
        if let chosen {
            pickedSource[id] = chosen
        }
        return chosen
    }

    private static func pickPosterSource(for album: Album) -> MediaItem? {
        pickPosterSource(
            id: album.id, coverURL: album.coverURL,
            media: posterCandidates(media: album.media)
        )
    }

    private static func pickPosterSource(for season: Season) -> MediaItem? {
        pickPosterSource(
            id: season.id, coverURL: season.coverURL,
            media: posterCandidates(media: season.media)
        )
    }

    /// Downsamples an image file straight from disk via ImageIO, instead
    /// of decoding the full multi-thousand-pixel original with
    /// `NSImage(contentsOf:)` and letting the view layer scale it down at
    /// render time. That naive path is what actually produced the
    /// pixelated/soft-looking thumbnails before -- SwiftUI's runtime
    /// scaling isn't a real high-quality resample, and without
    /// `kCGImageSourceCreateThumbnailWithTransform` a photo's EXIF
    /// orientation is ignored, so portrait photos can render
    /// sideways/skewed. ImageIO's thumbnail generator does a proper
    /// resample AND applies orientation, and it's dramatically
    /// faster/lighter than fully decoding a 4000px iPhone photo just to
    /// show it in a 300pt-wide tile.
    private static func downsampledImage(from url: URL, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
    }

    /// Same idea as `downsampledImage`, for the rare case where an
    /// album's picked poster source is a video (only happens when it has
    /// no photos at all): caps the extracted frame's size instead of
    /// pulling a full-resolution 4K frame for a small tile.
    private static func downsampledVideoFrame(from url: URL, maxPixelSize: CGFloat) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        guard let cgImage = try? generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Generic form behind poster(for: Album) and poster(for: Season) --
    /// same reasoning as pickPosterSource(id:coverURL:media:) above: only
    /// the id/cover/media triple actually matters, so a season reuses the
    /// exact same cache + decode path as an album, just keyed by the
    /// season's own id.
    private static func poster(id: String, coverURL: URL?, media: [MediaItem], maxPixelSize: CGFloat) -> NSImage? {
        let key = "\(id)-\(Int(maxPixelSize))" as NSString
        if let cached = posterCache.object(forKey: key) {
            return cached
        }
        guard let source = pickPosterSource(id: id, coverURL: coverURL, media: media) else { return nil }

        let image: NSImage?
        switch source.kind {
        case .photo:
            image = downsampledImage(from: source.url, maxPixelSize: maxPixelSize)
        case .video:
            image = downsampledVideoFrame(from: source.url, maxPixelSize: maxPixelSize)
        }
        if let image {
            posterCache.setObject(image, forKey: key)
        }
        return image
    }

    private static func poster(for album: Album, maxPixelSize: CGFloat) -> NSImage? {
        poster(
            id: album.id, coverURL: album.coverURL,
            media: posterCandidates(media: album.media),
            maxPixelSize: maxPixelSize
        )
    }

    private static func poster(for season: Season, maxPixelSize: CGFloat) -> NSImage? {
        poster(
            id: season.id, coverURL: season.coverURL,
            media: posterCandidates(media: season.media),
            maxPixelSize: maxPixelSize
        )
    }

    /// Grid-tile-sized poster for AlbumTile -- 900px covers even a 3x
    /// Retina tile at its max ~300pt width with headroom to spare.
    static func tileThumbnail(for album: Album) -> NSImage? {
        poster(for: album, maxPixelSize: 900)
    }

    /// Large hero-banner-sized poster for HeroView -- 1800px so a
    /// full-window-width, 460pt-tall banner still looks crisp on a 2x
    /// Retina display.
    static func posterImage(for album: Album) -> NSImage? {
        poster(for: album, maxPixelSize: 1800)
    }

    /// Season-tile-sized poster for SeasonListView's grid -- season tiles
    /// sit at a similar (actually slightly smaller) width to a Titles-row
    /// card, so 700px gives the same quality headroom tileThumbnail's
    /// 900px gives a wider Titles card.
    static func seasonThumbnail(for season: Season) -> NSImage? {
        poster(for: season, maxPixelSize: 700)
    }

    /// Re-rolls the poster for one album on demand, e.g. from AlbumTile's
    /// hover-only refresh button -- picks a different random photo (not
    /// just any random photo: the previous pick is excluded from the pool
    /// so the button visibly does something, unless the album only has
    /// one photo total to begin with) and drops both the tile- and
    /// hero-sized decoded images so the very next draw regenerates from
    /// the new pick. No-op for an album with an explicit
    /// `<title>.cover.<ext>` -- that's a deliberate curated choice with
    /// only one photo, nothing to shuffle to.
    /// Generic form behind refreshPoster(for: Album) and
    /// refreshPoster(for: Season) below.
    private static func refreshPoster(id: String, coverURL: URL?, media: [MediaItem], cacheKeys: [String]) {
        guard coverURL == nil else { return }

        pickLock.lock()
        let previous = pickedSource[id]
        let photos = media.filter { $0.kind == .photo }
        let pool = previous.map { prev in photos.filter { $0.url != prev.url } } ?? photos
        let candidates = pool.isEmpty ? photos : pool
        let chosen = candidates.randomElement() ?? media.filter { $0.kind == .video }.randomElement()
        if let chosen {
            pickedSource[id] = chosen
        } else {
            pickedSource.removeValue(forKey: id)
        }
        pickLock.unlock()

        for key in cacheKeys {
            posterCache.removeObject(forKey: key as NSString)
        }
    }

    static func refreshPoster(for album: Album) {
        refreshPoster(
            id: album.id, coverURL: album.coverURL,
            media: posterCandidates(media: album.media),
            cacheKeys: ["\(album.id)-900", "\(album.id)-1800"]
        )
    }

    /// Same idea as refreshPoster(for: Album), for a season tile's
    /// hover-only refresh button in SeasonListView -- only one cache size
    /// exists for a season (seasonThumbnail's 700px), so there's just the
    /// one key to drop.
    static func refreshPoster(for season: Season) {
        refreshPoster(
            id: season.id, coverURL: season.coverURL,
            media: posterCandidates(media: season.media),
            cacheKeys: ["\(season.id)-700"]
        )
    }
}
