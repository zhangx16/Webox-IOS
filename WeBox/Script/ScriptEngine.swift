//
//  ScriptEngine.swift
//  WeBox for iOS
//
//  JavaScriptCore host for WeBox Script 1.0 and XPTV (getConfig/getCards/getTracks/
//  getPlayinfo) scripts. The native bridge mirrors the Android QuickJS host:
//  every method listed here exists in the Android build with the same parameter
//  names, because runtime/widget.js and runtime/webox.js are shared verbatim.
//

import Foundation
import JavaScriptCore

enum ScriptError: LocalizedError {
    case message(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .unavailable(let text): return text
        }
    }
}

enum ScriptAssets {
    static func text(_ name: String) -> String? {
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.url(forResource: name, withExtension: nil, subdirectory: "runtime"),
            bundle.url(forResource: name, withExtension: nil),
            bundle.url(forResource: (name as NSString).deletingPathExtension,
                       withExtension: (name as NSString).pathExtension, subdirectory: "runtime")
        ]
        for case let url? in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        }
        return nil
    }
}

final class ScriptEngine: @unchecked Sendable {
    static let protocolVersion = "0.0.7"
    static let hostBuild = "0.1.64"

    let source: ContentSource

    private let queue: DispatchQueue
    var context: JSContext?
    var isXPTV = false
    private var ready = false
    var metadataCache: SourceMetadata?

    var pendingResults: [String: Result<JSValue, ScriptError>] = [:]
    var cancelled = false
    var invocationTimeout: TimeInterval = 60

    var handles: [String: Data] = [:]
    var handleSequence = 0
    var timers: [Int: (Date, JSValue)] = [:]
    var timerSequence = 0
    var settings: [String: String]

    /// Set while a media processor callback runs; binary handles are only legal there.
    var processorScope: String?

    init(source: ContentSource) {
        self.source = source
        self.settings = source.params
        self.queue = DispatchQueue(label: "webox.script.\(source.id)", qos: .userInitiated)
    }

    // MARK: - Public async API

    func prepare() async throws -> SourceMetadata {
        try await run {
            if let cached = self.metadataCache, self.ready { return cached }
            return try self.setup()
        }
    }

    func configure(with settings: [String: String]) async throws -> SourceMetadata {
        try await run {
            self.settings = settings
            return try self.configureLocked()
        }
    }

    func browse(params: [String: String], page: Int) async throws -> PageResult {
        try await run { try self.browseLocked(params: params, page: page) }
    }

    func search(keyword: String, params: [String: String], page: Int) async throws -> PageResult {
        try await run { try self.searchLocked(keyword: keyword, params: params, page: page) }
    }

    func detail(link: String) async throws -> MediaItem {
        try await run { try self.detailLocked(link: link) }
    }

    func play(link: String, purpose: String = "playback") async throws -> [StreamSource] {
        try await run { try self.playLocked(link: link, purpose: purpose) }
    }

    func metadata() -> SourceMetadata? { metadataCache }

    /// Called from the UI thread: only flips the flag the script polls through
    /// native.cancelled. Touching JSContext off its own queue is not safe.
    func cancel() {
        cancelled = true
    }

    func unload() {
        queue.sync {
            self.pendingResults.removeAll()
            self.handles.removeAll()
            self.timers.removeAll()
            self.context = nil
        }
    }

    // MARK: - Queue plumbing

    private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Setup

