import AVFoundation
import Foundation

/// One audio, video or subtitle stream in a Jellyfin media source.
nonisolated struct JellyfinMediaStream: Decodable, Hashable, Sendable {
    let index: Int
    let type: String
    let language: String?
    let displayTitle: String?
    let isForced: Bool?

    enum CodingKeys: String, CodingKey {
        case index = "Index"
        case type = "Type"
        case language = "Language"
        case displayTitle = "DisplayTitle"
        case isForced = "IsForced"
    }
}

/// A subtitle the viewer can choose, by Jellyfin's stream index.
nonisolated struct JellyfinSubtitleTrack: Identifiable, Hashable, Sendable {
    let index: Int
    let title: String

    var id: Int {
        index
    }

    static func tracks(in streams: [JellyfinMediaStream]?) -> [JellyfinSubtitleTrack] {
        (streams ?? [])
            .filter { $0.type == "Subtitle" }
            .map { stream in
                JellyfinSubtitleTrack(
                    index: stream.index,
                    title: stream.displayTitle
                        ?? stream.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
                        ?? "Subtitle \(stream.index)"
                )
            }
    }
}

extension AVPlayerItem {
    /// Turns the stream's subtitles on or off. Jellyfin puts only the chosen
    /// subtitle in the stream, so the first one is it.
    func showSubtitles(_ show: Bool) async {
        guard let group = try? await asset.loadMediaSelectionGroup(for: .legible) else { return }
        let option = show ? group.options.first { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) } : nil
        select(option ?? (show ? group.options.first : nil), in: group)
    }
}

#if !os(tvOS)
    import SwiftUI

    /// Picks the subtitle for a Jellyfin stream, for the Mac toolbar and the
    /// iPhone player. Apple TV uses the player's own transport bar instead.
    struct JellyfinSubtitleMenu: View {
        let playback: JellyfinPlayback

        var body: some View {
            Menu {
                Picker("Subtitles", selection: selection) {
                    Text("Off").tag(Int?.none)
                    ForEach(playback.subtitles) { track in
                        Text(track.title).tag(Int?.some(track.index))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Subtitles", systemImage: "captions.bubble")
            }
            .disabled(playback.isSwitchingSubtitles)
        }

        private var selection: Binding<Int?> {
            Binding(
                get: { playback.selectedSubtitle },
                set: { index in Task { await playback.selectSubtitle(index) } }
            )
        }
    }
#endif
