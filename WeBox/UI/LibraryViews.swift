//
//  LibraryViews.swift
//  WeBox for iOS
//
//  我的收藏 and 下载.
//

import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var library: Library

    var body: some View {
        NavigationStack {
            Group {
                if library.favorites.isEmpty {
                    EmptyStateView(icon: "heart",
                                   title: "还没有收藏的内容",
                                   message: "在影片详情页点击“收藏”，即可在这里继续观看。")
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 16) {
                            ForEach(library.favorites) { entry in
                                if let source = library.source(id: entry.sourceID) {
                                    NavigationLink(value: DetailRoute(item: entry.item, sourceID: source.id)) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            RemoteImage(urlString: entry.item.poster)
                                                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                            Text(entry.item.displayTitle).font(.system(size: 12)).lineLimit(2)
                                            Text(entry.sourceName).font(.system(size: 10)).foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("取消收藏", role: .destructive) {
                                            library.removeFavorite(link: entry.link)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .background(Theme.background)
            .navigationTitle("收藏 · \(library.favorites.count)")
            .navigationDestination(for: DetailRoute.self) { route in
                if let source = library.source(id: route.sourceID) {
                    DetailView(source: source, item: route.item)
                }
            }
        }
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @State private var playback: PlaybackRequest?

    var body: some View {
        NavigationStack {
            Group {
                if downloads.records.isEmpty {
                    EmptyStateView(icon: "arrow.down.circle",
                                   title: "还没有下载影片",
                                   message: "在影片详情页点击“下载”添加，完成后可离线观看。")
                } else {
                    List {
                        ForEach(downloads.records) { record in
                            DownloadRow(record: record) {
                                play(record)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    downloads.remove(record.id)
                                } label: { Label("删除", systemImage: "trash") }
                            }
                            .swipeActions(edge: .leading) {
                                if record.state == .downloading || record.state == .queued {
                                    Button { downloads.pause(record.id) } label: { Label("暂停", systemImage: "pause") }
                                } else if record.state != .completed {
                                    Button { downloads.resume(record.id) } label: { Label("继续", systemImage: "play") }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(Theme.background)
            .navigationTitle("下载")
            .toolbar {
                if !downloads.records.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("删除已完成") { downloads.removeAll(completedOnly: true) }
                            Button("全部删除", role: .destructive) { downloads.removeAll(completedOnly: false) }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .fullScreenCover(item: $playback) { request in
                PlayerScreen(request: request)
            }
        }
    }

    private func play(_ record: DownloadRecord) {
        guard let url = record.localURL else { return }
        let item = MediaItem(id: record.id, type: "url", title: record.title,
                             link: record.link, posterPath: record.poster,
                             description: record.subtitle, overview: nil,
                             rating: nil, ratingSource: nil, isLive: false,
                             episodeGroup: nil, children: nil, playbackURL: url.absoluteString)
        let source = Library.shared.source(id: record.sourceID)
            ?? ContentSource(id: record.sourceID, kind: .javascript, name: record.sourceName,
                             version: "1", icon: nil, scriptFile: nil, scriptText: nil,
                             sourceURL: nil, payload: nil, params: [:], enabled: true,
                             updatedAt: Date(), sizeBytes: 0)
        let stream = StreamSource(id: "local", name: "本地下载", url: url.absoluteString,
                                  manifest: nil, baseUrl: nil, mime: record.mime, mimeType: nil,
                                  headers: [:], downloadable: false, isLive: false,
                                  sourceId: record.sourceID, processor: nil)
        playback = PlaybackRequest(item: item, source: source, episodes: [item], index: 0,
                                   streams: [stream], engine: .system, loader: nil)
    }
}

private struct DownloadRow: View {
    let record: DownloadRecord
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(urlString: record.poster)
                .frame(width: 54, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(record.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                if let subtitle = record.subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
                HStack(spacing: 8) {
                    Text(record.state.title).font(.system(size: 11, weight: .medium))
                    if record.state == .downloading {
                        Text("\(Int(record.progress * 100))%").font(.system(size: 11).monospacedDigit())
                    }
                    if record.totalBytes > 0 {
                        Text(byteText(record.receivedBytes) + " / " + byteText(record.totalBytes))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if record.state == .downloading || record.state == .paused {
                    ProgressView(value: max(0.01, record.progress)).tint(.accentColor)
                }
                if let error = record.errorMessage, record.state == .failed {
                    Text(error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if record.state == .completed {
                Button(action: onPlay) { Image(systemName: "play.circle.fill").font(.system(size: 26)) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
