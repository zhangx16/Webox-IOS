//
//  ScriptBridge.swift
//  WeBox for iOS
//
//  Native side of the Widget bridge. Method names and parameter keys are identical to
//  the Android host, so any script written for WeBox on Android runs unchanged.
//

import Foundation
import JavaScriptCore

enum CacheControl {
    static let kind = "meta"
    static let generationKey = "cache.generation"

    static var generation: Int {
        Int(Store.shared.get(kind: kind, id: generationKey) ?? "0") ?? 0
    }

    static func bump() {
        Store.shared.put(kind: kind, id: generationKey, json: String(generation + 1))
    }
}

extension ScriptEngine {
    // MARK: - Installation

    func installBridge(on context: JSContext) {
        let syncCall: @convention(block) (String?) -> String = { [weak self] raw in
            guard let self else { return Self.failure("脚本会话已关闭") }
            return self.handle(raw)
        }
        context.setObject(syncCall, forKeyedSubscript: "__nativeSyncRaw" as NSString)
        let asyncCall: @convention(block) (String?) -> String = { [weak self] raw in
            guard let self else { return Self.failure("脚本会话已关闭") }
            return self.handle(raw)
        }
        context.setObject(asyncCall, forKeyedSubscript: "__nativeAsyncRaw" as NSString)
    }

    // MARK: - Envelope

    static func success(_ json: String) -> String {
        encode(["ok": true, "result": json]) ?? "{\"ok\":false,\"error\":\"脚本接口调用失败\"}"
    }

    static func failure(_ message: String) -> String {
        encode(["ok": false, "error": message]) ?? "{\"ok\":false,\"error\":\"脚本接口调用失败\"}"
    }

