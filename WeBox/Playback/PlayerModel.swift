//
//  PlayerModel.swift
//  WeBox for iOS
//
//  Playback session: stream selection, headers, in-memory HLS manifests, gestures
//  state, resume position and the 播放设置 options exposed by the Android player.
//

import Foundation
import AVFoundation
import MediaPlayer
import UIKit

struct PlaybackRequest: Identifiable {
    var id = UUID()
    var item: MediaItem
    var source: ContentSource
    var episodes: [MediaItem]
    var index: Int
    var streams: [StreamSource]
    var engine: PlaybackEngine
    var loader: ((MediaItem) async throws -> [StreamSource])?
}

@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var streams: [StreamSource] = []
    @Published var streamIndex: Int = 0
    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var buffered: Double = 0
    @Published var aspect: AspectMode = .fit
    @Published var speed: Double = 1.0
    @Published var locked = false
    @Published var controlsVisible = true
    @Published var errorMessage: String?
    @Published var isLoading = true
    @Published var episodeIndex: Int
    @Published var episodes: [MediaItem]

    let player = AVPlayer()
    let item: MediaItem
    let source: ContentSource
    var onLoadStreams: ((MediaItem, MediaItem) async throws -> [StreamSource])?

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var temporaryFile: URL?
    private var resumePosition: Double = 0
    private var lastSaved: Date = .distantPast
    private var seekPreview: Double?

    init(request: PlaybackRequest) {
        item = request.item
        source = request.source
        let list = request.episodes.isEmpty ? [request.item] : request.episodes
        episodes = list
        episodeIndex = min(max(0, request.index), max(0, list.count - 1))
        streams = request.streams
        aspect = AppSettings.shared.values.defaultAspect
        speed = AppSettings.shared.values.defaultSpeed
        resumePosition = Library.shared.progress(for: link(for: currentEpisode))?.position ?? 0
        if let loader = request.loader {
            onLoadStreams = { episode, _ in try await loader(episode) }
        }
        configureAudioSession()
        observePlayer()
    }

    var currentEpisode: MediaItem {
        episodes.indices.contains(episodeIndex) ? episodes[episodeIndex] : item
    }

    var currentStream: StreamSource? {
        streams.indices.contains(streamIndex) ? streams[streamIndex] : streams.first
    }

    var title: String {
        if episodes.count > 1, currentEpisode.id != item.id {
            return "\(item.title) · \(currentEpisode.title)"
        }
        return item.title
    }

    var isLive: Bool { currentStream?.isLive ?? item.isLiveContent }

    private func link(for episode: MediaItem) -> String {
        episode.link ?? episode.id
    }

    // MARK: - Lifecycle

    func start() async {
        guard currentStream != nil else {
            errorMessage = "没有找到可用线路"
            isLoading = false
            return
        }
        await loadCurrentStream(startAt: resumePosition)
    }

    func stop() {
        saveProgress(force: true)
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        statusObservation?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
    }

    // MARK: - Loading

    func selectStream(_ index: Int) async {
        guard streams.indices.contains(index), index != streamIndex else { return }
        streamIndex = index
        await loadCurrentStream(startAt: position)
    }

    private func loadCurrentStream(startAt seconds: Double) async {
        guard let stream = currentStream else { return }
        isLoading = true
        errorMessage = nil
        do {
            var urlString = stream.url ?? ""
            var headers = stream.headers ?? [:]
            if stream.url == nil, let manifest = stream.manifest, let base = stream.baseUrl,
               let baseURL = URL(string: base) {
                let rewritten = ManifestRewriter.absolutize(manifest, base: baseURL)
                let file = Files.cacheDirectory.appendingPathComponent("live-\(UUID().uuidString).m3u8")
                try rewritten.write(to: file, atomically: true, encoding: .utf8)
                temporaryFile = file
                urlString = file.absoluteString
            }
            if let engine = SourceManager.shared.scriptEngine(for: source),
               stream.processor?.request != nil {
                let rewritten = try await engine.mediaRequest(url: urlString, headers: headers, context: [:])
                urlString = rewritten.0
                headers = rewritten.1
            }
            guard let url = URL(string: urlString) else {
                throw ScriptError.message("播放地址暂不可用")
            }
            let asset = PlayerItemFactory.makeAsset(url: url, headers: headers)
            let newItem = AVPlayerItem(asset: asset)
            newItem.preferredForwardBufferDuration = Double(AppSettings.shared.values.bufferSeconds)
            player.replaceCurrentItem(with: newItem)
            if seconds > 5 {
                let target = CMTime(seconds: seconds, preferredTimescale: 600)
                await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player.play()
            player.rate = Float(speed)
            isPlaying = true
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
            player.rate = Float(speed)
        }
        isPlaying.toggle()
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        position = clamped
        seekPreview = nil
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ delta: Double) {
        seek(to: position + delta)
    }

    func previewSeek(to seconds: Double) {
        seekPreview = seconds
    }

    var previewPosition: Double { seekPreview ?? position }

    func setSpeed(_ value: Double) {
        speed = value
        if isPlaying { player.rate = Float(value) }
    }

    func cycleAspect() {
        aspect = aspect.next()
    }

    func beginTemporarySpeed(_ value: Double = 2.0) {
        guard isPlaying else { return }
        player.rate = Float(value)
    }

    func endTemporarySpeed() {
        player.rate = isPlaying ? Float(speed) : 0
    }

    func nextEpisode() async {
        guard episodeIndex + 1 < episodes.count else { return }
        saveProgress(force: true)
        episodeIndex += 1
        await reloadEpisode()
    }

    func previousEpisode() async {
        guard episodeIndex > 0 else { return }
        saveProgress(force: true)
        episodeIndex -= 1
        await reloadEpisode()
    }

    func selectEpisode(_ index: Int) async {
        guard episodes.indices.contains(index) else { return }
        saveProgress(force: true)
        episodeIndex = index
        await reloadEpisode()
    }

    private func reloadEpisode() async {
        guard let onLoadStreams else {
            errorMessage = "无法恢复到原播放位置"
            return
        }
        isLoading = true
        do {
            let loaded = try await onLoadStreams(currentEpisode, item)
            guard !loaded.isEmpty else { throw ScriptError.message("这个条目没有提供可播放地址") }
            streams = loaded
            streamIndex = 0
            resumePosition = 0
            await loadCurrentStream(startAt: 0)
            Library.shared.recordBrowse(item, source: source)
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    // MARK: - Observation

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.position = time.seconds.isFinite ? time.seconds : 0
                if let item = self.player.currentItem {
                    let total = item.duration.seconds
                    if total.isFinite, total > 0 { self.duration = total }
                    if let range = item.loadedTimeRanges.first?.timeRangeValue {
                        self.buffered = range.start.seconds + range.duration.seconds
                    }
                    if let error = item.error {
                        self.errorMessage = PlayerModel.describe(error)
                    }
                }
                self.isPlaying = self.player.rate > 0
                self.saveProgress(force: false)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if AppSettings.shared.values.autoPlayNext, self.episodeIndex + 1 < self.episodes.count {
                    await self.nextEpisode()
                } else {
                    self.isPlaying = false
                }
            }
        }
    }

    private func saveProgress(force: Bool) {
        guard AppSettings.shared.values.rememberProgress, !isLive else { return }
        guard duration > 1, position > 1 else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastSaved) > 5 else { return }
        lastSaved = now
        Library.shared.saveProgress(link: link(for: currentEpisode), sourceID: source.id,
                                    position: position, duration: duration)
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .allowBluetooth])
        try? session.setActive(true)
    }

    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain {
            switch nsError.code {
            case AVError.fileFormatNotRecognized.rawValue:
                return "当前引擎无法播放此格式，可以切换引擎或返回选择其他线路。"
            case AVError.decoderNotFound.rawValue, -11830:
                return "播放器解码失败，请尝试其他线路。"
            default:
                break
            }
        }
        if nsError.domain == NSURLErrorDomain {
            return HTTPClient.friendlyMessage(for: nsError)
        }
        return "播放遇到问题：\(error.localizedDescription)"
    }
}

