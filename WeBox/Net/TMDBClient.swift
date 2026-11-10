//
//  TMDBClient.swift
//  WeBox for iOS
//
//  Widget.tmdb / 影视资料. The Android build defaults to api.themoviedb.org with an
//  optional user API key and allows the built-in mirrors used by the app.
//

import Foundation

final class TMDBClient {
    static let shared = TMDBClient()

    private init() {}

    private var values: SettingsValues {
        guard let data = UserDefaults.standard.data(forKey: "webox.settings.v1"),
              let decoded = try? JSONDecoder().decode(SettingsValues.self, from: data) else {
            return SettingsValues()
        }
        return decoded
    }

    func call(api: String, params: [String: String]) throws -> Any {
        let path = api.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty, path.range(of: "^[A-Za-z0-9._/-]+$", options: .regularExpression) != nil,
              !path.contains("..") else {
            throw ScriptError.message("TMDB 路径无效")
        }
        let settings = values
        var base = settings.tmdbService.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "https://api.themoviedb.org/3" }
        guard base.lowercased().hasPrefix("https://") else {
            throw ScriptError.message("TMDB 地址需要使用 https")
        }
        while base.hasSuffix("/") { base.removeLast() }
        var options = HTTPOptions()
        options.urlString = "\(base)/\(path)"
        options.method = "GET"
        options.timeout = 20
        options.allowHTTP = false
        options.headers["Accept"] = "application/json"
        var query = params
        query["language"] = query["language"] ?? settings.catalogLanguage
        if base.contains("api.themoviedb.org") {
            guard !settings.tmdbAPIKey.isEmpty else {
                throw ScriptError.message("使用 TMDB 官方 API 时，请在设置中填写自己的 API Key")
            }
            query["api_key"] = settings.tmdbAPIKey
        }
        options.query = query
        let result = try HTTPClient.shared.perform(options)
        guard (200..<300).contains(result.status) else {
            throw ScriptError.message("TMDB 请求失败（HTTP \(result.status)）")
        }
        guard let data = result.text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            throw ScriptError.message("影视资料服务返回格式异常")
        }
        if let dictionary = object as? [String: Any], dictionary["success"] as? Bool == false {
            let message = dictionary["status_message"] as? String ?? "影视资料服务暂不可用"
            throw ScriptError.message(message)
        }
        return object
    }

    func posterURL(_ path: String?, size: String = "w500") -> String? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return path }
        return "https://image.tmdb.org/t/p/\(size)\(path.hasPrefix("/") ? path : "/" + path)"
    }
}
