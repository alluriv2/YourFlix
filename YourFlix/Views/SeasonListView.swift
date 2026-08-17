import AppKit
import SwiftUI

/// The "show page" for a multi-season title -- title header plus a tile
/// per season. Tapping a season continues forward (currently to
/// ComingSoonView, until the real content pipeline ships and seasons play
/// for real).
struct SeasonListView: View {
    let album: Album
    let onSelectSeason: (Season) -> Void
    let onBack: () -> Void

    // Backup Esc handling -- see keyMonitor's onAppear below for why
    // .onExitCommand alone isn't trusted to be enough here.
    @State private var keyMonitor: Any?

    var body: some View {
        // header lives OUTSIDE the ScrollView -- same fix already applied
        // to BrowseView's logo, for the same class of problem: content
        // pinned right at a ScrollView's top edge (rather than a fixed
        // section above it) can lose clicks to the scroll view's own
        // gesture recognizer, which is exactly what was happening to the
        // "← Back" button when it lived inside the ScrollView below.
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("\(album.seasons.count) Season\(album.seasons.count == 1 ? "" : "s")")
                        .font(.subheadline.bold())
                        .foregroundColor(Theme.textDim)
                        .padding(.horizontal, 40)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                        ForEach(album.seasons) { season in
                            SeasonTile(album: album, season: season) {
                                onSelectSeason(season)
                            }
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 60)
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.background.ignoresSafeArea())
        .onExitCommand { onBack() }
        .onAppear {
            // .onExitCommand only fires if SwiftUI's focus system considers
            // this view (or a subview) first responder, which isn't
            // guaranteed on a screen with no naturally-focusable control --
            // same class of unreliability PlayerView already works around
            // with its own local NSEvent monitor. This is a pure backup:
            // if .onExitCommand already handled Esc, onBack() just runs
            // twice, and setting selectedShowForSeasons back to the same
            // nil it's already been set to is a harmless no-op.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
                if event.keyCode == 53 { // Esc
                    onBack()
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 20) {
            Button(action: onBack) {
                Text("← Back")
                    .font(.callout.bold())
            }
            .buttonStyle(.plain)
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            // .buttonStyle(.plain) + a background-only pill doesn't
            // reliably make the WHOLE pill tappable on its own -- without
            // this, the hit-test area can shrink to roughly just the "←
            // Back" text glyphs, so clicks nearer the pill's edges/padding
            // silently miss. This pins the tappable area to the full
            // rounded-rect shape drawn above.
            .contentShape(RoundedRectangle(cornerRadius: 4))

            Text(album.title)
                .font(.largeTitle.bold())
                .foregroundColor(.white)

            Spacer()
        }
        .padding(.horizontal, 40)
        // 52, not 40: 40 turned out to still leave the button's top
        // portion inside macOS's hidden-titlebar drag/traffic-light strip
        // (see `.windowStyle(.hiddenTitleBar)` in YourFlixApp.swift) on at
        // least some window/display configurations -- clicks landing in
        // that strip get eaten by the window chrome before they ever
        // reach this Button. 52 gives a more generous, unambiguous margin
        // below that strip. Matches BrowseView.logoHeader's clearance
        // logic, just tuned further after 40 proved insufficient in
        // practice.
        .padding(.top, 52)
        .padding(.bottom, 14)
    }
}

/// One season's poster tile. Mirrors AlbumTile's structure (see that
/// file's header comments for the full rationale) since it hits the exact
/// same two pitfalls: a GeometryReader wrapper is required to force every
/// tile in the row to the same uniform size (otherwise each photo's own
/// aspect ratio leaks into the ZStack's layout, same as the Titles/Shows
/// row bug did), and every child that should fill the tile needs an
/// explicit `.frame(width:height:)` rather than relying on its own
/// intrinsic size. The image itself comes from
/// AlbumLoader.seasonThumbnail(for:) -- a properly downsampled, correctly
/// oriented ImageIO thumbnail keyed by the season's own id, so NYC's three
/// seasons each get their own independently-picked photo rather than all
/// three sharing NYC's own album-level pick.
///
/// A Coming Soon season (Season.isComingSoon -- a season subfolder that
/// exists but doesn't have enough content yet, see MediaScanner.swift's
/// header) renders here exactly like a Coming Soon AlbumTile does: dimmed
/// with a small red "COMING SOON" pill, still tappable-looking (no
/// `.disabled`) but the actual tap is a no-op -- see RootView's
/// onSelectSeason closure, which checks `isComingSoon` before ever
/// building a playable Album out of it.
private struct SeasonTile: View {
    let album: Album
    let season: Season
    let onTap: () -> Void

    @State private var hovering = false
    // Same purpose as AlbumTile's refreshTick: bumped by the hover refresh
    // button to force `thumbnail` to be re-read after
    // AlbumLoader.refreshPoster(for:) re-picks/clears the cache.
    @State private var refreshTick = 0

    private var thumbnail: NSImage? {
        AlbumLoader.seasonThumbnail(for: season)
    }

    var body: some View {
        Button(action: onTap) {
            GeometryReader { geo in
                ZStack {
                    Theme.posterGradient

                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .id(refreshTick)

                        // A real photo needs a scrim behind the centered
                        // text to stay legible -- Theme.posterGradient
                        // alone (a plain color gradient) never needed one
                        // since there was no image under it before.
                        Color.black.opacity(0.35)
                    }

                    // Just the season label ("SEASON 1") -- no show-name
                    // caption above it. The show's own name is already the
                    // page header just above this grid (see `header`
                    // below), so repeating it on every tile was redundant;
                    // per-tile text now matches what titles.json actually
                    // calls each season, nothing more.
                    Text(season.label)
                        .font(.title3.bold())
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .shadow(color: .black.opacity(0.7), radius: 4)

                    if season.isComingSoon {
                        // Same uniform dim + pill treatment as
                        // AlbumTile's own Coming Soon state -- reads at a
                        // glance as "not ready yet" even before spotting
                        // the pill.
                        Color.black.opacity(0.4)

                        Text("COMING SOON")
                            .font(.system(size: 11, weight: .heavy))
                            .tracking(1.4)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Theme.red)
                            .clipShape(Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 12)
                    }

                    if hovering && !season.isComingSoon {
                        Button {
                            AlbumLoader.refreshPoster(for: season)
                            refreshTick += 1
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .padding(6)
                                .background(Circle().fill(Color.black.opacity(0.6)))
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.opacity)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .scaleEffect(hovering ? 1.05 : 1.0)
            .shadow(color: .black.opacity(hovering ? 0.5 : 0), radius: 12)
            .animation(.easeOut(duration: 0.2), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
