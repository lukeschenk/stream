<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Assets/stream-logo.svg">
    <img src="Assets/stream-logo-dark.svg" width="120" alt="Stream app icon">
  </picture>
</p>

<div align="center">

![Stream](Assets/stream-light-mode.svg#gh-light-mode-only)
![Stream](Assets/stream-dark-mode.svg#gh-dark-mode-only)

</div>

<p align="center">
  All your streaming. One home.
</p>

<img src="Assets/showcase.png">

Stream is a lightweight browser for organizing streaming websites, shows, and
movies in one place. Add the services you use, search across them, keep links
to shows you are watching, and maintain a watchlist without switching between
browser tabs.

## About this fork

This is a personal fork of [timwehrle/wianu](https://github.com/timwehrle/wianu)
(GPL-3.0). Work happens on the `jellyfin-and-kids-profile` branch. It adds:

- **Profiles** — Main and Kids, switched from the Profile menu on the Mac
  (⌃⌘1 / ⌃⌘2) or in Settings on Stream Mobile. Each profile has its own sites,
  watchlist, website sign-ins and Jellyfin account. Give the Kids profile a
  Jellyfin user with parental controls.
- **Jellyfin** — browse and play your own library. Files play directly when
  Apple's player supports them, and the server converts the rest; resume
  points sync with the server. Sign in with a password, or with a Quick
  Connect code approved from a device that's already signed in (handy on Apple
  TV). Choose subtitles from the player; Jellyfin adds the one you pick to the
  stream. Needs Jellyfin 10.9 or later.
- **Service setup** — a first-run setup picks your services from TMDB's list
  for your region, and search can show only titles included with them.
- **Title and episode links** — services open on the title or episode rather
  than a search, using Wikidata and, with a key, the Streaming Availability
  API.
- **Pick up where you left off** — for shows, Stream remembers the last
  episode you opened from it and offers the next one. Sign in to Trakt to also
  bring in what you watched elsewhere: the latest episode of each show becomes
  where to pick up, and shows watched in the last month join the watchlist.
- **Release days** — when a show's next episode comes out, or its weekly slot,
  from Trakt.
- **iCloud sync** — optional. Each profile's watchlist, services and Jellyfin
  server stay the same on the Mac, iPhone, iPad and Apple TV. Sign-ins stay on
  each device.
- **Stream Mobile** — an iPhone, iPad and Apple TV app with Jellyfin playback,
  shows in progress, the watchlist, search and where to watch. Apple TV has no
  web browser, so titles open in each service's app or the TV app.

### Status

A work in progress. The Mac, iPhone, iPad and Apple TV apps build in Xcode,
the unit tests pass, and the iPhone app runs in the simulator. Not yet tried:
a signed build with iCloud, Trakt sign-in through to a synced history,
subtitles against a real server, and real devices.
[CLAUDE.md](CLAUDE.md) has the code conventions, layout and what's next.

### Setting up a build

1. In Xcode, choose your team under Signing & Capabilities for the **Stream**
   and **Stream Mobile** targets.
2. iCloud sync is set up for the container `iCloud.com.lukeschenk.stream` (the
   entitlements files and `STREAM_CLOUDKIT_CONTAINER` in
   `Config/Stream.xcconfig`). The first signed build registers it with your
   Apple developer account. Builds without code signing leave iCloud off.
3. Optional: copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig`
   and add your API keys (see below). Git ignores that file, so keys never
   reach this public repo.
4. Run the **Stream** scheme for the Mac or **Stream Mobile** for iPhone, iPad
   and Apple TV.

### API keys

Both are optional; Stream builds and runs without them.

| Setting | Get it from | What it adds |
| :- | :- | :- |
| `STREAMING_AVAILABILITY_API_KEY` | [Movie of the Night](https://www.movieofthenight.com/about/api) | Episode links and more services. The free plan allows 1,000 lookups a month; answers are saved on each device (movies for 30 days, shows for a week or until a new episode airs). Without it, Wikidata supplies title links only. |
| `TRAKT_CLIENT_ID` | [Trakt API apps](https://trakt.tv/oauth/applications) | Release days, and Trakt sign-in for your watch history. Only the Client ID is used; sign-in uses PKCE, so there's no client secret. Set the app's redirect URI to `com.lukeschenk.stream://trakt`. |

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

Stream's Continue Watching list saves a link; it does not track playback
progress itself.

For the best cross-device experience, add a show from its **show or series
detail page**, not from an individual episode or video player. When you open
the saved item later, use the streaming service's own Continue or Resume
button. The service can then select the latest episode using the progress
synced to your account.

If you save an episode or player page, Stream will reopen that exact episode.
Progress made on another device cannot change the saved link.

In this fork, show pages also get a **Pick Up** section when a Streaming
Availability key is set. Opening an episode from Stream saves it (adding the
show to your watchlist), and next time Stream offers the following episode.
Jellyfin items resume where you stopped.

### Example

1. Open the detail page for _How I Met Your Mother_.
2. Select the Continue Watching button in Stream's toolbar.
3. Watch on any device signed in to the same streaming account.
4. Open the show from Stream and select the provider's Continue or Resume
   button.

> Stream is not affiliated with streaming providers and cannot read their
> private viewing history. Playback synchronization is handled by each
> provider.

## Getting started

1. Launch Stream.
2. Select **Add Site** in the sidebar.
3. Enter a name and the website URL.
4. Optionally enter a search URL containing `{query}`, for example
   `https://example.com/search?q={query}`.
5. Sign in to the streaming website and use it as you would in a browser.

Some known sites receive a suggested search URL automatically. For other
sites, you can add a compatible search URL yourself.

## Anonymous usage analytics

Upstream Stream can send privacy-minimal feature events to a self-hosted Umami
instance. This fork switches analytics off.

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

- macOS 26 or later; Stream Mobile needs iOS, iPadOS or tvOS 26 or later
- An account with each streaming service you want to use
- For your own library, a Jellyfin 10.9 or later server

Availability and playback depend on the streaming service, your subscription,
and your region. A provider may also restrict playback in embedded browsers.

## Feature requests

Feature requests are very welcome! I am always happy to hear your ideas for
Stream. Please share them using the
[feature request issue template](.github/ISSUE_TEMPLATE/feature-request.md).

## Build from source

1. Clone this repository.
2. Open `Stream.xcodeproj` in Xcode.
3. Select the Stream scheme (Mac) or Stream Mobile scheme (iPhone, iPad and
   Apple TV) and build. See [Setting up a build](#setting-up-a-build) for
   signing, iCloud and API keys.

Swift Package Manager resolves the project's dependencies, including Sparkle
for application updates.

For command-line development, run `make help` to see the available tasks.
Common commands include `make build`, `make test`, `make format`, `make lint`,
and `make check`. SwiftFormat and SwiftLint can be installed with Homebrew.

## Data

Saved sites, Continue Watching entries, and watchlist items are stored locally
on your Mac. Streaming-service sign-in and playback take place in the embedded
web view. Movie and TV metadata is retrieved through Wianu's backend service.

In this fork:

- With iCloud sync on, the watchlist, chosen services and Jellyfin server
  address are kept in your private iCloud database. Jellyfin sign-ins are
  stored in each device's Keychain and aren't synced.
- Title links come from Wikidata and, with a key, Streaming Availability;
  release days come from Trakt. These lookups send the title's TMDB ID (and
  your region, for Streaming Availability), not your viewing history.
- Jellyfin playback talks only to your own server.
- With Trakt signed in, Stream reads your watched shows from Trakt; it never
  writes to your Trakt history. Trakt sign-ins are stored in each device's
  Keychain and aren't synced.

## License

Stream is available under the terms in [LICENSE](LICENSE).
