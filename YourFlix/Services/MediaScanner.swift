import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import ImageIO

/// Scans `source_media/images` directly and builds the full `[Album]`
/// list the app displays -- fully convention-driven, no manually-authored
/// title list. Every photo's capture time comes from its EXIF data (via
/// ImageIO, including HEIC), every video's creation time and duration come
/// from AVFoundation. `AlbumLoader.loadAlbums()` is the only entry point
/// other code should call -- it finds `source_media` on disk and hands
/// off to `scanAlbums(sourceRoot:)` below.
///
/// --- How titles/shows get discovered ---
///
/// Every direct subfolder of `source_media/images/` is a candidate title:
/// - If it contains one or more subfolders of its own, it's a multi-season
///   SHOW -- each subfolder is one season. Any files sitting loose
///   directly in the show folder itself (alongside its season subfolders)
///   are ignored; only the subfolders count once there's at least one.
/// - Otherwise (files directly inside, no subfolders) it's a flat TITLE.
///
/// Files sitting loose directly at the TOP LEVEL of `images/` itself
/// (not inside any folder at all) are a special case, handled once at
/// the very start of every scan by `autoSortLooseFiles(imagesRoot:)`:
/// they're automatically moved into one fixed catch-all folder,
/// `looseFileCatchAllFolderName` ("Recently_Added" -> "Recently Added"
/// on screen), so a plain unsorted dump becomes a normal flat title
/// with zero manual folder-making -- no splitting by date or anything
/// else, everything just lands in that one folder together. This is
/// idempotent -- once a file's been moved there it's an ordinary file
/// in an ordinary folder from then on, indistinguishable from one you
/// put there by hand (including being safe to rename afterward).
///
/// A folder's display name (a title's name, or -- via its own season
/// subfolder's name -- that season's title-card caption) is its own
/// folder name with underscores turned into spaces; case is left exactly
/// as typed, so naming a folder however you want it to read on screen is
/// the only styling control needed (e.g. "Suma_24th_birthday" -> "Suma
/// 24th birthday"; name it "SUMA'S 24TH BIRTHDAY" instead for the old
/// all-caps look). An optional "<folder name>.info.json" can still
/// override the display title/blurb/tags/subtitle/year on top of this,
/// same as before -- matched by the folder's own raw name.
///
/// A season's ORDER (which becomes "Season 1"/"Season 2"/...) is
/// chronological, by that season's own earliest photo/video timestamp --
/// not alphabetical by folder name, since real folder names (e.g.
/// "Potsdam", "Winter_break_2024") don't sort into a meaningful order on
/// their own. The season TILE always shows just "Season N"; the season's
/// own folder name only ever shows up as that season's title-card
/// caption (see Season.titleCardCaption).
///
/// Any folder (a flat title, or one season of a show) with fewer than
/// `minimumItemsToQualify` total items (photos + short videos + long
/// videos combined) isn't playable yet -- but it still gets a tile, marked
/// "Coming Soon" (Album.isComingSoon / Season.isComingSoon), rather than
/// disappearing entirely. A flat title below the bar, including an
/// entirely empty placeholder folder with zero files, becomes a Coming
/// Soon Album tile on Browse. A show (a folder with subfolders) is judged
/// the same way at the SHOW level too: if NOT ONE of its seasons clears
/// the bar, the show itself is a Coming Soon Album (dimmed, not tappable
/// -- RootView guards on Album.isComingSoon before ever opening the
/// season list). Once at least one season DOES clear the bar, the show
/// becomes a normal, tappable tile instead.
///
/// Either way, `Album.seasons` is ALWAYS fully populated for a show --
/// one Season per subfolder, every one of them, whether or not the show
/// as a whole ended up Coming Soon -- never collapsed away into a single
/// flat entry. That's deliberate, not just for a fully-qualifying show:
/// BrowseView routes a title into the "Shows" row (portrait tile) purely
/// by checking whether `seasons` is non-empty (see BrowseView.showAlbums),
/// so a show whose only season is still empty/thin needs `seasons`
/// populated too, or it would misread as a flat "Titles" row entry
/// instead of a (dimmed, Coming Soon) Shows row entry. The ones that
/// individually clear the bar play normally; the ones that don't are
/// marked Coming Soon right there in the season list (dimmed, not
/// tappable) instead of being silently left out. Season order is
/// chronological by each season's own earliest timestamp (see below); a
/// Coming Soon season with too little content to have a meaningful
/// earliest timestamp (or none at all) simply sorts to the end. See
/// AlbumTile/SeasonTile/BrowseView for how a Coming Soon tile renders,
/// and RootView for where tapping one is a no-op instead of opening the
/// player/season list.
///
/// After every scan, the exact set of titles/seasons that qualified gets
/// written back out to `source_media/titles.json` -- NOT read as input
/// anywhere in this file, purely a human-readable record of what got
/// discovered this run. It's rewritten fresh on every launch, timed to
/// happen while the splash/hero screen is up (this whole scan already
/// runs during that window -- see RootView's Task.detached around
/// AlbumLoader.loadAlbums()).
///
/// --- Why this can be slow the first time, and how the cache avoids that ---
///
/// Reading a photo's EXIF timestamp or a video's creation date/duration
/// means actually opening that file, which adds up across a whole
/// library (thousands of files). To avoid redoing that on every single
/// launch, results are cached per "group" (a flat title, or one season of
/// a multi-season title) in a small JSON file under Application Support
/// (`MediaCache.cacheURL`, well outside `source_media` -- it's never
/// touched by anything else and can be deleted at any time with no harm,
/// just a slower next launch).
///
/// Every launch does a cheap pass first: for a group's folder(s), list
/// every file's relative path/size/modified-date (no file *contents* are
/// read for this) and combine them into one signature (a SHA-256 hash).
/// If that signature matches what's cached for this group, its cached
/// per-file timestamps/classifications are reused directly -- zero EXIF
/// or AVFoundation calls. If the signature differs (or nothing is cached
/// yet), only THAT group gets the real, slower scan, and its cache entry
/// is rebuilt. Adding one photo to one title only costs a rescan of that
/// title -- everything else stays instant. Cache keys are the group's own
/// folder path (e.g. "NYC/First_Time"), not its display label or season
/// number -- so a season's cache entry stays stable even if a later scan
/// re-numbers it (e.g. a new, earlier season gets added and everything
/// after it shifts from "Season 2" to "Season 3").
///
/// --- Where the time-buckets come from ---
///
/// Once every file in a group has a timestamp and a class (photo /
/// short-video / long-video), `computeBuckets(_:)` divides that group's
/// full timestamp range into 100 photo slices, 10 short-video slices, and
/// 5 long-video slices. This part is cheap pure arithmetic, so it's
/// always recomputed fresh from the (possibly cached) timestamps rather
/// than cached itself -- one less thing that could ever drift out of
/// sync.
enum MediaScanner {

