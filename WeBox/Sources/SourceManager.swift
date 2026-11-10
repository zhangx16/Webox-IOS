//
//  SourceManager.swift
//  WeBox for iOS
//
//  Import, detection and provider lifetime for content sources. Mirrors the Android
//  import flow: 链接或本地文件 · 自动识别 (JS / M3U / VOD / 合集).
//

import Foundation

@MainActor
final class SourceManager {
    static let shared = SourceManager()

    private var engines: [String: ScriptEngine] = [:]

    private init() {}

    // MARK: - Provider

    func provider(for source: ContentSource) throws -> ContentProvider {
        switch source.kind {
        case .javascript, .xptv:
            if let engine = engines[source.id] {
                return ScriptProvider(source: source, engine: engine)
            }
            let engine = ScriptEngine(source: source)
            engines[source.id] = engine
            return ScriptProvider(source: source, engine: engine)
        case .m3u:
            return try M3UProvider(source: source)
        case .vod:
            return try VODProvider(source: source)
        case .webRule:
            throw ScriptError.message("此版本暂不支持 JSON 网页 XPath 规则，请改用 JS 内容源或 VOD 接口")
        case .collection:
            throw ScriptError.message("来源合集暂不支持直接播放，请先导入其中的来源")
        }
    }

    func scriptEngine(for source: ContentSource) -> ScriptEngine? {
        engines[source.id]
    }

    func invalidate(sourceID: String) {
        engines[sourceID]?.unload()
        engines.removeValue(forKey: sourceID)
    }

    // MARK: - Import

    @discardableResult
    func importScript(text: String, name: String, origin: String? = nil) async throws -> ContentSource {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScriptError.message("脚本无效或过大")
        }
        guard text.utf8.count <= 2 * 1024 * 1024 else {
            throw ScriptError.message("脚本超过 2 MB 限制")
        }
        var draft = ContentSource(id: "draft.\(UUID().uuidString.prefix(6))", kind: .javascript,
                                  name: name, version: "1", icon: nil, scriptText: text,
                                  sourceURL: origin, payload: nil, params: [:], enabled: true,
                                  updatedAt: Date(), sizeBytes: text.utf8.count)
        let engine = ScriptEngine(source: draft)
        let metadata = try await engine.prepare()
        draft.kind = engine.isXPTV ? .xptv : .javascript

        let identifier: String
        if engine.isXPTV {
            identifier = "xptv.\(CryptoBridge.md5Hex(text).prefix(10))"
        } else {
            identifier = metadata.id.isEmpty ? "source.\(UUID().uuidString.prefix(8))" : metadata.id
        }
        let fileName = "\(identifier.replacingOccurrences(of: "/", with: "_")).js"
        let fileURL = Files.scriptsDirectory.appendingPathComponent(fileName)
        try text.write(to: fileURL, atomically: true, encoding: .utf8)

        if let existing = Library.shared.source(id: identifier) {
            draft.params = existing.params
            draft.updatedAt = Date()
        }

        let source = ContentSource(id: identifier,
                                   kind: draft.kind,
                                   name: metadata.title.isEmpty ? name : metadata.title,
                                   version: metadata.version,
                                   icon: metadata.icon,
                                   scriptFile: fileName,
                                   scriptText: nil,
                                   sourceURL: origin,
                                   payload: nil,
                                   params: draft.params,
                                   enabled: true,
                                   updatedAt: Date(),
                                   sizeBytes: text.utf8.count)
        engines[identifier]?.unload()
        engines[identifier] = engine
        Library.shared.upsert(source)
        return source
    }

    @discardableResult
    func importURL(_ raw: String) async throws -> ContentSource {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            throw ScriptError.message("请输入完整的 HTTP 或 HTTPS 链接")
        }
        var options = HTTPOptions()
        options.urlString = trimmed
        options.timeout = 25
        options.allowHTTP = true
        let response = try await HTTPClient.shared.performAsync(options)
        guard (200..<300).contains(response.status) else {
            throw ScriptError.message("规则下载失败（HTTP \(response.status)）")
        }
        let name = (host as NSString).deletingPathExtension
        return try await importText(response.text, name: name, origin: trimmed)
    }

    @discardableResult
    func importFile(_ url: URL) async throws -> ContentSource {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            throw ScriptError.message("无法读取文件")
        }
        guard data.count <= 4 * 1024 * 1024 else {
            throw ScriptError.message("文件超过 2 MB 限制")
        }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return try await importText(text, name: url.deletingPathExtension().lastPathComponent, origin: nil)
    }

    @discardableResult
    func importText(_ text: String, name: String, origin: String? = nil) async throws -> ContentSource {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#EXTM3U") {
            return try importM3U(text: trimmed, name: name)
        }
        if let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
           let api = object["api"] as? String, !api.isEmpty {
            return try importVOD(config: trimmed, name: (object["name"] as? String) ?? name)
        }
        if trimmed.hasPrefix("{") && (trimmed.contains("\"xpath\"") || trimmed.contains("\"rules\"")) {
            throw ScriptError.message("此版本暂不支持 JSON 网页 XPath 规则，请改用 JS 内容源")
        }
        return try await importScript(text: text, name: name, origin: origin)
    }

    @discardableResult
    func importM3U(text: String, name: String) throws -> ContentSource {
        let channels = try M3UParser.parse(text)
        guard !channels.isEmpty else { throw ScriptError.message("不是有效的 M3U 直播列表") }
        guard channels.count <= 10000 else { throw ScriptError.message("直播列表最多支持 10000 条线路") }
        let identifier = "m3u.\(CryptoBridge.md5Hex(text).prefix(10))"
        let source = ContentSource(id: identifier, kind: .m3u, name: name, version: "1",
                                   icon: channels.first(where: { $0.logo?.isEmpty == false })?.logo,
                                   scriptFile: nil, scriptText: nil, sourceURL: nil,
                                   payload: text, params: [:], enabled: true,
                                   updatedAt: Date(), sizeBytes: text.utf8.count)
        Library.shared.upsert(source)
        return source
    }

    @discardableResult
    func importVOD(config: String, name: String) throws -> ContentSource {
        guard let data = config.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let api = object["api"] as? String, !api.isEmpty else {
            throw ScriptError.message("VOD 接口不能从响应文件安装")
        }
        let identifier = "vod.\(CryptoBridge.md5Hex(api).prefix(10))"
        let source = ContentSource(id: identifier, kind: .vod, name: (object["name"] as? String) ?? name,
                                   version: "1", icon: object["icon"] as? String,
                                   scriptFile: nil, scriptText: nil, sourceURL: api,
                                   payload: config, params: [:], enabled: true,
                                   updatedAt: Date(), sizeBytes: config.utf8.count)
        Library.shared.upsert(source)
        return source
    }

    // MARK: - Update

    func refresh(_ source: ContentSource) async throws -> ContentSource {
        guard let raw = source.sourceURL, !raw.isEmpty else {
            throw ScriptError.message("这个内容源没有订阅地址")
        }
        var options = HTTPOptions()
        options.urlString = raw
        options.timeout = 25
        options.allowHTTP = true
        let response = try await HTTPClient.shared.performAsync(options)
        guard (200..<300).contains(response.status) else {
            throw ScriptError.message("规则下载失败（HTTP \(response.status)）")
        }
        invalidate(sourceID: source.id)
        Library.shared.remove(source)
        return try await importText(response.text, name: source.name, origin: raw)
    }
}
