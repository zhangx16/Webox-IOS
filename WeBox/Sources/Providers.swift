//
//  Providers.swift
//  WeBox for iOS
//
//  Content source implementations. Script sources run through ScriptEngine; the
//  M3U and AppleCMS style VOD sources are native adapters that expose the same
//  metadata/browse/detail/play surface as a script.
//

import Foundation

protocol ContentProvider {
    var source: ContentSource { get }
    func loadMetadata() async throws -> SourceMetadata
    func browse(module: ModuleSpec, params: [String: String], page: Int) async throws -> PageResult
    func search(keyword: String, params: [String: String], page: Int) async throws -> PageResult
    func detail(link: String) async throws -> MediaItem
    func play(link: String, purpose: String) async throws -> [StreamSource]
}

// MARK: - Script

final class ScriptProvider: ContentProvider {
    let source: ContentSource
    let engine: ScriptEngine

    init(source: ContentSource, engine: ScriptEngine) {
        self.source = source
        self.engine = engine
    }

    func loadMetadata() async throws -> SourceMetadata {
        let metadata = try await engine.prepare()
        if metadata.isReady { return metadata }
        return try await engine.configure(with: source.params)
    }

    func configure(_ params: [String: String]) async throws -> SourceMetadata {
        try await engine.configure(with: params)
    }

    func browse(module: ModuleSpec, params: [String: String], page: Int) async throws -> PageResult {
        try await engine.browse(params: params, page: page)
    }

    func search(keyword: String, params: [String: String], page: Int) async throws -> PageResult {
        try await engine.search(keyword: keyword, params: params, page: page)
    }

    func detail(link: String) async throws -> MediaItem {
        try await engine.detail(link: link)
    }

    func play(link: String, purpose: String) async throws -> [StreamSource] {
        try await engine.play(link: link, purpose: purpose)
    }
}

// MARK: - M3U live playlist

struct M3UChannel: Codable, Hashable {
    var name: String
    var url: String
    var group: String
    var logo: String?
}

final class M3UProvider: ContentProvider {
    let source: ContentSource
    private let channels: [M3UChannel]

    init(source: ContentSource) throws {
        self.source = source
        guard let payload = source.payload else { throw ScriptError.message("直播源已移除") }
        channels = try M3UParser.parse(payload)
        guard !channels.isEmpty else { throw ScriptError.message("不是有效的 M3U 直播列表") }
    }

    func loadMetadata() async throws -> SourceMetadata {
        var groups: [String] = []
        for channel in channels where !groups.contains(channel.group) {
            groups.append(channel.group)
        }
        let modules = groups.map { group in
            ModuleSpec(id: "group:\(group)", title: group, functionName: "browse", cacheDuration: 0, type: nil, params: [])
        }
        return SourceMetadata(id: source.id, title: source.name, version: source.version,
                              requiredVersion: "0.0.1", hostProtocol: "m3u", nativeApi: "1.0",
                              catalogReady: true, globalParams: [], detailCacheDuration: 60,
                              icon: source.icon, allowHttp: true, modules: modules,
                              search: ModuleSpec(id: "search", title: "搜索", functionName: "search",
                                                 cacheDuration: 0, type: nil, params: []))
    }

    func browse(module: ModuleSpec, params: [String: String], page: Int) async throws -> PageResult {
        let group = module.id.hasPrefix("group:") ? String(module.id.dropFirst(6)) : module.title
        let list = channels.filter { $0.group == group }
        return PageResult(items: list.map { self.item($0) }, hasMore: false, filters: nil)
    }

    func search(keyword: String, params: [String: String], page: Int) async throws -> PageResult {
        let word = keyword.lowercased()
        let list = channels.filter { $0.name.lowercased().contains(word) }
        return PageResult(items: list.map { self.item($0) }, hasMore: false, filters: nil)
    }

    func detail(link: String) async throws -> MediaItem {
        guard let channel = channels.first(where: { $0.url == link }) else {
            throw ScriptError.message("这条直播线路暂不可用")
        }
        var media = self.item(channel)
        media.children = [MediaItem(id: channel.url, type: "url", title: "直播", link: channel.url, isLive: true)]
        return media
    }