    // MARK: - Discovery thresholds

    /// A folder (flat title, or one season) needs at least this many
    /// total items -- photos + short videos + long videos combined -- to
    /// be watchable. Anything thinner still gets a tile, marked "Coming
    /// Soon" rather than being hidden -- see this file's header for the
    /// full Coming Soon behavior. Lowered from 100 to 25 so a smaller,
    /// naturally-sized album (e.g. the auto-sorted "Recently Added"
    /// catch-all, see autoSortLooseFiles(imagesRoot:) below) has a
    /// realistic shot at qualifying instead of almost always landing on
    /// Coming Soon.
    static let minimumItemsToQualify = 25

    // MARK: - Media classification

    /// Which of the three curated-playback pools a file belongs in. Every
    /// photo file is always `.photo`, full stop, regardless of what any
    /// video on disk looks like -- see shortVideoMaxDuration below for
    /// how videos get split.
    enum MediaClass: String, Codable, Sendable {
        case photo
        case shortVideo
        case longVideo
    }

    /// A video this long or shorter belongs in the short-video pool (10
    /// slots, e.g. Live Photos); longer videos (or ones whose duration
    /// couldn't be read at all -- safer to over-classify as long) go in
    /// the long-video pool (5 slots).
    static let shortVideoMaxDuration: Double = 5.0

    static let numPhotoBuckets = 100
    static let numShortVideoBuckets = 10
    static let numLongVideoBuckets = 5

    private static let photoExtensions = AlbumLoader.photoExtensions
    private static let videoExtensions = AlbumLoader.videoExtensions

    // MARK: - Entry point

