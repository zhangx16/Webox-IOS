//
//  DownloadManager.swift
//  WeBox for iOS
//
//  Offline downloads (收藏 → 下载). Direct media is fetched with ranged retries;
//  HLS playlists are expanded into segments, downloaded in order and concatenated
//  into a locally playable file.
//

import Foundation
import AVFoundation
import UIKit

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var records: [DownloadRecord] = []

    private var jobs: [String: Task<Void, Never>] = [:]
    private let kind = "download"
    private let maximumConcurrent = 2
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {
        load()
    }

    func load() {
        records = Store.shared.all(kind: kind).compactMap { entry in
            guard let data = entry.json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(DownloadRecord.self, from: data)
        }
        for index in records.indices where records[index].state == .downloading {
            records[index].state = .paused
        }
        persistAll()
    }

    var activeCount: Int { records.filter { $0.state == .downloading }.count }

    // MARK: - Enqueue

    @discardableResult
    func enqueue(title: String, subtitle: String?, poster: String?, link: String,
                 source: ContentSource, stream: StreamSource) throws -> DownloadRecord {
        guard stream.isLive != true else { throw ScriptError.message("直播暂不支持离线下载") }
        guard let url = stream.url, !url.isEmpty else {
            throw ScriptError.message("动态直播清单暂不支持下载")
        }
        guard url.lowercased().hasPrefix("http") else { throw ScriptError.message("下载地址无效") }
        guard records.count < 200 else { throw ScriptError.message("下载任务已满，请先删除不需要的任务") }
        if let existing = records.first(where: { $0.link == link && $0.streamURL == url && $0.state != .failed }) {
            return existing
        }
        let identifier = UUID().uuidString
        let record = DownloadRecord(id: identifier, title: title, subtitle: subtitle, poster: poster,
                                    sourceID: source.id, sourceName: source.displayName,
                                    link: link, streamURL: url, headers: stream.headers ?? [:],
                                    mime: stream.effectiveMIME, isLive: false, state: .queued,
                                    progress: 0, receivedBytes: 0, totalBytes: 0,
                                    fileName: nil, createdAt: Date(), errorMessage: nil)
        records.insert(record, at: 0)
        persist(record)
        startJob(identifier)
        return record
    }

    // MARK: - Control

    func pause(_ id: String) {
        jobs[id]?.cancel()
        jobs[id] = nil
        update(id) { record in
            if record.state == .downloading || record.state == .queued {
                record.state = .paused
            }
        }
    }

    func resume(_ id: String) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        guard record.state == .paused || record.state == .failed else { return }
        update(id) { $0.state = .queued; $0.errorMessage = nil }
        startJob(id)
    }

    func remove(_ id: String) {
        jobs[id]?.cancel()
        jobs[id] = nil
        if let record = records.first(where: { $0.id == id }), let fileName = record.fileName {
            try? FileManager.default.removeItem(at: Files.downloadsDirectory.appendingPathComponent(fileName))
        }
        records.removeAll { $0.id == id }
        Store.shared.remove(kind: kind, id: id)
    }

    func removeAll(completedOnly: Bool) {
        let targets = records.filter { !completedOnly || $0.state == .completed }
        for record in targets { remove(record.id) }
    }

    // MARK: - Jobs

    private func startJob(_ id: String) {
        guard jobs[id] == nil else { return }
        guard activeCount < maximumConcurrent else { return }
        beginBackgroundWindow()
        jobs[id] = Task { [weak self] in
            guard let self else { return }
            await self.run(id)
            await MainActor.run {
                self.jobs[id] = nil
                self.endBackgroundWindowIfIdle()
                self.pumpQueue()
            }
        }
    }

    private func pumpQueue() {
        for record in records where record.state == .queued && jobs[record.id] == nil {
            if activeCount >= maximumConcurrent { break }
            startJob(record.id)
        }
    }

    private func run(_ id: String) async {
        guard let record = records.first(where: { $0.id == id }),
              let url = URL(string: record.streamURL) else { return }
        update(id) { $0.state = .downloading; $0.errorMessage = nil }
        let fileName = "\(record.id).\(Self.fileExtension(for: record.streamURL, mime: record.mime))"
        let destination = Files.downloadsDirectory.appendingPathComponent(fileName)
        do {
            try await download(record: record, url: url, destination: destination, id: id)
            update(id) { item in
                item.state = .completed
                item.progress = 1
                item.fileName = fileName
            }
        } catch is CancellationError {
            update(id) { item in
                if item.state != .completed { item.state = .paused }
            }
        } catch {
            update(id) { item in
                item.state = .failed
                item.errorMessage = error.localizedDescription
            }
        }
    }

    private func download(record: DownloadRecord, url: URL, destination: URL, id: String) async throws {
        let isHLS = record.streamURL.lowercased().contains(".m3u8") || (record.mime ?? "").contains("mpegurl")
        if isHLS {
            try await downloadHLS(record: record, url: url, destination: destination, id: id)
        } else {
            try await downloadDirect(record: record, url: url, destination: destination, id: id)
        }
    }

    private func downloadDirect(record: DownloadRecord, url: URL, destination: URL, id: String) async throws {
        var existing: Int64 = 0
        if FileManager.default.fileExists(atPath: destination.path) {
            existing = Files.fileSize(destination)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        for (key, value) in record.headers { request.setValue(value, forHTTPHeaderField: key) }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ScriptError.message("下载请求失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）")
        }
        let total = http.expectedContentLength > 0 ? existing + http.expectedContentLength : 0
        let handle: FileHandle
        if existing > 0 && http.statusCode == 206 {
            handle = try FileHandle(forWritingTo: destination)
            try handle.seekToEnd()
        } else {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            handle = try FileHandle(forWritingTo: destination)
            existing = 0
        }
        defer { try? handle.close() }

        var received = existing
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var lastUpdate = Date.distantPast

        for try await byte in bytes {
            if Task.isCancelled { throw CancellationError() }
            buffer.append(byte)
            if buffer.count >= 1 << 16 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if Date().timeIntervalSince(lastUpdate) > 0.4 {
                    lastUpdate = Date()
                    report(id: id, received: received, total: total)
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        report(id: id, received: received, total: total > 0 ? total : received)
    }

    private func downloadHLS(record: DownloadRecord, url: URL, destination: URL, id: String) async throws {
        let text = try await fetchText(url, headers: record.headers)
        guard text.hasPrefix("#EXTM3U") else { throw ScriptError.message("无效或过大的 HLS 清单") }
        var playlist = text
        if playlist.contains("#EXT-X-STREAM-INF") {
            guard let variant = Self.firstVariant(in: playlist, base: url) else {
                throw ScriptError.message("没有可下载的播放线路")
            }
            playlist = try await fetchText(variant, headers: record.headers)
        }
        let segments = Self.segments(in: playlist, base: url)
        guard !segments.isEmpty else { throw ScriptError.message("清单没有可下载的分片") }
        guard segments.count <= 5000 else { throw ScriptError.message("下载分片过多") }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var received: Int64 = 0
        for (index, segment) in segments.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let data = try await fetchData(segment, headers: record.headers)
            guard !data.isEmpty else { throw ScriptError.message("分片内容为空") }
            try handle.write(contentsOf: data)
            received += Int64(data.count)
            report(id: id, received: received, total: 0, fraction: Double(index + 1) / Double(segments.count))
        }
    }

    // MARK: - HTTP helpers

    private func fetchText(_ url: URL, headers: [String: String]) async throws -> String {
        let data = try await fetchData(url, headers: headers, limit: 8 * 1024 * 1024)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private func fetchData(_ url: URL, headers: [String: String], limit: Int = 64 * 1024 * 1024) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ScriptError.message("分片请求失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）")
        }
        guard data.count <= limit else { throw ScriptError.message("清单过大") }
        return data
    }

    // MARK: - Playlist parsing

    static func firstVariant(in playlist: String, base: URL) -> URL? {
        let lines = playlist.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
            if index + 1 < lines.count {
                let next = lines[index + 1]
                if !next.hasPrefix("#") { return URL(string: next, relativeTo: base)?.absoluteURL }
            }
        }
        return nil
    }

    static func segments(in playlist: String, base: URL) -> [URL] {
        var result: [URL] = []
        for raw in playlist.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if let url = URL(string: line, relativeTo: base)?.absoluteURL {
                result.append(url)
            }
        }
        return result
    }

    static func fileExtension(for url: String, mime: String?) -> String {
        let lower = url.lowercased()
        if lower.contains(".m3u8") { return "ts" }
        if let mime {
            if mime.contains("mp4") { return "mp4" }
            if mime.contains("mpegurl") { return "ts" }
            if mime.contains("webm") { return "webm" }
        }
        if let ext = URL(string: url)?.pathExtension, !ext.isEmpty, ext.count <= 5 { return ext }
        return "mp4"
    }

    // MARK: - State

    private func report(id: String, received: Int64, total: Int64, fraction: Double? = nil) {
        update(id) { record in
            record.receivedBytes = received
            if total > 0 { record.totalBytes = total }
            if let fraction {
                record.progress = fraction
            } else if record.totalBytes > 0 {
                record.progress = min(1, Double(received) / Double(record.totalBytes))
            }
        }
    }

    private func update(_ id: String, _ mutation: (inout DownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        mutation(&records[index])
        persist(records[index])
    }

    private func persist(_ record: DownloadRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        Store.shared.put(kind: kind, id: record.id, json: String(decoding: data, as: UTF8.self),
                         num: record.createdAt.timeIntervalSince1970)
    }

    private func persistAll() {
        for record in records { persist(record) }
    }

    // MARK: - Background window

    private func beginBackgroundWindow() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "webox.download") { [weak self] in
            Task { @MainActor in self?.endBackgroundWindow() }
        }
    }

    private func endBackgroundWindowIfIdle() {
        if jobs.isEmpty { endBackgroundWindow() }
    }

    private func endBackgroundWindow() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
