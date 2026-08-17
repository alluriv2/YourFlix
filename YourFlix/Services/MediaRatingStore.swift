import Foundation

/// A photo/video's like/dislike state -- see MediaRatingStore below for
/// how it's persisted, AlbumLoader.curatedPlaylist(...) for how a dislike
/// actually keeps a file out of future watches, and
/// AlbumLoader.posterCandidates(media:) for how a like curates that
/// title/season's own thumbnail pool.
enum MediaRating: String, Codable, Sendable {
    case liked
    case disliked
}

/// Persists every photo/video's like/dislike rating across launches,
/// keyed by each file's own full path (stable for as long as
/// source_media itself doesn't move) -- a rating belongs to one specific
/// FILE, not to whichever title/season MediaScanner happens to group it
/// under this run, so renaming/reorganizing folders never loses ratings.
/// Lives in Application Support, same as MediaCache (see
/// MediaScanner.swift) -- well outside source_media itself, so ratings
/// survive a source_media re-migration/rename without being lost or
/// getting swept up in a copy of the media library.
///
/// A DISLIKE is what changes PLAYBACK -- see AlbumLoader.curatedPlaylist(...),
/// which drops every disliked file from consideration before picking a
/// watch's photos/videos, every single time from then on (permanent
/// until you tap dislike again to clear it, not just skipped for the
/// rest of THIS watch).
///
/// A LIKE is what changes THUMBNAILS -- see
/// AlbumLoader.posterCandidates(media:), which prefers liked photos when
/// picking which random photo represents a title/season's tile/hero
/// poster, falling back to the whole title/season only when it has no
/// liked photos yet. This is the replacement for the old feature_image/
/// drop-in-folder mechanism: liking a good photo during a normal watch
/// curates that title/season's own thumbnail pool right there, with no
/// separate folder and no copying the same image a second time. A like
/// does NOT currently bias which photos get picked for the SLIDESHOW
/// itself -- no "show liked photos more often" weighting exists there,
/// only for thumbnails.
///
/// Thread-safety mirrors AlbumLoader's `pickedSource`/`posterCache`
/// pattern (a plain NSLock, not @MainActor) since this is read from
/// AlbumLoader.curatedPlaylist(...), a plain static function with no
/// actor isolation of its own, as well as written from
/// PlayerViewModel (@MainActor) when a button's tapped.
final class MediaRatingStore {
    static let shared = MediaRatingStore()

    private var ratings: [String: MediaRating]
    private let lock = NSLock()

    private static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("OurFlix", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("media_ratings.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.storeURL),
           let decoded = try? JSONDecoder().decode([String: MediaRating].self, from: data) {
            ratings = decoded
        } else {
            ratings = [:]
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(ratings) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }

    /// This file's current rating, if it has one -- nil means neutral
    /// (never rated, or a rating that got cleared by tapping it again).
    func rating(for url: URL) -> MediaRating? {
        lock.lock()
        defer { lock.unlock() }
        return ratings[url.path]
    }

    /// Tapping the same rating a file already has clears it back to
    /// neutral (a toggle, not a one-way switch); tapping the OTHER
    /// rating switches straight over from like to dislike or vice versa.
    /// Returns the new state (nil if just cleared) so the caller can
    /// update its own UI without a second lookup.
    @discardableResult
    func toggle(_ rating: MediaRating, for url: URL) -> MediaRating? {
        lock.lock()
        let key = url.path
        let newValue: MediaRating?
        if ratings[key] == rating {
            ratings.removeValue(forKey: key)
            newValue = nil
        } else {
            ratings[key] = rating
            newValue = rating
        }
        lock.unlock()
        save()
        return newValue
    }

    /// Every disliked file's path -- consulted by
    /// AlbumLoader.curatedPlaylist(...) to exclude them from every future
    /// watch's selection.
    var dislikedPaths: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(ratings.filter { $0.value == .disliked }.keys)
    }

    /// Every liked file's path -- consulted by
    /// AlbumLoader.posterCandidates(media:) as a title/season's curated
    /// thumbnail pool: liking a photo during a normal watch is what
    /// curates which photos that title/season's poster gets picked from
    /// going forward, replacing the old feature_image/ drop-in-folder
    /// mechanism (no more copying a photo into a separate folder just to
    /// mark it as a good thumbnail candidate -- liking it in place does
    /// the same job).
    var likedPaths: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(ratings.filter { $0.value == .liked }.keys)
    }
}