    /// Discovers every title/show under `sourceRoot/images/` and returns
    /// the full `[Album]` list, ready to display. This is a plain
    /// synchronous function -- it does real file I/O and can take real
    /// time on a cache miss, so callers (see AlbumLoader.loadAlbums())
    /// are expected to run it off the main thread (e.g. via
    /// `Task.detached`), not call it directly from a view body or
    /// onAppear.
    static func scanAlbums(sourceRoot: URL) -> [Album] {
        let fm = FileManager.default
        let imagesRoot = sourceRoot.appendingPathComponent("images", isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: imagesRoot.path, isDirectory: &isDir), isDir.boolValue else {
            print("MediaScanner: no images/ folder found at \(imagesRoot.path) -- no albums loaded.")
            return []
        }

        autoSortLooseFiles(imagesRoot: imagesRoot)

        guard let topLevelEntries = try? fm.contentsOfDirectory(
            at: imagesRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            print("MediaScanner: couldn't list \(imagesRoot.path) -- no albums loaded.")
            return []
        }

        var cache = MediaCache.load()
        var albums: [Album] = []
        var reusedGroups = 0
        var rescannedGroups = 0
        var comingSoonCount = 0
        // What actually gets written to titles.json at the end -- built
        // alongside each Album below, while the real season folder names
        // (which don't survive onto the Season model itself, only their
        // chronological "Season N" label does) are still at hand.
        var writtenTitles: [String: Any] = [:]

        let topFolders = topLevelEntries
            .filter { isVisibleDirectory($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        for folderURL in topFolders {
            let folderName = folderURL.lastPathComponent
            guard let children = try? fm.contentsOfDirectory(
                at: folderURL, includingPropertiesForKeys: [.isDirectoryKey]
            ) else {
                continue
            }
            let subfolders = children
                .filter { isVisibleDirectory($0) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            var seasons: [Season] = []
            var flatMedia: [MediaItem] = []
            var flatBuckets: MediaBucketGroup?
            var writtenSeasons: [String: Any] = [:] // only populated for a show
            // A folder that exists but doesn't clear minimumItemsToQualify
            // still gets an Album below -- just flagged Coming Soon rather
            // than hidden entirely, so a folder you've started organizing
            // (or even an empty placeholder folder) shows up as a tile
            // confirming it's there, not silently invisible. See Album's
            // own doc comment on `isComingSoon`.
            var isComingSoon = false

            if !subfolders.isEmpty {
                // SHOW: each subfolder is a candidate season. Loose files
                // sitting directly in `folderURL` itself are deliberately
                // ignored once there's at least one subfolder -- only
                // subfolders count as seasons.
                //
                // Every subfolder becomes a candidate regardless of
                // whether it clears minimumItemsToQualify -- `qualifies`
                // just tags which ones do, and `earliest` is nil for a
                // folder with zero files (nothing to time-sort by, so
                // those sort to the very end below rather than being
                // dropped).
                struct SeasonCandidate {
                    let folderName: String
                    let media: [MediaItem]
                    let buckets: MediaBucketGroup
                    let earliest: Date?
                    let qualifies: Bool
                }
                var candidates: [SeasonCandidate] = []

                for seasonURL in subfolders {
                    let seasonFolderName = seasonURL.lastPathComponent
                    let groupKey = "\(folderName)/\(seasonFolderName)"
                    let (files, wasCacheHit) = scanGroup(
                        groupKey: groupKey, folders: [seasonURL], sourceRoot: sourceRoot, cache: &cache
                    )
                    if wasCacheHit { reusedGroups += 1 } else { rescannedGroups += 1 }
                    let media = files
                        .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
                        .map { MediaItem(kind: $0.kind, url: $0.url, name: $0.url.lastPathComponent) }
                    candidates.append(SeasonCandidate(
                        folderName: seasonFolderName, media: media, buckets: computeBuckets(files),
                        earliest: files.map { $0.timestamp }.min(),
                        qualifies: files.count >= minimumItemsToQualify
                    ))
                }

                if !candidates.contains(where: { $0.qualifies }) {
                    // Not one season has enough content yet -- the show
                    // ITSELF is Coming Soon (dimmed, not tappable -- see
                    // RootView's guard), rather than vanishing entirely
                    // or opening into a season list with nothing playable
                    // in it. `seasons` still gets fully populated below
                    // regardless -- see this file's header for why: it's
                    // what tells BrowseView this is a Show, not a flat
                    // Title, even while every one of its seasons is
                    // itself Coming Soon.
                    comingSoonCount += 1
                    print("MediaScanner: COMING SOON -- \"\(folderName)\" -- no season had enough content yet")
                    isComingSoon = true
                }

                // Chronological, not alphabetical -- see this file's
                // header for why folder names alone can't be trusted to
                // sort into a meaningful season order. A candidate with
                // no files at all has no `earliest` to sort by --
                // .distantFuture pushes it to the end rather than
                // (arbitrarily) the very front, and Swift's sort() is
                // stable, so multiple such candidates keep `subfolders`'
                // own alphabetical order among themselves. Runs
                // unconditionally -- every subfolder gets a Season entry,
                // whether or not it (or the show as a whole) qualifies.
                candidates.sort { ($0.earliest ?? .distantFuture) < ($1.earliest ?? .distantFuture) }
                for (index, candidate) in candidates.enumerated() {
                    let label = "Season \(index + 1)"
                    let caption = prettify(candidate.folderName)
                    seasons.append(Season(
                        id: "\(folderName)-\(candidate.folderName)",
                        label: label,
                        media: candidate.media,
                        curationBuckets: candidate.buckets,
                        titleCardCaption: caption,
                        isComingSoon: !candidate.qualifies
                    ))
                    if candidate.qualifies {
                        writtenSeasons[label] = [
                            "images": relativeImagePaths(for: candidate.media, sourceRoot: sourceRoot),
                            "titleCard": caption
                        ]
                    } else {
                        writtenSeasons[label] = [
                            "comingSoon": true,
                            "images": relativeImagePaths(for: candidate.media, sourceRoot: sourceRoot),
                            "titleCard": caption
                        ]
                    }
                }
            } else {
                // Flat TITLE -- files directly inside, no subfolders (or
                // no files at all -- an empty placeholder folder is
                // treated the same as a too-thin one, both Coming Soon).
                let groupKey = "\(folderName)/\(AlbumLoader.allBucketsKey)"
                let (files, wasCacheHit) = scanGroup(
                    groupKey: groupKey, folders: [folderURL], sourceRoot: sourceRoot, cache: &cache
                )
                if wasCacheHit { reusedGroups += 1 } else { rescannedGroups += 1 }
                if files.count >= minimumItemsToQualify {
                    flatMedia = files
                        .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
                        .map { MediaItem(kind: $0.kind, url: $0.url, name: $0.url.lastPathComponent) }
                    flatBuckets = computeBuckets(files)
                } else {
                    comingSoonCount += 1
                    print("MediaScanner: COMING SOON -- \"\(folderName)\" -- only \(files.count) item(s), needs \(minimumItemsToQualify)")
                    isComingSoon = true
                    flatMedia = files.map { MediaItem(kind: $0.kind, url: $0.url, name: $0.url.lastPathComponent) }
                }
            }

            let info = loadInfo(title: folderName, sourceRoot: sourceRoot)
            let resolvedTitle: String
            if let infoTitle = info?.title, !infoTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                resolvedTitle = infoTitle
            } else {
                resolvedTitle = prettify(folderName)
            }
            let coverURL = findCompanion(title: folderName, kind: "cover", sourceRoot: sourceRoot)
            let songURL = findCompanion(title: folderName, kind: "song", sourceRoot: sourceRoot)
            let allMedia = seasons.isEmpty ? flatMedia : seasons.flatMap { $0.media }

            albums.append(Album(
                id: folderName,
                title: resolvedTitle,
                subtitle: info?.subtitle,
                year: info?.year,
                tags: info?.tags ?? [],
                blurb: info?.blurb ?? info?.description,
                coverURL: coverURL,
                songURL: songURL,
                media: allMedia,
                seasons: seasons,
                curationBuckets: seasons.isEmpty ? flatBuckets : nil,
                isComingSoon: isComingSoon
            ))

            if seasons.isEmpty {
                // Flat title -- Coming Soon or not, there's only ever one
                // flat image list to report.
                writtenTitles[folderName] = isComingSoon
                    ? [
                        "comingSoon": true,
                        "images": relativeImagePaths(for: flatMedia, sourceRoot: sourceRoot)
                      ]
                    : relativeImagePaths(for: flatMedia, sourceRoot: sourceRoot)
            } else {
                // Show -- `writtenSeasons` already carries each season's
                // own qualify/Coming-Soon state (see the per-candidate
                // "comingSoon" key above), so it's the whole picture on
                // its own even when the show as a whole is also Coming
                // Soon (every season in it will be too, in that case).
                writtenTitles[folderName] = writtenSeasons
            }
        }

        cache.save()
        writeTitlesJSON(writtenTitles, sourceRoot: sourceRoot)
        print("MediaScanner: \(albums.count) title(s) loaded -- \(reusedGroups) group(s) reused from cache, \(rescannedGroups) group(s) rescanned from disk, \(comingSoonCount) marked Coming Soon for too little content.")
        return albums.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    // MARK: - Auto-sorting a flat dump into one catch-all folder

    /// The one fixed folder every loose top-level file gets moved into --
    /// prettifies on screen to "Recently Added" (see `prettify(_:)`), same
    /// underscore convention as every other folder name.
    private static let looseFileCatchAllFolderName = "Recently_Added"

    /// Photo/video files sitting directly at the top level of `images/`
    /// (not inside any subfolder) don't count as a title on their own --
    /// only subfolders do (see this file's header). Rather than
    /// requiring a folder to be made by hand first, this runs at the
    /// very start of every scan, before `topFolders` is even listed, and
    /// moves any such loose files straight into one fixed catch-all
    /// folder, `looseFileCatchAllFolderName` -- so a plain dump of files
    /// becomes a normal, playable title on this very same launch, no
    /// separate script or manual step required. Deliberately NOT split
    /// up by date or anything else -- every loose file lands in that
    /// same one folder together; if you want a different organization
    /// (by trip, by person, whatever), just make those folders yourself
    /// and drop files in directly instead of leaving them loose.
    ///
    /// Idempotent and safe on every launch: once a file has been moved
    /// into `looseFileCatchAllFolderName` it's an ordinary file in an
    /// ordinary folder from then on, so later scans leave it alone --
    /// only files still sitting loose right now ever get touched.
    /// Renaming that folder afterward (or moving its contents elsewhere)
    /// is completely safe too -- this function only ever looks at what's
    /// loose directly in `images/`, never at the folder's own name.
    private static func autoSortLooseFiles(imagesRoot: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: imagesRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return
        }

        let looseFiles = entries.filter { url in
            guard !url.lastPathComponent.hasPrefix(".") else { return false }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true else { return false }
            let ext = url.pathExtension.lowercased()
            return photoExtensions.contains(ext) || videoExtensions.contains(ext)
        }
        guard !looseFiles.isEmpty else { return }

        let targetDir = imagesRoot.appendingPathComponent(looseFileCatchAllFolderName, isDirectory: true)
        if !fm.fileExists(atPath: targetDir.path) {
            try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        }

        var movedCount = 0
        for url in looseFiles {
            do {
                try fm.moveItem(at: url, to: targetDir.appendingPathComponent(url.lastPathComponent))
                movedCount += 1
            } catch {
                print("MediaScanner: couldn't auto-sort \(url.lastPathComponent) -- \(error.localizedDescription)")
            }
        }
        if movedCount > 0 {
            print("MediaScanner: auto-sorted \(movedCount) loose file(s) in images/ into \(looseFileCatchAllFolderName)/.")
        }
    }

    /// A non-hidden (not dot-prefixed) directory -- the shared filter
    /// behind both the images/ top level and each show's subfolder list.
    private static func isVisibleDirectory(_ url: URL) -> Bool {
        guard !url.lastPathComponent.hasPrefix(".") else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// Turns a folder name into a display string -- underscores become
    /// spaces, everything else (including case) is left exactly as
    /// typed, so naming the folder is the only styling control needed
    /// (e.g. name it "SUMA'S 24TH BIRTHDAY" for the app's usual all-caps
    /// look, or "Suma's 24th Birthday" for title case -- both just get
    /// used verbatim).
    private static func prettify(_ folderName: String) -> String {
        folderName.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Every one of `media`'s files, as a path relative to `sourceRoot`
    /// (e.g. "images/ALBANY/IMG_0001.jpg") -- purely for titles.json's
    /// generated output below, so each title/season entry lists the
    /// actual individual images that qualified for it, not just the
    /// folder they happened to come from.
    private static func relativeImagePaths(for media: [MediaItem], sourceRoot: URL) -> [String] {
        let sourcePrefix = sourceRoot.path.hasSuffix("/") ? sourceRoot.path : sourceRoot.path + "/"
        return media
            .map { $0.url.path.hasPrefix(sourcePrefix) ? String($0.url.path.dropFirst(sourcePrefix.count)) : $0.url.path }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Writes the discovered title/season structure back out to
    /// `source_media/titles.json` -- each title (or, for a show, each
    /// season) as a key, with the actual list of individual image/video
    /// files that qualified for it as the value (via
    /// relativeImagePaths(for:sourceRoot:) above), not just the folder
    /// path they live in. Still purely an inspectable record of this
    /// run's discovery -- what file ended up counted toward which
    /// title/tag, and whether it cleared the minimum-items bar or came up
    /// Coming Soon -- never read back in by this file; the folder
    /// structure under `images/` remains the one and only source of
    /// truth for what a file's title/tag actually is. Failure here (e.g.
    /// a read-only volume) is silent and non-fatal -- it never blocks
    /// albums from loading, since the in-memory `albums` this function
    /// built are already complete by the time this is called.
    private static func writeTitlesJSON(_ titles: [String: Any], sourceRoot: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: titles, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: sourceRoot.appendingPathComponent("titles.json"), options: .atomic)
    }

    // MARK: - Companion files (info.json / cover / song)

    private static func loadInfo(title: String, sourceRoot: URL) -> AlbumInfo? {
        let url = sourceRoot.appendingPathComponent("\(title).info.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AlbumInfo.self, from: data)
    }

    private static func findCompanion(title: String, kind: String, sourceRoot: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: sourceRoot, includingPropertiesForKeys: nil) else {
            return nil
        }
        let prefix = "\(title).\(kind)."
        return entries.first { $0.lastPathComponent.hasPrefix(prefix) }
    }

    // MARK: - One scanned file

    private struct ScannedFile {
        let relativePath: String // relative to sourceRoot -- unique across the whole library, used as the cache key
        let url: URL
        let kind: MediaItem.Kind
        let timestamp: Date // "naive wall-clock" Date -- see naiveDate(...) below
        let mediaClass: MediaClass
    }

    /// A file's cheap, no-file-contents-read listing info -- everything
    /// needed to build a signature and look this file up in the cache.
    private struct QuickListing {
        let relativePath: String
        let url: URL
        let ext: String
        let size: Int
        let mtime: Double
    }

    private static func quickList(folder: URL, sourceRoot: URL) -> [QuickListing] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        ) else {
            return []
        }
        var out: [QuickListing] = []
        let sourcePrefix = sourceRoot.path.hasSuffix("/") ? sourceRoot.path : sourceRoot.path + "/"
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else {
                continue
            }
            guard !name.hasPrefix(".") else { continue }
            if values.isDirectory == true { continue }
            let ext = url.pathExtension.lowercased()
            guard photoExtensions.contains(ext) || videoExtensions.contains(ext) else { continue }
            let size = values.fileSize ?? 0
            let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            let relPath = url.path.hasPrefix(sourcePrefix) ? String(url.path.dropFirst(sourcePrefix.count)) : url.path
            out.append(QuickListing(relativePath: relPath, url: url, ext: ext, size: size, mtime: mtime))
        }
        return out
    }

    /// Combines every file's (path, size, modified-date) into one stable
    /// SHA-256 signature -- if this matches what's cached for a group,
    /// nothing in that group has changed since last time.
    private static func computeSignature(for listing: [QuickListing]) -> String {
        let sorted = listing.sorted { $0.relativePath < $1.relativePath }
        let combined = sorted.map { "\($0.relativePath)|\($0.size)|\($0.mtime)" }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(combined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Scans one group (a flat title, or one season) across one or more
    /// folders. Returns the resolved files plus whether this was served
    /// straight from cache (no metadata reads at all) or freshly scanned.
    private static func scanGroup(
        groupKey: String,
        folders: [URL],
        sourceRoot: URL,
        cache: inout MediaCache
    ) -> (files: [ScannedFile], wasCacheHit: Bool) {
        var listing: [QuickListing] = []
        for folder in folders {
            listing.append(contentsOf: quickList(folder: folder, sourceRoot: sourceRoot))
        }
        guard !listing.isEmpty else { return ([], true) }

        let signature = computeSignature(for: listing)
        let cachedGroup = cache.groups[groupKey]

        if let cachedGroup, cachedGroup.signature == signature {
            // Nothing changed -- reuse every cached timestamp/class
            // directly, no EXIF/AVFoundation reads at all.
            let files: [ScannedFile] = listing.compactMap { item in
                guard let cachedFile = cachedGroup.files[item.relativePath] else { return nil }
                let kind: MediaItem.Kind = photoExtensions.contains(item.ext) ? .photo : .video
                return ScannedFile(
                    relativePath: item.relativePath, url: item.url, kind: kind,
                    timestamp: cachedFile.timestamp, mediaClass: cachedFile.mediaClass
                )
            }
            return (files, true)
        }

        // Signature changed (or nothing cached yet) -- do the real,
        // slower scan for this group's files, and rebuild its cache
        // entry from scratch.
        var newCachedFiles: [String: MediaCache.FileEntry] = [:]
        var results: [ScannedFile] = []
        for item in listing {
            let (timestamp, mediaClass, kind) = extract(item: item)
            newCachedFiles[item.relativePath] = MediaCache.FileEntry(timestamp: timestamp, mediaClass: mediaClass)
            results.append(ScannedFile(relativePath: item.relativePath, url: item.url, kind: kind, timestamp: timestamp, mediaClass: mediaClass))
        }
        cache.groups[groupKey] = MediaCache.GroupEntry(signature: signature, files: newCachedFiles)
        return (results, false)
    }

    private static func extract(item: QuickListing) -> (timestamp: Date, mediaClass: MediaClass, kind: MediaItem.Kind) {
        if photoExtensions.contains(item.ext) {
            let ts = photoTimestamp(url: item.url) ?? fallbackTimestamp(item: item)
            return (ts, .photo, .photo)
        } else {
            let (videoTimestamp, duration) = videoInfo(url: item.url)
            let ts = videoTimestamp ?? fallbackTimestamp(item: item)
            let mediaClass: MediaClass
            if let duration, duration <= shortVideoMaxDuration {
                mediaClass = .shortVideo
            } else {
                mediaClass = .longVideo // includes "duration unknown" -- safer to over-classify as long
            }
            return (ts, mediaClass, .video)
        }
    }

    /// No readable capture-time metadata -- falls back to the file's
    /// on-disk modified time, converted the same "naive Eastern wall
    /// clock" way as everything else so it stays comparable.
    private static func fallbackTimestamp(item: QuickListing) -> Date {
        let realDate = Date(timeIntervalSince1970: item.mtime)
        return toNaiveEastern(realDate) ?? realDate
    }

    // MARK: - Naive wall-clock time handling

    private static let easternTZ = TimeZone(identifier: "America/New_York")!

    /// A Calendar used purely to build/read "naive wall-clock" Dates --
    /// ones that store year/month/day/hour/minute/second values directly
    /// with NO real timezone meaning attached. EXIF timestamps carry no
    /// timezone info at all (they're effectively "whatever the camera's
    /// clock said"), so this whole pipeline treats every timestamp as a
    /// bare set of wall-clock numbers rather than a real instant in time
    /// -- using UTC here is arbitrary, it's a fixed, DST-free calendar
    /// used purely to store/compare those numbers consistently, never
    /// treated as an actual UTC moment anywhere.
    private static var naiveCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private static func naiveDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Date? {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        return naiveCalendar.date(from: comps)
    }

    /// Converts a real, absolute Date into a "naive" Date holding its
    /// Eastern-time wall-clock numbers (see naiveDate above) -- used for
    /// video creation dates and file-modified-dates (which ARE real,
    /// absolute instants, unlike EXIF's timezone-less strings) so
    /// everything lands on the same comparable footing. Every location in
    /// this library (NYC, Philly, Albany, Niagara, Atlantic City,
    /// Potsdam) is US Eastern, so this is hardcoded rather than read from
    /// the system.
    private static func toNaiveEastern(_ date: Date) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = easternTZ
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let y = c.year, let mo = c.month, let d = c.day, let h = c.hour, let mi = c.minute, let s = c.second else {
            return nil
        }
        return naiveDate(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
    }

    // MARK: - Photo EXIF

    /// Reads a photo's EXIF DateTimeOriginal (falling back to
    /// DateTimeDigitized, then the TIFF-level DateTime) -- DateTimeOriginal
    /// specifically is the reliable "when the shutter actually clicked"
    /// field; DateTime alone can reflect a later edit/re-save instead.
    private static func photoTimestamp(url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let raw = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        guard let raw else { return nil }
        return parseExifWallClock(raw)
    }

    /// Parses EXIF's "yyyy:MM:dd HH:mm:ss" format into naive wall-clock
    /// components -- no timezone interpretation, matching how EXIF
    /// itself carries none.
    private static func parseExifWallClock(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: " ")
        guard pieces.count == 2 else { return nil }
        let dateParts = pieces[0].split(separator: ":").compactMap { Int($0) }
        let timeParts = pieces[1].split(separator: ":").compactMap { Int($0) }
        guard dateParts.count == 3, timeParts.count == 3 else { return nil }
        return naiveDate(
            year: dateParts[0], month: dateParts[1], day: dateParts[2],
            hour: timeParts[0], minute: timeParts[1], second: timeParts[2]
        )
    }

    // MARK: - Video metadata

    /// Reads a video's creation date (converted to naive-Eastern, see
    /// toNaiveEastern above) and duration in seconds. Deliberately uses
    /// AVFoundation's traditional synchronous properties rather than the
    /// newer async `load(_:)` API, so the whole scan stays simple,
    /// single-threaded Swift with nothing to reason about concurrency-
    /// wise -- Xcode may show a mild deprecation warning on these
    /// properties, which is fine to leave as a possible future cleanup,
    /// not a correctness issue.
    private static func videoInfo(url: URL) -> (timestamp: Date?, duration: Double?) {
        let asset = AVURLAsset(url: url)

        var duration: Double? = nil
        let cmDuration = asset.duration
        if cmDuration.isValid, !cmDuration.isIndefinite {
            let seconds = CMTimeGetSeconds(cmDuration)
            if seconds.isFinite, seconds > 0 {
                duration = seconds
            }
        }

        var timestamp: Date? = nil
        let creationItems = AVMetadataItem.metadataItems(
            from: asset.commonMetadata,
            withKey: AVMetadataKey.commonKeyCreationDate,
            keySpace: .common
        )
        if let raw = creationItems.first {
            if let dateValue = raw.dateValue {
                timestamp = toNaiveEastern(dateValue)
            } else if let stringValue = raw.stringValue {
                // Some files store creation date as an ISO-8601 string
                // instead of a native date value.
                let isoFormatter = ISO8601DateFormatter()
                if let parsed = isoFormatter.date(from: stringValue) {
                    timestamp = toNaiveEastern(parsed)
                }
            }
        }

        return (timestamp, duration)
    }

    // MARK: - Bucket computation

    /// Divides one group's files into 100 photo / 10 short-video / 5
    /// long-video time-slices spanning that group's own full timestamp
    /// range (computed from every file across all three classes, so every
    /// pool's slices line up against the same timeline).
    private static func computeBuckets(_ files: [ScannedFile]) -> MediaBucketGroup {
        guard !files.isEmpty,
              let tMin = files.map({ $0.timestamp }).min(),
              let tMax = files.map({ $0.timestamp }).max() else {
            return MediaBucketGroup()
        }
        let span = tMax.timeIntervalSince(tMin)

        func bucketIndex(_ ts: Date, count: Int) -> Int {
            guard span > 0 else { return 0 }
            let frac = ts.timeIntervalSince(tMin) / span
            return min(max(Int(frac * Double(count)), 0), count - 1)
        }

        var photoBuckets = Array(repeating: [MediaItem](), count: numPhotoBuckets)
        var shortVideoBuckets = Array(repeating: [MediaItem](), count: numShortVideoBuckets)
        var longVideoBuckets = Array(repeating: [MediaItem](), count: numLongVideoBuckets)

        for file in files {
            let item = MediaItem(kind: file.kind, url: file.url, name: file.url.lastPathComponent)
            switch file.mediaClass {
            case .photo:
                photoBuckets[bucketIndex(file.timestamp, count: numPhotoBuckets)].append(item)
            case .shortVideo:
                shortVideoBuckets[bucketIndex(file.timestamp, count: numShortVideoBuckets)].append(item)
            case .longVideo:
                longVideoBuckets[bucketIndex(file.timestamp, count: numLongVideoBuckets)].append(item)
            }
        }

        return MediaBucketGroup(photoBuckets: photoBuckets, shortVideoBuckets: shortVideoBuckets, longVideoBuckets: longVideoBuckets)
    }
}

/// The on-disk cache MediaScanner reads/writes -- see MediaScanner's
/// header for the full picture of why this exists and how it's kept
/// correct. Lives in Application Support, never inside source_media;
/// deleting it just costs a slower next launch, never any lost data
/// (source_media itself is always the single source of truth).
private struct MediaCache: Codable {
    struct FileEntry: Codable {
        let timestamp: Date
        let mediaClass: MediaScanner.MediaClass
    }
    struct GroupEntry: Codable {
        var signature: String
        var files: [String: FileEntry] // relativePath -> entry
    }

    var groups: [String: GroupEntry] = [:] // "folderName/seasonFolderNameOrAllBucketsKey" -> group

    static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("OurFlix", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("media_cache.json")
    }

    static func load() -> MediaCache {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(MediaCache.self, from: data) else {
            return MediaCache()
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }
}
