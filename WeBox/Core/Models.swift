//
//  Models.swift
//  WeBox for iOS
//
//  Data model mirroring the Android host's Widget/Script contract (protocol 0.0.7)
//  and the WeBox Script 1.0 metadata shape produced by runtime/webox.js.
//

import Foundation

// MARK: - Flexible JSON

/// A lenient JSON value used for script supplied objects (for example \c nativeField)
/// whose shape is intentionally open ended.
enum JSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value): return value == "true" || value == "1"
        default: return nil
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

// MARK: - Script metadata

struct EnumOption: Codable, Hashable, Identifiable {
    var title: String
    var value: String
    var id: String { value }
}

struct BelongTo: Codable, Hashable {
    var paramName: String
    var value: [String]
}

struct ParamSpec: Codable, Hashable, Identifiable {
    var name: String
    var title: String
    var type: String
    var required: Bool?
    var value: String?
    var enumOptions: [EnumOption]?
    var belongTo: [BelongTo]?
    var description: String?
    var placeholder: String?
    var sensitive: Bool?
    var nativeField: JSONValue?

    var id: String { name }

    var isPage: Bool { type == "page" }
    var isOffset: Bool { type == "offset" }
    var isEnabled: Bool { !isPage && !isOffset && type != "constant" }
    var isSecret: Bool {
        if let sensitive, sensitive { return true }
        return type == "secret"
    }
    var maxLength: Int? { nativeField?["maxLength"]?.intValue }
    var options: [EnumOption] { enumOptions ?? [] }
}

struct ModuleSpec: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var functionName: String
    var cacheDuration: Int?
    var type: String?
    var params: [ParamSpec]?

    var parameterList: [ParamSpec] { params ?? [] }
    var isStream: Bool { type == "stream" }
}

struct SourceMetadata: Codable, Hashable {
    var id: String
    var title: String
    var version: String
    var requiredVersion: String?
    var hostProtocol: String?
    var nativeApi: String?
    var catalogReady: Bool?
    var globalParams: [ParamSpec]?
    var detailCacheDuration: Int?
    var icon: String?
    var allowHttp: Bool?
    var modules: [ModuleSpec]?
    var search: ModuleSpec?

    var isReady: Bool { catalogReady ?? true }
    var allModules: [ModuleSpec] { modules ?? [] }
    var browseModules: [ModuleSpec] { allModules.filter { !$0.isStream } }
    var streamModules: [ModuleSpec] { allModules.filter { $0.isStream } }
    var settingsFields: [ParamSpec] { globalParams ?? [] }
    var permitsPlainHTTP: Bool { allowHttp ?? false }
}

// MARK: - Media content

struct MediaItem: Codable, Hashable, Identifiable {
    var id: String
    var type: String?
    var title: String
    var link: String?
    var posterPath: String?
    var description: String?
    var overview: String?
    var rating: String?
    var ratingSource: String?
    var isLive: Bool?
    var episodeGroup: String?
    var children: [MediaItem]?
    var playbackURL: String?

    init(id: String,
         type: String? = nil,
         title: String,
         link: String? = nil,
         posterPath: String? = nil,
         description: String? = nil,
         overview: String? = nil,
         rating: String? = nil,
         ratingSource: String? = nil,
         isLive: Bool? = nil,
         episodeGroup: String? = nil,
         children: [MediaItem]? = nil,
         playbackURL: String? = nil) {
        self.id = id
        self.type = type
        self.title = title
        self.link = link
        self.posterPath = posterPath
        self.description = description
        self.overview = overview
        self.rating = rating
        self.ratingSource = ratingSource
        self.isLive = isLive
        self.episodeGroup = episodeGroup
        self.children = children
        self.playbackURL = playbackURL
    }

    enum CodingKeys: String, CodingKey {
        case id, type, title, link, posterPath, description, overview
        case rating, ratingSource, isLive, episodeGroup, children, childItems, playbackURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        type = try? container.decode(String.self, forKey: .type)
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        link = try? container.decode(String.self, forKey: .link)
        posterPath = try? container.decode(String.self, forKey: .posterPath)
        description = try? container.decode(String.self, forKey: .description)
        overview = try? container.decode(String.self, forKey: .overview)
        if let value = try? container.decode(String.self, forKey: .rating) {
            rating = value
        } else if let number = try? container.decode(Double.self, forKey: .rating) {
            rating = number == number.rounded() ? String(Int(number)) : String(number)
        } else {
            rating = nil
        }
        ratingSource = try? container.decode(String.self, forKey: .ratingSource)
        isLive = try? container.decode(Bool.self, forKey: .isLive)
        episodeGroup = try? container.decode(String.self, forKey: .episodeGroup)
        playbackURL = try? container.decode(String.self, forKey: .playbackURL)
        // The Script 1.0 detail contract returns episodes as "childItems".
        if let decoded = try? container.decode([MediaItem].self, forKey: .children) {
            children = decoded
        } else if let decoded = try? container.decode([MediaItem].self, forKey: .childItems) {
            children = decoded
        } else {
            children = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(link, forKey: .link)
        try container.encodeIfPresent(posterPath, forKey: .posterPath)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(overview, forKey: .overview)
        try container.encodeIfPresent(rating, forKey: .rating)
        try container.encodeIfPresent(ratingSource, forKey: .ratingSource)
        try container.encodeIfPresent(isLive, forKey: .isLive)
        try container.encodeIfPresent(episodeGroup, forKey: .episodeGroup)
        try container.encodeIfPresent(children, forKey: .children)
        try container.encodeIfPresent(playbackURL, forKey: .playbackURL)
    }