    private func setup() throws -> SourceMetadata {
        cancelled = false
        guard let cheerio = ScriptAssets.text("cheerio.js") else {
            throw ScriptError.unavailable("缺少运行资源：cheerio.js")
        }
        guard let widget = ScriptAssets.text("widget.js") else {
            throw ScriptError.unavailable("缺少运行资源：widget.js")
        }
        guard let webox = ScriptAssets.text("webox.js") else {
            throw ScriptError.unavailable("缺少运行资源：webox.js")
        }
        let xptv = ScriptAssets.text("xptv.js")

        let context = JSContext()!
        self.context = context
        installBridge(on: context)
        installAwaitHelpers(on: context)

        func evaluate(_ script: String, _ name: String) throws {
            guard context.evaluateScript(script, withSourceURL: URL(string: "webox://runtime/\(name)")) != nil else {
                let message = context.exception?.toString() ?? "脚本无效或过大"
                throw ScriptError.message(message)
            }
            if let exception = context.exception, !exception.isUndefined, !exception.isNull {
                context.exception = nil
                throw ScriptError.message(exception.toString())
            }
        }

        try evaluate(cheerio, "cheerio.js")
        try evaluate(widget, "widget.js")
        try evaluate(webox, "webox.js")
        if let xptv { try evaluate(xptv, "xptv.js") }

        metadataCache = nil
        guard let script = scriptBody() else {
            throw ScriptError.message("脚本不存在或已移除")
        }
        guard script.utf8.count <= 2 * 1024 * 1024 else {
            throw ScriptError.message("脚本超过 2 MB 限制")
        }
        try evaluate(script, "source.js")

        invocationTimeout = 60
        let hasWebox = context.evaluateScript("typeof __wbHasSource==='function' && __wbHasSource()")?.toBool() ?? false
        if hasWebox {
            isXPTV = false
            let json = evaluateString("__wbMetadata()")
            metadataCache = try decodeMetadata(json)
        } else {
            let hasXptv = context.evaluateScript("typeof getConfig==='function' || typeof getCards==='function'")?.toBool() ?? false
            guard hasXptv else {
                throw ScriptError.message("脚本缺少 WeBox.define 注册或受支持的接口")
            }
            isXPTV = true
            let attach = context.objectForKeyedSubscript("__weboxXptvAttach")
            let app = context.objectForKeyedSubscript("app")
            attach?.call(withArguments: [source.id, (app?.isUndefined ?? true) ? NSNull() : app!])
            let json = evaluateString("JSON.stringify(WidgetMetadata)")
            metadataCache = try decodeMetadata(json)
        }
        ready = true
        return metadataCache!
    }

    private func scriptBody() -> String? {
        if let text = source.scriptText, !text.isEmpty { return text }
        if let file = source.scriptFile {
            let url = Files.scriptsDirectory.appendingPathComponent(file)
            return try? String(contentsOf: url, encoding: .utf8)
        }
        return nil
    }

    private func configureLocked() throws -> SourceMetadata {
        guard ready, let context else { throw ScriptError.message("脚本会话已关闭") }
        invocationTimeout = 60
        if isXPTV {
            let config = settings["__xptv_config"] ?? "{}"
            let argument: [String: Any] = ["__xptv_config": config]
            _ = try callAwaiting("__weboxXptvConfigure", arguments: [argument])
        } else {
            let data = try JSONEncoder().encode(settings)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            _ = context.objectForKeyedSubscript("__wbSetSettings")?.call(withArguments: [json])
            _ = try callAwaiting("__wbConfigure", arguments: [])
        }
        let json = isXPTV ? evaluateString("JSON.stringify(WidgetMetadata)") : evaluateString("__wbMetadata()")
        let metadata = try decodeMetadata(json)
        metadataCache = metadata
        return metadata
    }

    private func decodeMetadata(_ json: String) throws -> SourceMetadata {
        guard let data = json.data(using: .utf8) else { throw ScriptError.message("脚本元数据无效") }
        do {
            let metadata = try JSONDecoder().decode(SourceMetadata.self, from: data)
            if let required = metadata.requiredVersion, !required.isEmpty, Self.compare(required, Self.protocolVersion) > 0 {
                throw ScriptError.message("脚本使用更高版本的接口：\(required)")
            }
            return metadata
        } catch let error as ScriptError {
            throw error
        } catch {
            throw ScriptError.message("脚本元数据无效")
        }
    }

