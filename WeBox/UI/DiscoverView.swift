//
//  DiscoverView.swift
//  WeBox for iOS
//
//  发现: 内容源切换、栏目浏览入口、最近浏览与收藏。
//

import SwiftUI

struct BrowseRoute: Hashable {
    var sourceID: String
    var moduleID: String
}

struct DetailRoute: Hashable {
    var item: MediaItem
    var sourceID: String
}

struct DiscoverView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var settings: AppSettings

    @State private var selectedSourceID: String?
    @State private var metadata: SourceMetadata?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var showSearch = false
    @State private var showImport = false
    @State private var showSourceSettings = false

    private var enabledSources: [ContentSource] {
        library.sources.filter { $0.enabled }
    }

    private var selectedSource: ContentSource? {
        if let selectedSourceID, let match = library.source(id: selectedSourceID) { return match }
        return enabledSources.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if enabledSources.isEmpty {
                    EmptyStateView(icon: "square.stack.3d.up",
                                   title: "还没有可用的内容源",
                                   message: "导入 JS 内容源、M3U 直播源或 VOD 接口后即可开始浏览。",
                                   action: (title: "导入内容源", handler: { showImport = true }))
                        .frame(height: 320)
                } else {
                    sourcePicker
                    modulesSection
                    recentSection
                    favoritesSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .navigationTitle("发现")
        .background(Theme.background)
        .navigationDestination(for: BrowseRoute.self) { route in
            if let source = library.source(id: route.sourceID) {
                BrowseView(source: source, moduleID: route.moduleID)
            }
        }
        .navigationDestination(for: DetailRoute.self) { route in
            if let source = library.source(id: route.sourceID) {
                DetailView(source: source, item: route.item)
            }
        }
        .sheet(isPresented: $showSearch) { SearchView() }
        .sheet(isPresented: $showImport) { ImportSourceView() }
        .sheet(isPresented: $showSourceSettings) {
            if let source = selectedSource { SourceSettingsView(source: source) }
        }
        .task(id: selectedSource?.id) { await loadMetadata() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("WeBox").font(.system(size: 26, weight: .bold))
                    Text("发现喜欢的影视，留住想看的故事。").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showSearch = true } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .semibold))
                }
            }
            Button { showSearch = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text("搜索电影、剧集").foregroundStyle(.secondary)
                    Spacer()
                    if let source = selectedSource {
                        Text(source.displayName).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 6)
    }

    private var sourcePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(enabledSources) { source in
                    Button { selectedSourceID = source.id } label: {
                        HStack(spacing: 7) {
                            if let icon = source.icon, !icon.isEmpty {
                                RemoteImage(urlString: icon).frame(width: 22, height: 22)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            } else {
                                Image(systemName: "shippingbox").font(.system(size: 13))
                            }
                            Text(source.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(source.id == selectedSource?.id ? Color.accentColor.opacity(0.16) : Theme.card,
                                    in: Capsule())
                        .overlay(Capsule().strokeBorder(source.id == selectedSource?.id ? Color.accentColor.opacity(0.5) : .clear))
                    }
                    .buttonStyle(.plain)
                }
                Button { showImport = true } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                        .padding(10).background(Theme.card, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var modulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("栏目").font(.system(size: 16, weight: .semibold))
                Spacer()
                if let source = selectedSource {
                    Button("配置") { showSourceSettings = true }
                        .font(.system(size: 12))
                }
            }
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else if let loadError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(loadError).font(.system(size: 13)).foregroundStyle(.secondary)
                    HStack {
                        Button("重试") { Task { await loadMetadata() } }.buttonStyle(.bordered)
                        Button("填写配置") { showSourceSettings = true }.buttonStyle(.bordered)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            } else if let metadata {
                let modules = metadata.browseModules
                if modules.isEmpty {
                    Text("这个内容源没有栏目").font(.system(size: 13)).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                        ForEach(modules) { module in
                            NavigationLink(value: BrowseRoute(sourceID: metadata.id, moduleID: module.id)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(module.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                    Text("浏览").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !library.browseHistory.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("最近浏览").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text("\(library.browseHistory.count) 条").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(library.browseHistory.prefix(10)) { entry in
                            if let source = library.source(id: entry.sourceID) {
                                NavigationLink(value: DetailRoute(item: entry.item, sourceID: source.id)) {
                                    PosterCard(item: entry.item).frame(width: 96)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var favoritesSection: some View {
        if !library.favorites.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("我的收藏").font(.system(size: 16, weight: .semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(library.favorites.prefix(10)) { entry in
                            if let source = library.source(id: entry.sourceID) {
                                NavigationLink(value: DetailRoute(item: entry.item, sourceID: source.id)) {
                                    PosterCard(item: entry.item).frame(width: 96)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private func loadMetadata() async {
        guard let source = selectedSource else { metadata = nil; return }
        isLoading = true
        loadError = nil
        do {
            let provider = try SourceManager.shared.provider(for: source)
            let loaded = try await provider.loadMetadata()
            metadata = loaded
        } catch {
            loadError = error.localizedDescription
            metadata = nil
        }
        isLoading = false
    }
}

enum Theme {
    static var background: Color { Color(uiColor: .systemGroupedBackground) }
    static var card: Color { Color(uiColor: .secondarySystemGroupedBackground) }
}