    var displayTitle: String { title.isEmpty ? "未命名内容" : title }
    var isLiveContent: Bool { isLive ?? false }
    var poster: String? {
        guard let posterPath, !posterPath.isEmpty else { return nil }
        return posterPath
    }
    var childItems: [MediaItem] { children ?? [] }
    var ratingText: String? {
        guard let rating, !rating.isEmpty else { return nil }
        return rating
    }
}

struct FilterChoice: Codable, Hashable, Identifiable {
    var name: String
    var title: String
    var options: [EnumOption]
    var value: String?

    var id: String { name }
}

struct PageResult: Codable {
    var items: [MediaItem]
    var hasMore: Bool
    var filters: [FilterChoice]?

    static let empty = PageResult(items: [], hasMore: false, filters: nil)
}

struct StreamSource: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var url: String?
    var manifest: String?
    var baseUrl: String?
    var mime: String?
    var mimeType: String?
    var headers: [String: String]?
    var downloadable: Bool?
    var isLive: Bool?
    var sourceId: String?
    var processor: MediaProcessor?

    init(id: String,
         name: String,
         url: String? = nil,
         manifest: String? = nil,
         baseUrl: String? = nil,
         mime: String? = nil,
         mimeType: String? = nil,
         headers: [String: String]? = nil,
         downloadable: Bool? = nil,
         isLive: Bool? = nil,
         sourceId: String? = nil,
         processor: MediaProcessor? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.manifest = manifest
        self.baseUrl = baseUrl
        self.mime = mime
        self.mimeType = mimeType
        self.headers = headers
        self.downloadable = downloadable
        self.isLive = isLive
        self.sourceId = sourceId
        self.processor = processor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? "line"
        name = (try? container.decode(String.self, forKey: .name)) ?? "线路"
        url = try? container.decode(String.self, forKey: .url)
        manifest = try? container.decode(String.self, forKey: .manifest)
        baseUrl = try? container.decode(String.self, forKey: .baseUrl)
        mime = try? container.decode(String.self, forKey: .mime)
        mimeType = try? container.decode(String.self, forKey: .mimeType)
        headers = try? container.decode([String: String].self, forKey: .headers)
        downloadable = try? container.decode(Bool.self, forKey: .downloadable)
        isLive = try? container.decode(Bool.self, forKey: .isLive)
        sourceId = try? container.decode(String.self, forKey: .sourceId)
        processor = try? container.decode(MediaProcessor.self, forKey: .processor)
    }

    var effectiveMIME: String? { (mime ?? mimeType).flatMap { $0.isEmpty ? nil : $0 } }
    var resolvedURL: String? {
        if let url, !url.isEmpty { return url }
        if let manifest, let baseUrl { return "memoryhls://\(manifest.count)" } // in-memory playlists are handled by PlaybackCoordinator
        return nil
    }
    var supportsDownload: Bool { downloadable ?? true }
}

struct MediaProcessor: Codable, Hashable {
    var request: String?
    var response: String?
    var context: [String: JSONValue]?
}

// MARK: - Sources

enum SourceKind: String, Codable, CaseIterable, Identifiable {
    case javascript
    case xptv
    case m3u
    case vod
    case webRule
    case collection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .javascript: return "JS 内容源"
        case .xptv: return "XPTV 脚本"
        case .m3u: return "M3U 直播源"
        case .vod: return "VOD 内容源"
        case .webRule: return "JSON 网页源"
        case .collection: return "来源合集"
        }
    }
}

struct ContentSource: Codable, Hashable, Identifiable {
    var id: String
    var kind: SourceKind
    var name: String
    var version: String
    var icon: String?
    var scriptFile: String?
    var scriptText: String?
    var sourceURL: String?
    var payload: String?
    var params: [String: String]
    var enabled: Bool
    var updatedAt: Date
    var sizeBytes: Int?

    var displayName: String { name.isEmpty ? "未命名来源" : name }
    var isScript: Bool { kind == .javascript || kind == .xptv }
    var isSearchable: Bool { kind != .m3u && kind != .collection }

    static func makeID(kind: SourceKind, name: String) -> String {
        "\(kind.rawValue).\(UUID().uuidString.prefix(8))"
    }
}

// MARK: - Library

struct FavoriteEntry: Codable, Hashable, Identifiable {
    var id: String { link }
    var link: String
    var item: MediaItem
    var sourceID: String
    var sourceName: String
    var addedAt: Date
}

struct BrowseHistoryEntry: Codable, Hashable, Identifiable {
    var id: String { "\(sourceID)|\(link)" }
    var link: String
    var item: MediaItem
    var sourceID: String
    var sourceName: String
    var watchedAt: Date
}

struct PlaybackProgress: Codable, Hashable {
    var link: String
    var sourceID: String
    var position: Double
    var duration: Double
    var updatedAt: Date

    var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

enum DownloadState: String, Codable {
    case queued, downloading, paused, completed, failed

    var title: String {
        switch self {
        case .queued: return "等待下载"
        case .downloading: return "下载中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "下载失败"
        }
    }
}

struct DownloadRecord: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var subtitle: String?
    var poster: String?
    var sourceID: String
    var sourceName: String
    var link: String
    var streamURL: String
    var headers: [String: String]
    var mime: String?
    var isLive: Bool
    var state: DownloadState
    var progress: Double
    var receivedBytes: Int64
    var totalBytes: Int64
    var fileName: String?
    var createdAt: Date
    var errorMessage: String?

    var localURL: URL? {
        guard let fileName else { return nil }
        let url = Files.downloadsDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - Files

enum Files {
    static var root: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WeBox", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var scriptsDirectory: URL { directory("Scripts") }
    static var downloadsDirectory: URL { directory("Downloads") }
    static var cacheDirectory: URL { directory("Cache") }
    static var imageCacheDirectory: URL { directory("Cache/Images") }

    static func directory(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}