    func play(link: String, purpose: String) async throws -> [StreamSource] {
        guard channels.contains(where: { $0.url == link }) else {
            throw ScriptError.message("这条直播线路暂不可用")
        }
        return [StreamSource(id: "live", name: "直播", url: link, manifest: nil, baseUrl: nil,
                             mime: nil, mimeType: nil, headers: [:], downloadable: false,
                             isLive: true, sourceId: source.id, processor: nil)]
    }

    private func item(_ channel: M3UChannel) -> MediaItem {
        MediaItem(id: channel.url, type: "url", title: channel.name, link: channel.url,
                  posterPath: channel.logo, description: channel.group, overview: nil,
                  rating: nil, ratingSource: nil, isLive: true, episodeGroup: channel.group,
                  children: nil, playbackURL: channel.url)
    }
}

enum M3UParser {
    static func parse(_ text: String) throws -> [M3UChannel] {
        var channels: [M3UChannel] = []
        var pending: (name: String, group: String, logo: String?)?
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTM3U") { continue }
            if line.hasPrefix("#EXTINF") {
                let info = parseInfo(line)
                pending = (info.name, info.group, info.logo)
                continue
            }
            if line.hasPrefix("#") { continue }
            guard let pending else { continue }
            channels.append(M3UChannel(name: pending.name, url: line,
                                       group: pending.group, logo: pending.logo))
            pending = nil
        }
        return channels
    }

    private static func parseInfo(_ line: String) -> (name: String, group: String, logo: String?) {
        var group = "未分组"
        var logo: String?
        if let range = line.range(of: "group-title=\"") {
            let rest = line[range.upperBound...]
            if let end = rest.firstIndex(of: "\"") { group = String(rest[..<end]) }
        }
        if let range = line.range(of: "tvg-logo=\"") {
            let rest = line[range.upperBound...]
            if let end = rest.firstIndex(of: "\"") { logo = String(rest[..<end]) }
        }
        if let comma = line.range(of: ",", options: .backwards) {
            return (String(line[comma.upperBound...]).trimmingCharacters(in: .whitespaces), group, logo)
        }
        if let comma = line.lastIndex(of: ",") {
            return (String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespaces), group, logo)
        }
        return ("直播频道", group, logo)
    }
}

// MARK: - AppleCMS style VOD API

final class VODProvider: ContentProvider {
    let source: ContentSource
    private let api: String
    private let name: String

