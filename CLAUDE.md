# Stream (fork of Wianu)

Personal fork of timwehrle/wianu: a SwiftUI Mac app (target **Wianu**) plus an
iPhone, iPad and Apple TV app (target **Stream Mobile**, sources in `Mobile/`).
Work happens on the `jellyfin-and-kids-profile` branch. The repo is public.

## Never commit secrets

API keys live in `Config/Secrets.xcconfig`, which git ignores. It's included by
`Config/Stream.xcconfig` and read through Info.plist keys
(`StreamingAvailabilityAPIKey`, `TraktClientID`). Keep keys out of code, tests,
commit messages and docs. `Config/Secrets.example.xcconfig` shows the format.

## Build and check

```sh
make build                     # Mac app, unsigned
make test                      # Mac unit tests (Tests/)
make lint                      # SwiftLint --strict: warnings fail
make format                    # SwiftFormat
xcodebuild -project Wianu.xcodeproj -scheme "Stream Mobile" \
  -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Wianu.xcodeproj -scheme "Stream Mobile" \
  -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO build
```

The work so far was written and unit-tested on Linux, so it has not been built
with Xcode yet. Expect small compile fixes in SwiftUI views, CloudKit and
AVKit code on the first build.

## Conventions

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (Swift 5 mode). Data types and
  network clients are marked `nonisolated`; their extensions need
  `nonisolated extension`.
- Lint limits: lines ≤ 120, type bodies ≤ 300 lines, files ≤ 550 lines.
  Split into `Type+Feature.swift` extensions when close.
- New files must be added to the right targets in `project.pbxproj`. Shared
  code under `Wianu/` is usually in both Wianu and Stream Mobile; Mac-only
  views stay out of Stream Mobile.
- Tests use Swift Testing with fixture sessions (`TMDBSession` protocol);
  no live network calls in tests.
- User-Agent for third-party APIs is `Stream/<version> (https://github.com/lukeschenk/stream)`.

## Layout

- `Wianu/Features/Profiles` — Main and Kids profiles; each has its own sites,
  watchlist, cookies and Jellyfin account.
- `Wianu/Features/Jellyfin` — client (password and Quick Connect sign-in,
  playback through AVPlayer with direct play or HLS transcode), connection
  per profile, settings UI. Needs Jellyfin 10.9+.
- `Wianu/Features/Services` — the service catalog, region availability,
  title and episode links (Wikidata + Streaming Availability, cached by
  `ExpiringCache`), and release schedules from Trakt (`ShowSchedule.swift`).
- `Wianu/Infrastructure/Cloud` — iCloud: `WatchlistCloudSync`
  (CKSyncEngine, one zone per profile) and `ProfileSettingsCloudSync` (one
  record per profile with the sites and Jellyfin server; newest wins).
- `Mobile/` — the iOS/tvOS app. tvOS has no web browser, so titles open in
  each service's app by universal link or the TV app.

## Decisions so far

The first rounds of work happened in a cloud session; `git log` on this branch
has the history. Things worth knowing:

- Jellyfin access tokens are tied to the device ID that signed in, so they
  stay in each device's Keychain. Only the server address and username sync
  through iCloud; Quick Connect covers signing in on Apple TV.
- Streaming Availability's free plan allows 1,000 lookups a month, so answers
  are cached (`TitleLinksModel.lifetime`): movies 30 days, shows a week, and
  shows again a few hours after a new episode airs (`linksStaleBefore`). A
  quota or auth error pauses lookups until relaunch; Wikidata fills in.
- Wikidata properties used: TMDB P4947 (movie) / P4983 (TV), Disney+ P13902,
  Netflix P1874, Prime Video P14440 / P14462 / P8055, Tubi P7760 / P7761,
  Crunchyroll P11330, Apple TV P9586 (movie) / P9751 (show).
- Trakt is used through its public API with only the Client ID
  (`trakt-api-key` header). The Trakt app has no client secret; sign-in must
  use PKCE.
- "Pick up" progress is only what was opened from Stream; no service exposes
  watch history. Recording an episode adds the show to the watchlist.
- Settings sync merges sites by ID and host on a device's first sync, then the
  newest change wins.

## Still to do

- First Xcode build of both schemes; fix compile errors; run on devices.
- iCloud capability and container for both targets (see README).
- Trakt sign-in (PKCE, redirect `com.lukeschenk.stream://trakt`; check
  whether device-code sign-in works without a client secret on Apple TV),
  then sync watch history.
- Optional: playback progress on the Mac, a subtitle picker, app icons, a PR
  into main.
