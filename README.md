# YourFlix
**Your moments, now streaming.**
Turn your photos and home videos into your own personal streaming service.
YourFlix transforms ordinary folders into a cinematic library with a hero banner, poster rows, title cards, shuffled playback, and music. There’s no catalog to build and nothing to organize inside the app—just add your media and start watching.
**Available now for macOS.**
## Get started
1. Download YourFlix.
2. Add your photos and videos to `source_media/images/`, using one folder for each title.
3. Open `YourFlix.app`.
That’s it. YourFlix automatically finds the media folder beside the app and builds your library.
Because the app is currently unsigned, macOS may block it the first time. Control-click `YourFlix.app`, choose **Open**, and confirm. After that, it opens normally.
If you've done that and YourFlix still isn't finding your music or your library, open Terminal and run `xattr -cr /path/to/YourFlix.app` (drag the app into the Terminal window to fill in the path). This clears a quarantine flag that can survive even after approving the app once, and it's the fix if things still aren't showing up.
## Your folders become your library
Create a folder for each collection you want to see in YourFlix:
```text
source_media/
└── images/
    ├── Beach Trips/
    ├── Family Memories/
    ├── Graduation/
    └── Our Wedding/
```
The folder name becomes the title shown on screen.
If a title contains subfolders, YourFlix treats them as seasons:
```text
Beach Trips/
├── 2024/
└── 2025/
```
Have a loose pile of photos with no folders? Drop them directly into `images/`. YourFlix gathers them into a title called **Recently Added** when it scans your library.
For every folder and season, aim for at least 25 photos or videos. Smaller collections still appear in your library, labeled **Coming Soon**, until they’re ready to watch.
## Every playback is different
Each time you press play, YourFlix creates a fresh mix of your photos and videos with a randomly selected music track underneath.
Videos and photos are naturally interleaved, and videos never play back-to-back.
## Make it yours
Use **Like** and **Dislike** while watching:
- Liked moments help shape the artwork used for that title.
- Disliked moments are left out of future playback.
- You can undo either choice later.
Want more control over how a title appears? You can optionally add a custom description or cover image. See [`source_media/README.md`](source_media/README.md) for the naming conventions.
## Current version
YourFlix currently runs as a local, single-user macOS app:
- No account or sign-in
- No cloud library
- No uploading your photos or videos
- One shared library on your Mac
## Compatibility
YourFlix is currently available for macOS. Windows, web, phone, and TV versions are not yet available.
## What’s next
- A web app for access on Windows, phones, and TV browsers
- Personal accounts with login and sign-up
- Direct links to albums from Apple Photos and Google Photos
- Multiple password-protected profiles, each with its own selection of albums
## License
The YourFlix app code is available under the MIT License. Included music has its own licensing terms, and anything you add to your personal library remains yours. See [`LICENSE`](LICENSE) for details.