    private static func compare(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    // MARK: - Invocation

    private func browseLocked(params: [String: String], page: Int) throws -> PageResult {
        var arguments = params
        arguments["__wb_page"] = String(page)
        let function = isXPTV ? "compatBrowse" : "__wbList"
        if isXPTV {
            arguments["page"] = String(page)
            arguments["offset"] = String((page - 1) * 30)
        }
        guard let value = try callAwaiting(function, arguments: [arguments]) else {
            throw ScriptError.message("模块没有返回内容")
        }
        return try decodePage(value)
    }

    private func searchLocked(keyword: String, params: [String: String], page: Int) throws -> PageResult {
        var arguments = params
        arguments["keyword"] = keyword
        arguments["__wb_page"] = String(page)
        let function = isXPTV ? "compatSearch" : "__wbSearch"
        if isXPTV {
            arguments["page"] = String(page)
        }
        guard let value = try callAwaiting(function, arguments: [arguments]) else {
            throw ScriptError.message("搜索没有返回内容")
        }
        return try decodePage(value)
    }

    private func detailLocked(link: String) throws -> MediaItem {
        let function = isXPTV ? "loadDetail" : "__wbDetail"
        guard let value = try callAwaiting(function, arguments: [link]) else {
            throw ScriptError.message("内容源没有返回详情")
        }
        if isXPTV {
            let json = stringify(value)
            guard let data = json.data(using: .utf8) else { throw ScriptError.message("内容源返回的详情格式不正确") }
            let items = (try? JSONDecoder().decode([MediaItem].self, from: data)) ?? []
            guard !items.isEmpty else { throw ScriptError.message("这个条目暂时没有详情") }
            let title = items.first?.title ?? "播放"
            var detail = MediaItem(id: link, type: "detail", title: title, link: link)
            detail.children = items
            detail.isLive = items.first?.isLive
            return detail
        }
        let json = stringify(value)
        guard let data = json.data(using: .utf8) else { throw ScriptError.message("内容源返回的详情格式不正确") }
        do {
            return try JSONDecoder().decode(MediaItem.self, from: data)
        } catch {
            throw ScriptError.message("内容源返回的详情格式不正确")
        }
    }

    private func playLocked(link: String, purpose: String) throws -> [StreamSource] {
        let function = isXPTV ? "loadResource" : "__wbPlay"
        let argument: [String: Any] = ["link": link, "__wbPurpose": purpose, "__weboxRefresh": "false"]
        guard let value = try callAwaiting(function, arguments: [argument]) else {
            throw ScriptError.message("内容源没有返回可用地址")
        }
        let json = stringify(value)
        guard let data = json.data(using: .utf8) else { throw ScriptError.message("播放地址格式无效") }
        do {
            let streams = try JSONDecoder().decode([StreamSource].self, from: data)
            guard !streams.isEmpty else { throw ScriptError.message("没有找到可用线路") }
            return streams
        } catch let error as ScriptError {
            throw error
        } catch {
            throw ScriptError.message("播放地址格式无效")
        }
    }

    private func decodePage(_ value: JSValue) throws -> PageResult {
        let json = stringify(value)
        guard let data = json.data(using: .utf8) else { throw ScriptError.message("模块返回了无法展示的内容格式") }
        struct RawPage: Decodable {
            var items: [MediaItem]?
            var hasMore: Bool?
            var filters: [ParamSpec]?
        }
        guard let page = try? JSONDecoder().decode(RawPage.self, from: data) else {
            throw ScriptError.message("模块返回了无法展示的内容格式")
        }
        let filters = (page.filters ?? []).map {
            FilterChoice(name: $0.name,
                         title: $0.title,
                         options: $0.options,
                         value: $0.value)
        }
        return PageResult(items: page.items ?? [], hasMore: page.hasMore ?? false, filters: filters.isEmpty ? nil : filters)
    }

    // MARK: - Media processor callbacks

    func mediaRequest(url: String, headers: [String: String], context extra: [String: Any]) async throws -> (String, [String: String]) {
        try await run {
            guard self.isXPTV == false else { return (url, headers) }
            guard let function = self.context?.objectForKeyedSubscript("__wbMediaRequest"),
                  !function.isUndefined else { return (url, headers) }
            self.processorScope = "request"
            defer { self.processorScope = nil }
            var payload: [String: Any] = ["url": url, "headers": headers]
            payload.merge(extra) { _, new in new }
            guard let value = try self.callAwaiting("__wbMediaRequest", arguments: [payload]) else {
                return (url, headers)
            }
            let dictionary = value.toDictionary() as? [String: Any] ?? [:]
            let newURL = dictionary["url"] as? String ?? url
            let newHeaders = dictionary["headers"] as? [String: String] ?? headers
            return (newURL, newHeaders)
        }
    }

    func mediaResponse(status: Int, headers: [String: String], body: Data) async throws -> Data {
        try await run {
            guard self.isXPTV == false else { return body }
            guard let function = self.context?.objectForKeyedSubscript("__wbMediaResponse"),
                  !function.isUndefined else { return body }
            self.processorScope = "response"
            defer { self.processorScope = nil }
            let handle = self.store(handle: body)
            let payload: [String: Any] = [
                "handle": handle,
                "statusCode": status,
                "headers": headers,
                "size": body.count
            ]
            guard let value = try self.callAwaiting("__wbMediaResponse", arguments: [payload]) else { return body }
            let dictionary = value.toDictionary() as? [String: Any] ?? [:]
            if let newHandle = dictionary["handle"] as? String, let data = self.handles[newHandle] {
                return data
            }
            if let base64 = dictionary["body"] as? String, let data = Data(base64Encoded: base64) {
                return data
            }
            return body
        }
    }

    // MARK: - JS helpers

    private func evaluateString(_ script: String) -> String {
        guard let context else { return "{}" }
        let value = context.evaluateScript(script)
        if let exception = context.exception, !exception.isUndefined, !exception.isNull {
            context.exception = nil
            Log.shared.error("JS 求值失败：\(exception.toString())")
            return "{}"
        }
        return value?.toString() ?? "{}"
    }

    private func stringify(_ value: JSValue) -> String {
        guard let json = value.context.objectForKeyedSubscript("JSON")?
            .objectForKeyedSubscript("stringify")?
            .call(withArguments: [value]), !json.isUndefined else {
            return "null"
        }
        return json.toString()
    }

    private func callAwaiting(_ function: String, arguments: [Any]) throws -> JSValue? {
        guard let context else { throw ScriptError.message("脚本会话已关闭") }
        guard let target = context.objectForKeyedSubscript(function), !target.isUndefined else {
            throw ScriptError.message("脚本没有定义函数：\(function)")
        }
        cancelled = false
        let result = target.call(withArguments: arguments)
        if let exception = context.exception, !exception.isUndefined, !exception.isNull {
            context.exception = nil
            throw ScriptError.message(exception.toString())
        }
        guard let result else { return nil }
        if isPromise(result) {
            return try awaitPromise(result)
        }
        return result
    }

    private func isPromise(_ value: JSValue) -> Bool {
        guard value.isObject, let context = value.context else { return false }
        return context.evaluateScript("(function(v){return !!(v && typeof v.then==='function');})")?
            .call(withArguments: [value])?.toBool() ?? false
    }

    private func awaitPromise(_ promise: JSValue) throws -> JSValue {
        guard let context else { throw ScriptError.message("脚本会话已关闭") }
        let token = UUID().uuidString
        pendingResults[token] = nil
        let helper = context.objectForKeyedSubscript("__wbHostAwait")
        helper?.call(withArguments: [promise, token])
        let deadline = Date().addingTimeInterval(invocationTimeout)
        while pendingResults[token] == nil {
            if cancelled {
                pendingResults[token] = nil
                throw ScriptError.message("操作已取消")
            }
            if Date() > deadline {
                pendingResults[token] = nil
                throw ScriptError.message("脚本执行超时，请重试或检查内容源")
            }
            _ = context.evaluateScript("void 0")
            drainTimers()
            Thread.sleep(forTimeInterval: 0.004)
        }
        let outcome = pendingResults.removeValue(forKey: token)!
        switch outcome {
        case .success(let value):
            if value.isUndefined { return JSValue(undefinedIn: context) }
            return value
        case .failure(let error):
            throw error
        }
    }

    private func drainTimers() {
        guard let context, !timers.isEmpty else { return }
        let now = Date()
        let due = timers.filter { $0.value.0 <= now }.map(\.key)
        for key in due {
            guard let (_, callback) = timers.removeValue(forKey: key) else { continue }
            _ = callback.call(withArguments: [])
            if let exception = context.exception, !exception.isUndefined, !exception.isNull {
                context.exception = nil
                Log.shared.error("定时器异常：\(exception.toString())")
            }
        }
    }

    private func installAwaitHelpers(on context: JSContext) {
        let resolve: @convention(block) (String, Bool, JSValue?) -> Void = { [weak self] token, ok, value in
            guard let self else { return }
            if ok {
                if let value, !value.isUndefined {
                    self.pendingResults[token] = .success(value)
                } else if let context = self.context {
                    self.pendingResults[token] = .success(JSValue(undefinedIn: context))
                } else {
                    self.pendingResults[token] = .failure(.message("脚本会话已关闭"))
                }
            } else {
                self.pendingResults[token] = .failure(.message(value?.toString() ?? "脚本执行失败"))
            }
        }
        context.setObject(resolve, forKeyedSubscript: "__nativeAwaitResolve" as NSString)

        let timer: @convention(block) (JSValue?, Double) -> Int = { [weak self] callback, delay in
            guard let self, let callback else { return 0 }
            self.timerSequence += 1
            let key = self.timerSequence
            self.timers[key] = (Date().addingTimeInterval(max(0, delay) / 1000), callback)
            return key
        }
        context.setObject(timer, forKeyedSubscript: "setTimeout" as NSString)
        let clear: @convention(block) (Int) -> Void = { [weak self] key in
            self?.timers.removeValue(forKey: key)
        }
        context.setObject(clear, forKeyedSubscript: "clearTimeout" as NSString)

        let log: @convention(block) (String?) -> Void = { raw in
            guard let raw, let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let level = object["level"] as? String ?? "info"
            let message = object["message"] as? String ?? ""
            switch level {
            case "error": Log.shared.error(message)
            case "warn": Log.shared.warn(message)
            case "debug": Log.shared.debug(message)
            default: Log.shared.info(message)
            }
        }
        context.setObject(log, forKeyedSubscript: "__nativeLog" as NSString)

        let cryptoResource: @convention(block) (String?) -> String = { _ in
            ScriptAssets.text("cryptojs.js") ?? ""
        }
        context.setObject(cryptoResource, forKeyedSubscript: "__nativeCryptoResource" as NSString)

        let bootstrap = """
        (function(){
          globalThis.__wbHostAwait = function(promise, token) {
            Promise.resolve(promise).then(function(value){ __nativeAwaitResolve(token, true, value); },
              function(error){ __nativeAwaitResolve(token, false, String((error && error.message) || error)); });
          };
          function unpack(raw) {
            var envelope = JSON.parse(raw);
            if (!envelope || envelope.ok !== true) { throw new Error((envelope && envelope.error) || '脚本接口调用失败'); }
            return envelope.result;
          }
          globalThis.__nativeSync = function(json) { return unpack(__nativeSyncRaw(String(json))); };
          globalThis.__nativeAsync = async function(json) { return unpack(__nativeAsyncRaw(String(json))); };
        })();
        """
        context.evaluateScript(bootstrap)
    }
}