    init(source: ContentSource) throws {
        self.source = source
        guard let payload = source.payload, let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let api = object["api"] as? String, !api.isEmpty else {
            throw ScriptError.message("VOD 接口地址无效")
        }
        guard let components = URLComponents(string: api), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", components.user == nil, components.password == nil else {
            throw ScriptError.message("VOD 地址不支持内嵌用户名密码")
        }
        self.api = api
        self.name = object["name"] as? String ?? source.name
    }

    func loadMetadata() async throws -> SourceMetadata {
        let json = try await request(["ac": "list"])
        var modules: [ModuleSpec] = []
        for type in json["class"] as? [[String: Any]] ?? [] {
            let id = "\(type["type_id"] ?? "")"
            let title = type["type_name"] as? String ?? "分类"
            modules.append(ModuleSpec(id: "type:\(id)", title: title, functionName: "browse",
                                      cacheDuration: 300, type: nil, params: []))
        }
        if modules.isEmpty {
            modules = [ModuleSpec(id: "type:all", title: "全部", functionName: "browse", cacheDuration: 300, type: nil, params: [])]
        }
        return SourceMetadata(id: source.id, title: name, version: source.version,
                              requiredVersion: "0.0.1", hostProtocol: "vod", nativeApi: "1.0",
                              catalogReady: true, globalParams: [], detailCacheDuration: 60,
                              icon: source.icon, allowHttp: true, modules: modules,
                              search: ModuleSpec(id: "search", title: "搜索", functionName: "search",
                                                 cacheDuration: 0, type: nil, params: []))
    }

    func browse(module: ModuleSpec, params: [String: String], page: Int) async throws -> PageResult {
        let type = module.id.hasPrefix("type:") ? String(module.id.dropFirst(5)) : ""
        var query = ["ac": "videolist", "pg": String(max(1, page))]
        if !type.isEmpty && type != "all" { query["t"] = type }
        let json = try await request(query)
        let list = json["list"] as? [[String: Any]] ?? []
        let pageCount = int(json["pagecount"]) ?? 1
        return PageResult(items: list.compactMap(item), hasMore: page < pageCount, filters: nil)
    }

    func search(keyword: String, params: [String: String], page: Int) async throws -> PageResult {
        let json = try await request(["ac": "videolist", "wd": keyword, "pg": String(max(1, page))])
        let list = json["list"] as? [[String: Any]] ?? []
        let pageCount = int(json["pagecount"]) ?? 1
        var result = PageResult(items: list.compactMap(item), hasMore: page < pageCount, filters: nil)
        if result.items.isEmpty {
            let suggestions = try await request(["ac": "videolist", "wd": keyword, "pg": "1"])
            result.items = (suggestions["list"] as? [[String: Any]] ?? []).compactMap(item)
        }
        return result
    }

    func detail(link: String) async throws -> MediaItem {
        guard let id = link.split(separator: "|").first.map(String.init), !id.isEmpty else {
            throw ScriptError.message("VOD 影片缺少 ID")
        }
        let json = try await request(["ac": "videolist", "ids": id])
        guard let row = (json["list"] as? [[String: Any]])?.first, var media = self.item(row) else {
            throw ScriptError.message("VOD 服务没有返回该影片")
        }
        let episodes = parsePlayURL(row["vod_play_url"] as? String ?? "")
        if episodes.isEmpty {
            media.children = []
        } else {
            media.children = episodes.map {
                MediaItem(id: $0.name, type: "url", title: $0.name,
                          link: "\(id)|\($0.name)|\($0.url)", isLive: false)
            }
        }
        return media
    }

    func play(link: String, purpose: String) async throws -> [StreamSource] {
        let parts = link.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { throw ScriptError.message("播放地址暂不可用") }
        return [StreamSource(id: "vod", name: parts[1], url: parts[2], manifest: nil, baseUrl: nil,
                             mime: nil, mimeType: nil, headers: [:], downloadable: true,
                             isLive: false, sourceId: source.id, processor: nil)]
    }

    private func item(_ row: [String: Any]) -> MediaItem? {
        guard let id = int(row["vod_id"]), !"\(id)".isEmpty else { return nil }
        let title = row["vod_name"] as? String ?? "未命名影片"
        return MediaItem(id: "\(id)", type: "detail", title: title,
                         link: "\(id)|", posterPath: row["vod_pic"] as? String,
                         description: row["vod_remarks"] as? String,
                         overview: (row["vod_content"] as? String)?.strippedHTML,
                         rating: row["vod_score"] as? String, ratingSource: "源评分",
                         isLive: false, episodeGroup: nil, children: nil, playbackURL: nil)
    }

    private func parsePlayURL(_ text: String) -> [(name: String, url: String)] {
        var result: [(String, String)] = []
        for group in text.components(separatedBy: "#") {
            let parts = group.components(separatedBy: "$")
            guard parts.count >= 2 else { continue }
            let url = parts[1].trimmingCharacters(in: .whitespaces)
            guard url.lowercased().hasPrefix("http") else { continue }
            let name = parts[0].isEmpty ? "第 \(result.count + 1) 集" : parts[0]
            if result.contains(where: { $0.1 == url }) { continue }
            result.append((name, url))
        }
        return result
    }

    private func request(_ query: [String: String]) async throws -> [String: Any] {
        var options = HTTPOptions()
        options.urlString = api
        options.method = "GET"
        options.timeout = 20
        options.allowHTTP = true
        options.query = query
        let result = try await HTTPClient.shared.performAsync(options)
        guard (200..<300).contains(result.status) else {
            throw ScriptError.message("VOD 服务响应异常（HTTP \(result.status)）")
        }
        guard let data = result.text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScriptError.message("VOD 服务未能完成请求")
        }
        return object
    }

    private func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

extension String {
    var strippedHTML: String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
