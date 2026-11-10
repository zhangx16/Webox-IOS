//
//  DetailView.swift
//  WeBox for iOS
//
//  影片详情: 简介、分集、收藏、下载与播放线路解析。
//

import SwiftUI

struct EpisodeGroup: Identifiable {
    var name: String
    var episodes: [MediaItem]
    var id: String { name }
}

struct DetailView: View {
    let source: ContentSource
    let item: MediaItem

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var settings: AppSettings

    @State private var detail: MediaItem?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var expanded = false
    @State private var selectedGroup: String?
    @State private var selectedEpisodeID: String?
    @State private var playback: PlaybackRequest?
    @State private var showDownloads = false
    @State private var resolving = false

    private var content: MediaItem { detail ?? item }

    private var groups: [EpisodeGroup] {
        var order: [String] = []
        var buckets: [String: [MediaItem]] = [:]
        for child in content.childItems {
            let name = child.episodeGroup ?? "正片"
            if buckets[name] == nil { order.append(name); buckets[name] = [] }
            buckets[name]?.append(child)
        }
        return order.map { EpisodeGroup(name: $0, episodes: buckets[$0] ?? []) }
    }

    private var currentEpisodes: [MediaItem] {
        if let selectedGroup, let group = groups.first(where: { $0.name == selectedGroup }) {
            return group.episodes
        }
        return groups.first?.episodes ?? content.childItems
    }

