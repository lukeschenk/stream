import Foundation

/// Describes what AVPlayer on macOS can play, so Jellyfin knows when it can
/// send the original file and when it must remux or transcode.
nonisolated struct JellyfinDeviceProfile: Encodable, Sendable {
    struct DirectPlayProfile: Encodable, Sendable {
        let container: String
        let type: String
        let videoCodec: String?
        let audioCodec: String?

        enum CodingKeys: String, CodingKey {
            case container = "Container"
            case type = "Type"
            case videoCodec = "VideoCodec"
            case audioCodec = "AudioCodec"
        }
    }

    struct TranscodingProfile: Encodable, Sendable {
        let container: String
        let type: String
        let videoCodec: String
        let audioCodec: String
        let `protocol`: String
        let context: String
        let maxAudioChannels: String
        let minSegments: Int
        let breakOnNonKeyFrames: Bool
        let enableSubtitlesInManifest: Bool

        enum CodingKeys: String, CodingKey {
            case container = "Container"
            case type = "Type"
            case videoCodec = "VideoCodec"
            case audioCodec = "AudioCodec"
            case `protocol` = "Protocol"
            case context = "Context"
            case maxAudioChannels = "MaxAudioChannels"
            case minSegments = "MinSegments"
            case breakOnNonKeyFrames = "BreakOnNonKeyFrames"
            case enableSubtitlesInManifest = "EnableSubtitlesInManifest"
        }
    }

    struct ProfileCondition: Encodable, Sendable {
        let condition: String
        let property: String
        let value: String
        let isRequired: Bool

        enum CodingKeys: String, CodingKey {
            case condition = "Condition"
            case property = "Property"
            case value = "Value"
            case isRequired = "IsRequired"
        }
    }

    struct CodecProfile: Encodable, Sendable {
        let type: String
        let codec: String
        let conditions: [ProfileCondition]

        enum CodingKeys: String, CodingKey {
            case type = "Type"
            case codec = "Codec"
            case conditions = "Conditions"
        }
    }

    struct SubtitleProfile: Encodable, Sendable {
        let format: String
        let method: String

        enum CodingKeys: String, CodingKey {
            case format = "Format"
            case method = "Method"
        }
    }

    let name: String
    let maxStreamingBitrate: Int
    let maxStaticBitrate: Int
    let directPlayProfiles: [DirectPlayProfile]
    let transcodingProfiles: [TranscodingProfile]
    let codecProfiles: [CodecProfile]
    let subtitleProfiles: [SubtitleProfile]

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case maxStreamingBitrate = "MaxStreamingBitrate"
        case maxStaticBitrate = "MaxStaticBitrate"
        case directPlayProfiles = "DirectPlayProfiles"
        case transcodingProfiles = "TranscodingProfiles"
        case codecProfiles = "CodecProfiles"
        case subtitleProfiles = "SubtitleProfiles"
    }

    /// Generous enough for 4K remuxes on a home network.
    static let localNetworkBitrate = 120_000_000

    static let avPlayer = JellyfinDeviceProfile(
        name: "Wianu (AVPlayer)",
        maxStreamingBitrate: localNetworkBitrate,
        maxStaticBitrate: localNetworkBitrate,
        directPlayProfiles: [
            DirectPlayProfile(
                container: "mp4,m4v,mov",
                type: "Video",
                videoCodec: "h264,hevc",
                audioCodec: "aac,ac3,eac3,alac,flac,mp3"
            )
        ],
        transcodingProfiles: [
            // Fragmented-MP4 HLS carries HEVC as well as H.264, and lets the
            // server copy compatible streams instead of re-encoding them.
            TranscodingProfile(
                container: "mp4",
                type: "Video",
                videoCodec: "hevc,h264",
                audioCodec: "aac,ac3,eac3",
                protocol: "hls",
                context: "Streaming",
                maxAudioChannels: "6",
                minSegments: 2,
                breakOnNonKeyFrames: true,
                enableSubtitlesInManifest: true
            )
        ],
        codecProfiles: [
            // AVFoundation only plays HEVC tagged hvc1 (or Dolby Vision dvh1).
            // Not required, so files with no recorded tag (common in MKV) can
            // still be remuxed instead of fully re-encoded.
            CodecProfile(
                type: "Video",
                codec: "hevc",
                conditions: [
                    ProfileCondition(
                        condition: "EqualsAny",
                        property: "VideoCodecTag",
                        value: "hvc1|dvh1",
                        isRequired: false
                    )
                ]
            )
        ],
        subtitleProfiles: [
            SubtitleProfile(format: "vtt", method: "Hls"),
            SubtitleProfile(format: "mov_text", method: "Embed")
        ]
    )
}
