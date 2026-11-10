//
//  SearchView.swift
//  WeBox for iOS
//
//  搜索: 跨内容源搜索，按来源分组展示。
//

import SwiftUI

struct SearchSection: Identifiable {
    let id: String
    let source: ContentSource
    let items: [MediaItem]
}

@MainActor
final class SearchModel: ObservableObject {
    @Published var sections: [SearchSection] = []
    @Published var searching = false
    @Published var keyword = ""
    @Published var errors: [String] = []
    @Published var selectedSourceIDs: Set<String> = []

    func availableSources(_ library: Library) -> [ContentSource] {
        library.sources.filter { $0.enabled && $0.isSearchable }
    }

    func search(_ text: String, library: Library) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { sections = []; return }
        keyword = query
        searching = true
        errors = []
        sections = []

        let sources = availableSources(library).filter {
            selectedSourceIDs.isEmpty || selectedSourceIDs.contains($0.id)
        }
        for source in sources {
            guard let provider = try? SourceManager.shared.provider(for: source) else { continue }
            do {
                _ = try? await provider.loadMetadata()
                let page = try await provider.search(keyword: query, params: source.params, page: 1)
                if !page.items.isEmpty {
                    sections.append(SearchSection(id: source.id, source: source, items: page.items))
                }
            } catch {
                errors.append("\(source.displayName)：\(error.localizedDescription)")
            }
        }
        sections.sort { $0.source.displayName < $1.source.displayName }
        searching = false
    }
}

struct SearchView: View {
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SearchModel()
    @State private var text = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索电影、剧集", text: $text)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.search)
                            .onSubmit { Task { await model.search(text, library: library) } }
                        if model.searching { ProgressView() }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if !model.availableSources(library).isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(model.availableSources(library)) { source in
                                    let selected = model.selectedSourceIDs.isEmpty || model.selectedSourceIDs.contains(source.id)
                                    Button {
                                        if model.selectedSourceIDs.isEmpty {
                                            model.selectedSourceIDs = Set(model.availableSources(library).map(\.id))
                                        }
                                        if model.selectedSourceIDs.contains(source.id) {
                                            model.selectedSourceIDs.remove(source.id)
                                        } else {
                                            model.selectedSourceIDs.insert(source.id)
                                        }
                                    } label: {
                                        Text(source.displayName)
                                            .font(.system(size: 12, weight: .medium))
                                            .padding(.horizontal, 10).padding(.vertical, 6)
                                            .background(selected ? Color.accentColor.opacity(0.18) : Theme.card, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    if model.sections.isEmpty && !model.searching {
                        EmptyStateView(icon: "text.magnifyingglass",
                                       title: "搜索影视",
                                       message: "在已启用的内容源中查找影片，可以继续在详情页拨放或收藏。")
                            .frame(height: 300)
                    }

                    ForEach(model.sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(section.source.displayName).font(.system(size: 15, weight: .semibold))
                                Spacer()
                                Text("\(section.items.count) 个结果").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(section.items) { item in
                                        NavigationLink(value: DetailRoute(item: item, sourceID: section.source.id)) {
                                            PosterCard(item: item).frame(width: 104)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }

                    if !model.errors.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("部分内容源未能完成搜索").font(.system(size: 12, weight: .medium))
                            ForEach(model.errors, id: \.self) { message in
                                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: DetailRoute.self) { route in
                if let source = library.source(id: route.sourceID) {
                    DetailView(source: source, item: route.item)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
        }
    }
}