enum PlayerItemFactory {
    static func makeAsset(url: URL, headers: [String: String]) -> AVURLAsset {
        if headers.isEmpty {
            return AVURLAsset(url: url)
        }
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }
}

enum ManifestRewriter {
    /// Resolves relative segment/playlist URIs so a script supplied (in-memory)
    /// manifest can be played from a local file.
    static func absolutize(_ manifest: String, base: URL) -> String {
        manifest.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                if trimmed.hasPrefix("#EXT-X-KEY"), let range = trimmed.range(of: "URI=\"") {
                    let rest = trimmed[range.upperBound...]
                    if let end = rest.firstIndex(of: "\""),
                       let absolute = URL(string: String(rest[..<end]), relativeTo: base)?.absoluteURL {
                        return trimmed.replacingOccurrences(of: String(rest[..<end]), with: absolute.absoluteString)
                    }
                }
                return String(line)
            }
            if let absolute = URL(string: trimmed, relativeTo: base)?.absoluteURL {
                return absolute.absoluteString
            }
            return String(line)
        }.joined(separator: "\n")
    }
}

@MainActor
enum SystemVolume {
    private static let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
    private static var slider: UISlider? {
        volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    static var value: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    static func set(_ value: Float) {
        guard let slider else { return }
        DispatchQueue.main.async {
            slider.value = min(max(value, 0), 1)
        }
    }
}

@MainActor
enum OrientationLock {
    static func landscape() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
    }

    static func portrait() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
    }

    static func all() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .allButUpsideDown))
    }
}
