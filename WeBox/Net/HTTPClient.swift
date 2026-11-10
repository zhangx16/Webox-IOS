//
//  HTTPClient.swift
//  WeBox for iOS
//
//  The transport behind Widget.http / context.http. The blocking entry point is used
//  from the script queue only (like the Android QuickJS host); UI code awaits the
//  async entry point instead.
//

import Foundation

struct HTTPOptions {
    var urlString: String = ""
    var method: String = "GET"
    var headers: [String: String] = [:]
    var query: [String: String]?
    var body: Data?
    var timeout: TimeInterval = 18
    var allowHTTP: Bool = false
    var base64Response: Bool = false
    var decodeContent: Bool = true
    var followRedirects: Bool = true
    var userAgent: String = "WeBox/0.3.0"
}

struct HTTPResult {
    var status: Int
    var url: String
    var headers: [String: String]
    var text: String
    var data: Data
}

enum HTTPError: LocalizedError {
    case invalidURL(String)
    case insecureURL
    case network(String)
    case timeout
    case cancelled
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "网页地址无效"
        case .insecureURL: return "此源不允许明文 HTTP 请求"
        case .network(let message): return message
        case .timeout: return "请求超时"
        case .cancelled: return "操作已取消"
        case .emptyResponse: return "请求返回空内容"
        }
    }
}

final class HTTPClient {
    static let shared = HTTPClient()

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    // MARK: - Blocking (script queue only)

    func perform(_ options: HTTPOptions) throws -> HTTPResult {
        let request = try buildRequest(options)
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<HTTPResult, Error> = .failure(HTTPError.network("请求失败"))
        let task = session.dataTask(with: request) { data, response, error in
            outcome = Self.outcome(data: data, response: response, error: error, options: options, fallbackURL: request.url)
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        switch outcome {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }

    // MARK: - Async (UI code)

    func performAsync(_ options: HTTPOptions) async throws -> HTTPResult {
        let request = try buildRequest(options)
        do {
            let (data, response) = try await session.data(for: request)
            switch Self.outcome(data: data, response: response, error: nil, options: options, fallbackURL: request.url) {
            case .success(let result): return result
            case .failure(let error): throw error
            }
        } catch let error as HTTPError {
            throw error
        } catch {
            throw Self.translate(error)
        }
    }

    // MARK: - Request

    private func buildRequest(_ options: HTTPOptions) throws -> URLRequest {
        guard var components = URLComponents(string: options.urlString) else {
            throw HTTPError.invalidURL(options.urlString)
        }
        if let query = options.query, !query.isEmpty {
            var items = components.queryItems ?? []
            items.append(contentsOf: query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) })
            components.queryItems = items
        }
        guard let url = components.url else { throw HTTPError.invalidURL(options.urlString) }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw HTTPError.invalidURL(url.absoluteString)
        }
        guard let host = url.host, !host.isEmpty else { throw HTTPError.invalidURL(url.absoluteString) }
        if url.user != nil || url.password != nil { throw HTTPError.invalidURL(url.absoluteString) }
        if scheme == "http" && !options.allowHTTP { throw HTTPError.insecureURL }

        var request = URLRequest(url: url)
        request.httpMethod = options.method
        request.timeoutInterval = max(1, min(options.timeout, 120))
        request.httpShouldHandleCookies = true
        var headers = options.headers
        if headers.keys.first(where: { $0.lowercased() == "user-agent" }) == nil {
            headers["User-Agent"] = options.userAgent
        }
        if headers.keys.first(where: { $0.lowercased() == "accept" }) == nil {
            headers["Accept"] = "*/*"
        }
        if headers.keys.first(where: { $0.lowercased() == "accept-language" }) == nil {
            headers["Accept-Language"] = "zh-CN,zh;q=0.9,en;q=0.8"
        }
        if !options.decodeContent && headers.keys.first(where: { $0.lowercased() == "accept-encoding" }) == nil {
            headers["Accept-Encoding"] = "identity"
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body = options.body {
            request.httpBody = body
            if headers.keys.first(where: { $0.lowercased() == "content-type" }) == nil {
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            }
        }
        return request
    }

    // MARK: - Response

    private static func outcome(data: Data?, response: URLResponse?, error: Error?,
                                options: HTTPOptions, fallbackURL: URL?) -> Result<HTTPResult, Error> {
        if let error {
            return .failure(translate(error))
        }
        guard let data, let response else {
            return .failure(HTTPError.emptyResponse)
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure(HTTPError.network("网站响应异常，请稍后重试。"))
        }
        var responseHeaders: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            let name = String(describing: key)
            if name.lowercased() == "set-cookie" { continue }
            responseHeaders[name.lowercased()] = String(describing: value)
        }
        let text: String
        if options.base64Response {
            text = data.base64EncodedString()
        } else {
            text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
        }
        return .success(HTTPResult(status: http.statusCode,
                                   url: http.url?.absoluteString ?? fallbackURL?.absoluteString ?? "",
                                   headers: responseHeaders,
                                   text: text,
                                   data: data))
    }

    static func translate(_ error: Error) -> HTTPError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return .timeout
            case NSURLErrorCancelled:
                return .cancelled
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return .network("域名解析失败，请检查网络后重试。")
            case NSURLErrorCannotConnectToHost:
                return .network("无法连接源站，请检查网络或稍后重试。")
            case NSURLErrorNetworkConnectionLost:
                return .network("连接被中断，可能与节点链路或源站有关，请稍后重试。")
            case NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorServerCertificateHasUnknownRoot:
                return .network("HTTPS 证书验证或 TLS 握手失败，请检查设备时间或节点链路。")
            case NSURLErrorNotConnectedToInternet:
                return .network("当前网络不可用，请检查网络连接。")
            default:
                break
            }
        }
        return .network("请求失败（\(error.localizedDescription)）")
    }

    static func friendlyMessage(for error: NSError) -> String {
        translate(error).localizedDescription
    }
}
