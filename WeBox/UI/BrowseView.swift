//
//  BrowseView.swift
//  WeBox for iOS
//
//  分类浏览 with filter chips, pagination and in-place search.
//

import SwiftUI

@MainActor
final class BrowseModel: ObservableObject {
    let source: ContentSource
    let moduleID: String

    @Published var metadata: SourceMetadata?
    @Published var module: ModuleSpec?
    @Published var items: [MediaItem] = []
    @Published var filters: [FilterChoice] = []
    @Published var values: [String: String] = [:]
    @Published var page = 1
    @Published var hasMore = false
    @Published var isLoading = false
    @Published var error: String?
    @Published var keyword = ""
    @Published var searching = false

    private var provider: ContentProvider?

    init(source: ContentSource, moduleID: String) {
        self.source = source
        self.moduleID = moduleID
        self.values = source.params
    }

    var title: String { module?.title ?? source.displayName }
    var canSearch: Bool { metadata?.search != nil }

    func start() async {
        guard items.isEmpty else { return }
        await reload()
    }

    func prepare() async -> Bool {
        if provider != nil, metadata != nil { return true }
        do {
            let loaded = try SourceManager.shared.provider(for: source)
            provider = loaded
            let info = try await loaded.loadMetadata()
            metadata = info
            module = info.allModules.first { $0.id == moduleID } ?? info.browseModules.first
            if filters.isEmpty, let module {
                for param in module.parameterList where param.type.lowercased() == "enumeration" {
                    filters.append(FilterChoice(name: param.name, title: param.title,
                                                options: param.options, value: param.value))
                    if let value = param.value, !value.isEmpty { values[param.name] = value }
                }
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func reload() async {
        guard await prepare(), let provider, let module else { return }
        isLoading = true
        error = nil
        page = 1
        do {
            let result: PageResult
            if searching, !keyword.isEmpty {
                result = try await provider.search(keyword: keyword, params: values, page: 1)
            } else {
                result = try await provider.browse(module: module, params: values, page: 1)
            }
            items = result.items
            hasMore = result.hasMore
            if let newFilters = result.filters, !newFilters.isEmpty {
                merge(filters: newFilters)
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func loadMore() async {
        guard hasMore, !isLoading, let provider, let module else { return }
        isLoading = true
        let next = page + 1
        do {
            let result: PageResult
            if searching, !keyword.isEmpty {
                result = try await provider.search(keyword: keyword, params: values, page: next)
            } else {
                result = try await provider.browse(module: module, params: values, page: next)
            }
            page = next
            items.append(contentsOf: result.items)
            hasMore = result.hasMore
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func apply(_ name: String, value: String) async {
        values[name] = value
        if let index = filters.firstIndex(where: { $0.name == name }) {
            filters[index].value = value
        }
        await reload()
    }

    func submitSearch(_ text: String) async {
        keyword = text
        searching = !text.trimmingCharacters(in: .whitespaces).isEmpty
        await reload()
    }

    private func merge(filters newFilters: [FilterChoice]) {
        for filter in newFilters {
            if let index = filters.firstIndex(where: { $0.name == filter.name }) {
                filters[index].options = filter.options
                filters[index].title = filter.title
            } else {
                filters.append(filter)
            }
        }
    }
}

struct BrowseView: View {
    @StateObject private var model: BrowseModel
    @EnvironmentObject private var settings: AppSettings
    @State private var searchText = ""

    init(source: ContentSource, moduleID: String) {
        _model = StateObject(wrappedValue: BrowseModel(source: source, moduleID: moduleID))
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: max(2, min(settings.values.posterColumns, 6)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.canSearch {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("在当前列表中搜索", text: $searchText)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.search)
                            .onSubmit { Task { await model.submitSearch(searchText) } }
                        if model.searching {
                            Button {
                                searchText = ""
                                Task { await model.submitSearch("") }
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if !model.filters.isEmpty {
                    filterBar
                }

                if let error = model.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).font(.system(size: 13)).foregroundStyle(.secondary)
                        HStack {
                            Button("重试") { Task { await model.reload() } }.buttonStyle(.bordered)
                            if let source = Optional(model.source) {
                                NavigationLink("配置内容源") { SourceSettingsView(source: source) }.buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                }

                if model.items.isEmpty && model.isLoading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                } else if model.items.isEmpty && !model.isLoading {
                    EmptyStateView(icon: "film",
                                   title: "暂无内容",
                                   message: "没有找到内容，试试其他分类或关键词。")
                        .frame(height: 260)
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(model.items) { item in
                            NavigationLink(value: DetailRoute(item: item, sourceID: model.source.id)) {
                                PosterCard(item: item)
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                if item.id == model.items.last?.id {
                                    Task { await model.loadMore() }
                                }
                            }
                        }
                    }
                    if model.hasMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .onAppear { Task { await model.loadMore() } }
                    } else if !model.items.isEmpty {
                        Text("没有更多内容了").font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.reload() }
        .task { await model.start() }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.filters) { filter in
                    filterMenu(for: filter)
                }
            }
        }
    }

    private func filterMenu(for filter: FilterChoice) -> some View {
        Menu {
            ForEach(filter.options) { option in
                Button {
                    apply(filter, option)
                } label: {
                    optionLabel(for: filter, option: option)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(label(for: filter))
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.card, in: Capsule())
        }
    }

    @ViewBuilder
    private func optionLabel(for filter: FilterChoice, option: EnumOption) -> some View {
        if selectedValue(for: filter) == option.value {
            Label(option.title, systemImage: "checkmark")
        } else {
            Text(option.title)
        }
    }

    private func selectedValue(for filter: FilterChoice) -> String {
        model.values[filter.name] ?? filter.value ?? ""
    }

    private func apply(_ filter: FilterChoice, _ option: EnumOption) {
        Task { await model.apply(filter.name, value: option.value) }
    }

    private func label(for filter: FilterChoice) -> String {
        let value = model.values[filter.name] ?? filter.value ?? ""
        if value.isEmpty { return filter.title }
        return filter.options.first { $0.value == value }?.title ?? filter.title
    }
}
