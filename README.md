<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Assets/wianu-logo.svg">
    <img src="Assets/wianu-logo-dark.svg" width="120" alt="Wianu app icon">
  </picture>
</p>

<div align="center">

![Wianu](Assets/wianu-light-mode.svg#gh-light-mode-only)
![Wianu](Assets/wianu-dark-mode.svg#gh-dark-mode-only)

</div>

<p align="center">
  All your streaming. One home.
</p>

<img src="Assets/showcase.png">

Wianu is a lightweight browser for organizing streaming websites, shows, and
movies in one place. Add the services you use, search across them, keep links
to shows you are watching, and maintain a watchlist without switching between
browser tabs.

## About this fork

This is a personal fork of [timwehrle/wianu](https://github.com/timwehrle/wianu)
(GPL-3.0). It adds:

- **Profiles** — a Kids profile with its own sites, watchlist, website sign-ins
  and Jellyfin account (⌃⌘1 / ⌃⌘2 on the Mac).
- **Jellyfin** — browse and play your own library, with resume progress synced
  to the server. Needs Jellyfin 10.9 or later.
- **Service setup and filtering** — pick your services from TMDB's list for your
  region; search can show only titles included with them.
- **iCloud sync** — each profile's watchlist, streaming services and Jellyfin
  server stay the same on the Mac, iPhone, iPad and Apple TV. Jellyfin sign-ins
  stay on each device; the Apple TV can sign in with a code approved from
  another device (Jellyfin Quick Connect).
- **Title and episode links** — services open on the title or episode rather
  than a search, using Wikidata and, with a key, Streaming Availability. Stream
  remembers the last episode you opened for each show.
- **Release days** — when a show's next episode comes out, from Trakt.
- **Stream Mobile** — an iPhone, iPad and Apple TV app: Jellyfin playback, the
  watchlist, search, and where to watch, opening each service's app.

### Setting up a build

1. In Xcode, choose your team under Signing & Capabilities for the **Wianu**
   and **Stream Mobile** targets.
2. For iCloud sync, add the iCloud capability with CloudKit to both targets,
   using one container (for example `iCloud.com.lukeschenk.stream`). The Mac app
   detects it automatically. For Stream Mobile, also put the container ID in
   `StreamCloudKitContainer` in `Mobile/Info.plist`.
3. Optional: copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig`
   (which git ignores) and add a Streaming Availability key for episode links
   and a Trakt Client ID for release days.
4. Run the **Wianu** scheme for the Mac or **Stream Mobile** for iPhone, iPad
   and Apple TV.

Automatic updates and usage analytics are switched off in this fork so it never
installs upstream builds or reports to the upstream analytics server.

## Features

- Add and organize streaming websites in a sidebar.
- Search supported sites from one search screen.
- Search for watchlist movies on any configured site from their context menu.
- Save show pages under **Continue Watching**.
- Add movies to a built-in watchlist.
- Import a watchlist exported from Letterboxd as CSV.
- Navigate backward and forward through the current browsing session.
- Open streaming sites directly inside the app.
- Open movie search results on Letterboxd for rating.

## Continue Watching

Wianu's Continue Watching list saves a link; it does not track playback
progress itself.

For the best cross-device experience, add a show from its **show or series
detail page**, not from an individual episode or video player. When you open
the saved item later, use the streaming service's own Continue or Resume
button. The service can then select the latest episode using the progress
synced to your account.

If you save an episode or player page, Wianu will reopen that exact episode.
Progress made on another device cannot change the saved link.

### Example

1. Open the detail page for _How I Met Your Mother_.
2. Select the Continue Watching button in Wianu's toolbar.
3. Watch on any device signed in to the same streaming account.
4. Open the show from Wianu and select the provider's Continue or Resume
   button.

> Wianu is not affiliated with streaming providers and cannot read their
> private viewing history. Playback synchronization is handled by each
> provider.

## Getting started

1. Launch Wianu.
2. Select **Add Site** in the sidebar.
3. Enter a name and the website URL.
4. Optionally enter a search URL containing `{query}`, for example
   `https://example.com/search?q={query}`.
5. Sign in to the streaming website and use it as you would in a browser.

Some known sites receive a suggested search URL automatically. For other
sites, you can add a compatible search URL yourself.

## Anonymous usage analytics

Wianu can send privacy-minimal feature events to a self-hosted Umami instance.
Users can turn analytics off from the General settings tab.

## Watchlist

Add a movie from its current page with the bookmark button, or select
**Add Movie** in the sidebar to enter it manually.

To import Letterboxd:

1. Export your data from Letterboxd.
2. Select **Import Letterboxd CSV…** under Watchlist.
3. Choose the exported watchlist CSV file.

The importer expects the standard Letterboxd columns, including `Name` and
`Letterboxd URI`.

## Requirements

- macOS 26 or later
- An account with each streaming service you want to use

Availability and playback depend on the streaming service, your subscription,
and your region. A provider may also restrict playback in embedded browsers.

## Feature requests

Feature requests are very welcome! I am always happy to hear your ideas for
Wianu. Please share them using the
[feature request issue template](.github/ISSUE_TEMPLATE/feature-request.md).

## Build from source

1. Clone this repository.
2. Open `Wianu.xcodeproj` in Xcode.
3. Select the Wianu scheme and build.

Swift Package Manager resolves the project's dependencies, including Sparkle
for application updates.

For command-line development, run `make help` to see the available tasks.
Common commands include `make build`, `make test`, `make format`, `make lint`,
and `make check`. SwiftFormat and SwiftLint can be installed with Homebrew.

## Data

Saved sites, Continue Watching entries, and watchlist items are stored locally
on your Mac. Streaming-service sign-in and playback take place in the embedded
web view. Movie and TV metadata is retrieved through Wianu's backend service.

## License

Wianu is available under the terms in [LICENSE](LICENSE).