    static func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func handle(_ raw: String?) -> String {
        guard let raw, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self.failure("参数格式无效")
        }
        let method = object["method"] as? String ?? ""
        let params = object["params"] as? [String: Any] ?? [:]
        do {
            let result = try dispatch(method, params)
            let json: String
            if let result {
                let encoded = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed, .withoutEscapingSlashes])
                json = String(data: encoded, encoding: .utf8) ?? "null"
            } else {
                json = "null"
            }
            return Self.success(json)
        } catch let error as ScriptError {
            return Self.failure(error.localizedDescription)
        } catch {
            return Self.failure(error.localizedDescription)
        }
    }

    // MARK: - Dispatch

    func dispatch(_ method: String, _ params: [String: Any]) throws -> Any? {
        switch method {
        case "ping":
            return "pong"
        case "runtime.capabilities":
            return ["compute": false, "html": true, "crypto": true, "memoryHls": true,
                     "mediaProcessor": true, "binary": true, "protocol": Self.protocolVersion]
        case "url.validate":
            return try validateURL(text(params["url"]), allowHTTP: bool(params["allowHttp"]) ?? false)
        case "url.resolve":
            return try resolveURL(text(params["url"]), base: text(params["base"]))
        case "url.origin":
            return try origin(text(params["url"]))
        case "request":
            return try performRequest(params)
        case "crypto.aes":
            return try CryptoBridge.aes(text: text(params["text"]),
                                        key: text(params["key"]),
                                        iv: text(params["iv"]),
                                        mode: text(params["mode"], "CBC"),
                                        padding: text(params["padding"], "PKCS7"),
                                        keyEncoding: params["keyEncoding"] as? String,
                                        ivEncoding: params["ivEncoding"] as? String,
                                        inputEncoding: params["inputEncoding"] as? String,
                                        outputEncoding: params["outputEncoding"] as? String,
                                        decrypt: bool(params["decrypt"]) ?? false)
        case "crypto.hash":
            return try CryptoBridge.hash(algorithm: text(params["algorithm"], "MD5"),
                                         text: text(params["text"]),
                                         inputEncoding: params["inputEncoding"] as? String,
                                         outputEncoding: params["outputEncoding"] as? String)
        case "crypto.hmac":
            return try CryptoBridge.hmac(algorithm: text(params["algorithm"], "SHA256"),
                                         text: text(params["text"]),
                                         key: text(params["key"]),
                                         keyEncoding: params["keyEncoding"] as? String,
                                         inputEncoding: params["inputEncoding"] as? String,
                                         outputEncoding: params["outputEncoding"] as? String)
        case "crypto.encode":
            return try CryptoBridge.encode(text: text(params["text"]),
                                           from: text(params["from"], "utf8"),
                                           to: text(params["to"], "base64"))
        case "crypto.random":
            let size = int(params["size"]) ?? 16
            let data = try CryptoBridge.randomData(size: size)
            return [UInt8](data)
        case "crypto.rsa":
            return try CryptoBridge.rsa(text: text(params["text"]),
                                        key: text(params["key"]),
                                        decrypt: bool(params["decrypt"]) ?? false)
        case "storage.getItem", "native.store.get":
            return Store.shared.scriptGet(scopedNamespace, key: text(params["key"]))
        case "storage.setItem", "native.store.set":
            Store.shared.scriptSet(scopedNamespace, key: text(params["key"]), value: text(params["value"]))
            return true
        case "storage.removeItem", "native.store.remove":
            Store.shared.scriptRemove(scopedNamespace, key: text(params["key"]))
            return true
        case "storage.keys":
            return Store.shared.scriptKeys(scopedNamespace)
        case "storage.clear":
            Store.shared.scriptClear(scopedNamespace)
            return true
        case "sharedCache.getItem":
            return Store.shared.sharedGet(try namespace(params), key: text(params["key"]))
        case "sharedCache.setItem":
            Store.shared.sharedSet(try namespace(params), key: text(params["key"]), value: text(params["value"]), ttl: 0)
            return true
        case "sharedCache.removeItem":
            Store.shared.sharedRemove(try namespace(params), key: text(params["key"]))
            return true
        case "sharedCache.keys":
            return Store.shared.sharedKeys(try namespace(params))
        case "native.cache.generation":
            return CacheControl.generation
        case "native.cache.seconds":
            return max(0, min(int(params["seconds"]) ?? 0, 86400))
        case "native.cancelled":
            return cancelled
        case "i18n":
            return text(params["value"])
        case "binary.size":
            return try binaryHandle(params).count
        case "binary.read":
            let data = try binaryHandle(params)
            let offset = max(0, int(params["offset"]) ?? 0)
            let length = min(int(params["length"]) ?? data.count, 65536)
            guard offset <= data.count else { throw ScriptError.message("二进制范围无效") }
            let end = min(data.count, offset + length)
            return data.subdata(in: offset..<end).base64EncodedString()
        case "binary.slice":
            let data = try binaryHandle(params)
            let offset = max(0, int(params["offset"]) ?? 0)
            guard offset <= data.count else { throw ScriptError.message("二进制范围无效") }
            let end = int(params["length"]).map { min(data.count, offset + $0) } ?? data.count
            return store(handle: data.subdata(in: offset..<end))
        case "binary.write":
            guard let handle = params["handle"] as? String, var data = handles[handle] else {
                throw ScriptError.message("二进制句柄无效或已失效")
            }
            guard let body = Data(base64Encoded: text(params["data"])) else {
                throw ScriptError.message("二进制数据无效")
            }
            guard body.count <= 65536 else { throw ScriptError.message("单次写入超过 64 KiB") }
            let offset = max(0, int(params["offset"]) ?? 0)
            guard offset <= data.count else { throw ScriptError.message("二进制范围无效") }
            data.replaceSubrange(offset..<min(data.count, offset + body.count), with: body)
            handles[handle] = data
            return true
        case "binary.patch":
            guard let handle = params["handle"] as? String, var data = handles[handle] else {
                throw ScriptError.message("二进制句柄无效或已失效")
            }
            guard let patches = params["patches"] as? [[String: Any]], !patches.isEmpty else {
                throw ScriptError.message("补丁数量无效")
            }
            guard patches.count <= 256 else { throw ScriptError.message("补丁数量无效") }
            for patch in patches {
                guard let body = Data(base64Encoded: text(patch["data"])) else {
                    throw ScriptError.message("补丁数据无效")
                }
                let offset = max(0, int(patch["offset"]) ?? 0)
                guard offset + body.count <= data.count else { throw ScriptError.message("补丁过大") }
                data.replaceSubrange(offset..<(offset + body.count), with: body)
            }
            handles[handle] = data
            return true
        case "binary.concat":
            guard let list = params["handles"] as? [String], !list.isEmpty, list.count <= 64 else {
                throw ScriptError.message("拼接数量无效")
            }
            var combined = Data()
            for handle in list {
                guard let data = handles[handle] else { throw ScriptError.message("二进制句柄无效或已失效") }
                combined.append(data)
            }
            return store(handle: combined)
        case "tmdb":
            return try TMDBClient.shared.call(api: text(params["api"]),
                                              params: params["params"] as? [String: String] ?? [:])
        case "compute":
            throw ScriptError.message("当前运行环境未提供独立计算能力")
        default:
            throw ScriptError.message("暂不支持的同步接口：\(method)")
        }
    }

    // MARK: - Helpers

    var scopedNamespace: String { source.id }

    private func text(_ value: Any?, _ fallback: String = "") -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return fallback
    }

    private func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return string == "true" || string == "1" }
        return nil
    }

    private func namespace(_ params: [String: Any]) throws -> String {
        let value = text(params["namespace"])
        guard !value.isEmpty, value.count <= 120,
              value.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw ScriptError.message("共享缓存命名空间无效")
        }
        return value
    }

    private func validateURL(_ raw: String, allowHTTP: Bool) throws -> String {
        guard let components = URLComponents(string: raw), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty else {
            throw ScriptError.message("网页地址无效")
        }
        if components.user != nil || components.password != nil {
            throw ScriptError.message("网站地址需要 HTTPS 且不能内嵌账号密码")
        }
        if scheme == "http" && !allowHTTP {
            throw ScriptError.message("此源不允许明文 HTTP 请求")
        }
        return components.url?.absoluteString ?? raw
    }

    private func resolveURL(_ raw: String, base: String) throws -> String {
        guard let baseURL = URL(string: base) else { throw ScriptError.message("网页地址无效") }
        if let absolute = URL(string: raw), absolute.scheme != nil { return absolute.absoluteString }
        guard let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL else {
            throw ScriptError.message("网页地址无效")
        }
        return resolved.absoluteString
    }

    private func origin(_ raw: String) throws -> String {
        guard let components = URLComponents(string: raw), let scheme = components.scheme,
              let host = components.host else {
            throw ScriptError.message("网页地址无效")
        }
        var origin = "\(scheme)://\(host)"
        if let port = components.port { origin += ":\(port)" }
        return origin
    }

    private func performRequest(_ params: [String: Any]) throws -> [String: Any] {
        let url = text(params["url"])
        var options = HTTPOptions()
        options.urlString = url
        options.method = text(params["method"], "GET").uppercased()
        options.query = params["params"] as? [String: String]
        options.timeout = (params["timeout"] as? NSNumber)?.doubleValue ?? 18
        options.allowHTTP = !(bool(params["httpsOnly"]) ?? true) || (metadataCache?.permitsPlainHTTP ?? false)
        options.base64Response = bool(params["base64Data"]) ?? false
        options.decodeContent = bool(params["decodable"]) ?? true
        if let headers = params["headers"] as? [String: Any] {
            var converted: [String: String] = [:]
            for (key, value) in headers { converted[key] = "\(value)" }
            options.headers = converted
        }
        if let body = params["data"] as? String {
            options.body = Data(body.utf8)
        }
        let result = try HTTPClient.shared.perform(options)
        return ["statusCode": result.status,
                "url": result.url,
                "headers": result.headers,
                "data": result.text]
    }

    // MARK: - Binary handles

    func store(handle data: Data) -> String {
        handleSequence += 1
        let key = String(handleSequence, radix: 36)
        handles[key] = data
        if handles.count > 32 { handles.removeValue(forKey: handles.keys.first { $0 != key } ?? key) }
        return key
    }

    private func binaryHandle(_ params: [String: Any]) throws -> Data {
        guard let handle = params["handle"] as? String, let data = handles[handle] else {
            throw ScriptError.message("二进制句柄无效或已失效")
        }
        return data
    }
}
