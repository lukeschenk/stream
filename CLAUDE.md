# Stream (fork of Wianu)

Personal fork of timwehrle/wianu: a SwiftUI Mac app (target **Stream**) plus an
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
xcodebuild -project Stream.xcodeproj -scheme "Stream Mobile" \
  -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Stream.xcodeproj -scheme "Stream Mobile" \
  -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO build
```

Both schemes build with Xcode 27.2 for macOS, iOS and tvOS, and the 144 tests
pass. The iPhone app runs in the simulator. There's no tvOS simulator runtime
on this Mac yet (`xcodebuild -downloadPlatform tvOS`). Build into a scratch
`-derivedDataPath`: `build/` isn't git-ignored.

## Conventions

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (Swift 5 mode). Data types and
  network clients are marked `nonisolated`; their extensions need
  `nonisolated extension`.
- Lint limits: lines ≤ 120, type bodies ≤ 300 lines, files ≤ 550 lines.
  Split into `Type+Feature.swift` extensions when close.
- New files must be added to the right targets in `project.pbxproj`. Shared
  code under `Stream/` is usually in both Stream and Stream Mobile; Mac-only
  views stay out of Stream Mobile.
- Tests use Swift Testing with fixture sessions (`TMDBSession` protocol);
  no live network calls in tests.
- User-Agent for third-party APIs is `Stream/<version> (https://github.com/lukeschenk/stream)`.

## Layout

- `Stream/Features/Profiles` — Main and Kids profiles; each has its own sites,
  watchlist, cookies and Jellyfin account.
- `Stream/Features/Jellyfin` — client (password and Quick Connect sign-in,
  playback through AVPlayer with direct play or HLS transcode), connection
  per profile, settings UI. Needs Jellyfin 10.9+.
- `Stream/Features/Services` — the service catalog, region availability,
  title and episode links (Wikidata + Streaming Availability, cached by
  `ExpiringCache`), and release schedules from Trakt (`ShowSchedule.swift`).
- `Stream/Features/Trakt` — sign-in (`TraktAuth`), the per-profile
  `TraktConnection`, watch history (`TraktHistory`) and the settings screen.
- `Stream/Infrastructure/Cloud` — iCloud: `WatchlistCloudSync`
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
- Trakt is used with only the Client ID (`trakt-api-key` header). Since
  October 2026 Trakt makes `client_secret` optional and supports PKCE
  (trakt/trakt-api#974). All `/oauth` calls go to `auth.trakt.tv`, which Trakt
  enforces from February 2027. The Mac and iPhone sign in through the browser
  (`webAuthenticationSession`, redirect `com.lukeschenk.stream://trakt`); every
  platform can sign in with a device code, and Apple TV only that way.
  Requesting a device code without a secret was confirmed against the live
  API; approving one hasn't been tried yet.
- Trakt history is read-only: `/sync/watched/shows` moves "pick up" forward to
  the latest regular episode watched (never back), and adds shows watched in
  the last 30 days to the watchlist. Opening an episode in Stream doesn't mean
  it was watched, so nothing is written to Trakt. Syncs run at launch and when
  the mobile app comes forward, at most every 30 minutes.
- iCloud container `iCloud.com.lukeschenk.stream`. iOS can't read its own
  entitlements, so Stream Mobile gets the ID from `STREAM_CLOUDKIT_CONTAINER`,
  which is empty when `CODE_SIGNING_ALLOWED=NO`. CloudKit crashes in builds
  without the entitlement.
- Subtitles: choosing one requests PlaybackInfo with `SubtitleStreamIndex` and
  direct play off, so Jellyfin builds an HLS stream with that subtitle as VTT;
  the player then turns on the stream's only legible track.
- The app icon is a play mark (`StreamLogo.icon`, iOS and Mac) replacing
  upstream's W. Apple TV needs layered brand assets (`StreamLogoTV` in
  `Stream/Assets.xcassets`), made from the same mark.
- "Pick up" progress is only what was opened from Stream; no service exposes
  watch history. Recording an episode adds the show to the watchlist.
- Settings sync merges sites by ID and host on a device's first sync, then the
  newest change wins.

## Still to do

- First signed build, which registers the iCloud container; then check sync
  between two devices.
- Set the Trakt app's redirect URI to `com.lukeschenk.stream://trakt` and try
  both sign-ins through to a synced history.
- Try subtitles against a real Jellyfin server.
- Run on devices, and on an Apple TV simulator once the runtime is installed.
- The README and website logos are still upstream's W.
- Decide what "playback progress on the Mac" should mean: Jellyfin progress
  already syncs, so it's either tracking playback in the services' web
  players or scrobbling to Trakt.
