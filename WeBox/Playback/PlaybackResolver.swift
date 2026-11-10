//
//  PlaybackResolver.swift
//  WeBox for iOS
//
//  Resolves a concrete episode into playable streams through the owning provider.
//

import Foundation

@MainActor
enum PlaybackResolver {
    static func streams(for episode: MediaItem, in source: ContentSource) async throws -> [StreamSource] {
        let link = episode.link ?? episode.id
        if let playbackURL = episode.playbackURL, !playbackURL.isEmpty, playbackURL.lowercased().hasPrefix("http") {
            return [StreamSource(id: "direct", name: "直播", url: playbackURL, manifest: nil, baseUrl: nil,
                                 mime: nil, mimeType: nil, headers: [:], downloadable: false,
                                 isLive: episode.isLiveContent, sourceId: source.id, processor: nil)]
        }
        let provider = try SourceManager.shared.provider(for: source)
        _ = try? await provider.loadMetadata()
        let streams = try await provider.play(link: link, purpose: "playback")
        if streams.isEmpty { throw ScriptError.message("这个条目没有提供可播放地址") }
        return streams
    }

    static func makeRequest(item: MediaItem,
                            source: ContentSource,
                            episodes: [MediaItem],
                            index: Int,
                            streams: [StreamSource]) -> PlaybackRequest {
        PlaybackRequest(item: item, source: source, episodes: episodes, index: index,
                        streams: streams,
                        engine: AppSettings.shared.values.defaultEngine,
                        loader: { episode in try await streams(for: episode, in: source) })
    }
}