    private var selectedEpisode: MediaItem? {
        if let selectedEpisodeID, let match = currentEpisodes.first(where: { episodeID($0) == selectedEpisodeID }) {
            return match
        }
        return currentEpisodes.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actions
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                } else if let errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(errorMessage).font(.system(size: 13)).foregroundStyle(.secondary)
                        Button("重试") { Task { await load() } }.buttonStyle(.bordered)
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                }
                overviewSection
                episodesSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .background(Theme.background)
        .navigationTitle(content.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .fullScreenCover(item: $playback) { request in
            PlayerScreen(request: request)
        }
        .sheet(isPresented: $showDownloads) {
            DownloadSelectionView(item: content, source: source, episodes: content.childItems)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(urlString: content.poster)
                    .frame(height: 210)
                    .blur(radius: 12)
                    .opacity(0.35)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                HStack(alignment: .bottom, spacing: 14) {
                    RemoteImage(urlString: content.poster)
                        .frame(width: 104, height: 156)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(content.displayTitle).font(.system(size: 19, weight: .bold)).lineLimit(2)
                        if let rating = content.ratingText {
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.orange)
                                Text(rating).font(.system(size: 12, weight: .semibold))
                                if let source = content.ratingSource, !source.isEmpty {
                                    Text(source).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if let subtitle = content.description, !subtitle.isEmpty {
                            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                        }
                        if let progress = library.progress(for: item.link ?? item.id), progress.fraction > 0.02 {
                            Text("已续播至 \(timeText(progress.position))").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
            }
        }
        .padding(.top, 4)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                Task { await play(episode: selectedEpisode) }
            } label: {
                HStack(spacing: 6) {
                    if resolving { ProgressView().tint(.white) } else { Image(systemName: "play.fill") }
                    Text(resolving ? "正在解析播放地址" : "立即播放").font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(resolving || currentEpisodes.isEmpty)

            Button {
                library.toggleFavorite(item, source: source)
            } label: {
                Image(systemName: library.isFavorite(item.link ?? item.id) ? "heart.fill" : "heart")
                    .font(.system(size: 16))
                    .frame(width: 44, height: 42)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(library.isFavorite(item.link ?? item.id) ? .red : .primary)
            }
            .buttonStyle(.plain)

            Button { showDownloads = true } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 16))
                    .frame(width: 44, height: 42)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(currentEpisodes.isEmpty)
        }
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("剧情简介").font(.system(size: 15, weight: .semibold))
            let text = (content.overview?.isEmpty == false ? content.overview! : (content.description ?? ""))
            if text.isEmpty {
                Text("这个内容源暂未提供影片简介。").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 3)
                Button(expanded ? "收起简介 ⌃" : "展开简介 ⌄") {
                    withAnimation { expanded.toggle() }
                }
                .font(.system(size: 12, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("选集").font(.system(size: 15, weight: .semibold))
                Spacer()
                if !content.childItems.isEmpty {
                    Text("\(currentEpisodes.count) 集").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if groups.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(groups) { group in
                            Button {
                                selectedGroup = group.name
                                selectedEpisodeID = nil
                            } label: {
                                Text(group.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background((selectedGroup ?? groups.first?.name) == group.name
                                                ? Color.accentColor.opacity(0.18) : Theme.card, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if currentEpisodes.isEmpty {
                Text("暂无分集").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                    ForEach(currentEpisodes) { episode in
                        let selected = episodeID(episode) == (selectedEpisodeID ?? currentEpisodes.first.map(episodeID) ?? "")
                        Button {
                            selectedEpisodeID = episodeID(episode)
                        } label: {
                            Text(episode.title)
                                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(selected ? Color.accentColor.opacity(0.18) : Theme.card,
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func episodeID(_ episode: MediaItem) -> String {
        episode.link ?? episode.id
    }

    private func play(episode: MediaItem?) async {
        guard let episode else { return }
        resolving = true
        errorMessage = nil
        do {
            let streams = try await PlaybackResolver.streams(for: episode, in: source)
            let episodes = currentEpisodes
            let index = episodes.firstIndex { episodeID($0) == episodeID(episode) } ?? 0
            playback = PlaybackResolver.makeRequest(item: content, source: source,
                                                   episodes: episodes, index: index, streams: streams)
            library.recordBrowse(content, source: source)
        } catch {
            errorMessage = error.localizedDescription
        }
        resolving = false
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let provider = try SourceManager.shared.provider(for: source)
            _ = try? await provider.loadMetadata()
            let loaded = try await provider.detail(link: item.link ?? item.id)
            detail = loaded
            if loaded.childItems.isEmpty, loaded.playbackURL == nil {
                errorMessage = "这个条目没有提供可播放地址。部分模块仅提供片单或影视资料。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func timeText(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
                             : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Download selection

struct DownloadSelectionView: View {
    let item: MediaItem
    let source: ContentSource
    let episodes: [MediaItem]

    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(episodes) { episode in
                        Button {
                            let id = episode.link ?? episode.id
                            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
                        } label: {
                            HStack {
                                Text(episode.title).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: selected.contains(episode.link ?? episode.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(episode.link ?? episode.id) ? Color.accentColor : .secondary)
                            }
                        }
                    }
                } footer: {
                    Text("下载所选 · \(selected.count) 集。直播与实际解析的线路可能不支持离线下载。")
                }
                if let message {
                    Section { Text(message).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("下载选集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selected.count == episodes.count ? "取消全选" : "全选") {
                        selected = selected.count == episodes.count ? [] : Set(episodes.map { $0.link ?? $0.id })
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(busy ? "正在加入…" : "下载") { Task { await enqueue() } }
                        .disabled(selected.isEmpty || busy)
                }
            }
        }
    }

    private func enqueue() async {
        guard !selected.isEmpty else { return }
        busy = true
        var failures: [String] = []
        for episode in episodes where selected.contains(episode.link ?? episode.id) {
            do {
                let streams = try await PlaybackResolver.streams(for: episode, in: source)
                guard let stream = streams.first(where: { $0.supportsDownload && $0.url != nil }) else {
                    failures.append("\(episode.title)：没有可下载的播放线路")
                    continue
                }
                _ = try downloads.enqueue(title: item.title, subtitle: episode.title, poster: item.poster,
                                          link: episode.link ?? episode.id, source: source, stream: stream)
            } catch {
                failures.append("\(episode.title)：\(error.localizedDescription)")
            }
        }
        message = failures.isEmpty ? "已加入下载，可在收藏 → 下载查看" : failures.joined(separator: "\n")
        busy = false
        if failures.isEmpty { dismiss() }
    }
}
