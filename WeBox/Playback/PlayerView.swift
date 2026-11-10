//
//  PlayerView.swift
//  WeBox for iOS
//
//  Player surface and controls: 快进回退、亮度音量、长按倍速、切换全屏、锁定播放器.
//

import SwiftUI
import AVFoundation
import UIKit

struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.attach(player: player)
        view.setGravity(gravity)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.attach(player: player)
        uiView.setGravity(gravity)
    }
}

final class PlayerContainerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    func attach(player: AVPlayer) {
        if playerLayer.player !== player { playerLayer.player = player }
        backgroundColor = .black
    }

    func setGravity(_ gravity: AVLayerVideoGravity) {
        playerLayer.videoGravity = gravity
    }
}

struct PlayerScreen: View {
    @StateObject private var model: PlayerModel
    @Environment(\.dismiss) private var dismiss

    @State private var showEpisodes = false
    @State private var showStreams = false
    @State private var showSettings = false
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var overlay: OverlayHint?
    @State private var hideTask: Task<Void, Never>?

    init(request: PlaybackRequest) {
        _model = StateObject(wrappedValue: PlayerModel(request: request))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                VideoSurface(player: model.player, gravity: model.aspect.avLayerVideoGravity)
                    .ignoresSafeArea()
                    .onTapGesture(count: 2) { model.togglePlayPause(); flashControls() }
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { model.controlsVisible.toggle() } }
                    .gesture(seekGesture(width: geometry.size.width))
                    .simultaneousGesture(verticalGesture(height: geometry.size.height))
                    .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 40) {
                        model.beginTemporarySpeed(AppSettings.shared.values.longPressSpeed)
                    } onPressingChanged: { pressing in
                        if !pressing { model.endTemporarySpeed() }
                    }

                if model.isLoading {
                    ProgressView().scaleEffect(1.4).tint(.white)
                }

                if let hint = overlay {
                    OverlayBadge(hint: hint)
                }

                if model.locked {
                    lockedOverlay
                } else if model.controlsVisible {
                    controls(geometry: geometry)
                }

                if let message = model.errorMessage {
                    errorOverlay(message)
                }
            }
            .statusBarHidden(!model.controlsVisible)
            .persistentSystemOverlays(.hidden)
        }
        .background(Color.black)
        .task { await model.start() }
        .onDisappear {
            model.stop()
            OrientationLock.portrait()
        }
        .sheet(isPresented: $showEpisodes) { episodesSheet }
        .sheet(isPresented: $showStreams) { streamsSheet }
        .sheet(isPresented: $showSettings) { PlayerOptionsSheet(model: model) }
        .onAppear { OrientationLock.landscape() }
    }

    // MARK: - Controls

    private func controls(geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                }
                Text(model.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Spacer()
                if model.isLive {
                    Text("● 直播").font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.red.opacity(0.8), in: Capsule())
                }
                Button { model.locked = true; scheduleHide() } label: {
                    Image(systemName: "lock.open").font(.system(size: 16))
                }
                Button { showEpisodes = true } label: {
                    Image(systemName: "list.bullet.rectangle").font(.system(size: 16))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            Spacer()

            HStack(spacing: 46) {
                Button { Task { await model.previousEpisode() } } label: {
                    Image(systemName: "backward.end.fill").font(.system(size: 22))
                }
                .disabled(model.episodeIndex == 0)

                Button { model.togglePlayPause() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 42))
                }

                Button { Task { await model.nextEpisode() } } label: {
                    Image(systemName: "forward.end.fill").font(.system(size: 22))
                }
                .disabled(model.episodeIndex + 1 >= model.episodes.count)
            }
            .foregroundStyle(.white)

            Spacer()

            VStack(spacing: 10) {
                if !model.isLive {
                    SeekBar(position: model.previewPosition, duration: max(model.duration, 1),
                            buffered: model.buffered, isScrubbing: $isScrubbing) { value in
                        scrubValue = value
                    } onCommit: { value in
                        model.seek(to: value)
                    }
                    HStack {
                        Text(timeText(model.previewPosition))
                        Spacer()
                        Text(timeText(max(model.duration, 0)))
                    }
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                } else {
                    HStack {
                        Text("直播").font(.system(size: 12, weight: .semibold))
                        Spacer()
                    }
                }

                HStack(spacing: 22) {
                    Button { model.skip(-Double(AppSettings.shared.values.seekBackward)) } label: {
                        Label("\(AppSettings.shared.values.seekBackward)", systemImage: "gobackward")
                            .labelStyle(.titleAndIcon).font(.system(size: 13))
                    }
                    Button { model.skip(Double(AppSettings.shared.values.seekForward)) } label: {
                        Label("\(AppSettings.shared.values.seekForward)", systemImage: "goforward")
                            .labelStyle(.titleAndIcon).font(.system(size: 13))
                    }
                    Spacer()
                    Button { model.cycleAspect() } label: {
                        Text(model.aspect.title).font(.system(size: 13, weight: .semibold))
                    }
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 15))
                    }
                    Button { showStreams = true } label: {
                        Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 15))
                    }
                }
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
        .onAppear { scheduleHide() }
    }

    private var lockedOverlay: some View {
        VStack {
            HStack {
                Spacer()
                Button { model.locked = false } label: {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 16))
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(18)
            }
            Spacer()
        }
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 28))
            Text(message).font(.system(size: 14)).multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Button("重新加载") { Task { await model.start() } }
                Button("选择线路") { showStreams = true }
                Button("返回") { dismiss() }
            }
            .font(.system(size: 13, weight: .semibold))
        }
        .padding(22)
        .foregroundStyle(.white)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 18))
        .padding(30)
    }

    // MARK: - Gestures

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !model.isLive, model.duration > 0 else { return }
                if abs(value.translation.width) > abs(value.translation.height) {
                    let delta = Double(value.translation.width / max(width, 1)) * model.duration
                    isScrubbing = true
                    let target = min(max(model.position + delta, 0), model.duration)
                    scrubValue = target
                    model.previewSeek(to: target)
                    overlay = .seek(target)
                }
            }
            .onEnded { value in
                guard isScrubbing else { return }
                isScrubbing = false
                let delta = Double(value.translation.width / max(width, 1)) * model.duration
                model.seek(to: model.position + delta)
                scheduleHide()
                clearOverlay()
            }
    }

    private func verticalGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                let fraction = Double(-value.translation.height / max(height, 1))
                if value.startLocation.x < UIScreen.main.bounds.width / 2 {
                    guard AppSettings.shared.values.brightnessGesture else { return }
                    UIScreen.main.brightness = min(max(UIScreen.main.brightness + CGFloat(fraction * 0.5), 0), 1)
                    overlay = .brightness(Double(UIScreen.main.brightness))
                } else {
                    guard AppSettings.shared.values.volumeGesture else { return }
                    let target = Double(SystemVolume.value) + fraction
                    SystemVolume.set(Float(min(max(target, 0), 1)))
                    overlay = .volume(Double(SystemVolume.value))
                }
            }
            .onEnded { _ in clearOverlay() }
    }

    private func clearOverlay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if !isScrubbing { overlay = nil }
        }
    }

    private func flashControls() {
        model.controlsVisible = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if !Task.isCancelled {
                withAnimation { model.controlsVisible = false }
            }
        }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs)
                         : String(format: "%02d:%02d", minutes, secs)
    }

    // MARK: - Sheets

    private var episodesSheet: some View {
        NavigationStack {
            List {
                ForEach(Array(model.episodes.enumerated()), id: \.offset) { index, episode in
                    Button {
                        Task { await model.selectEpisode(index); showEpisodes = false }
                    } label: {
                        HStack {
                            Text(episode.title).foregroundStyle(.primary)
                            Spacer()
                            if index == model.episodeIndex {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
            .navigationTitle("选集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showEpisodes = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var streamsSheet: some View {
        NavigationStack {
            List {
                ForEach(Array(model.streams.enumerated()), id: \.offset) { index, stream in
                    Button {
                        Task { await model.selectStream(index); showStreams = false }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(stream.name).foregroundStyle(.primary)
                                if let mime = stream.effectiveMIME, !mime.isEmpty {
                                    Text(mime).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if index == model.streamIndex { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                }
            }
            .navigationTitle("选择播放线路")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showStreams = false } } }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Seek bar

struct SeekBar: View {
    let position: Double
    let duration: Double
    let buffered: Double
    @Binding var isScrubbing: Bool
    var onChange: (Double) -> Void
    var onCommit: (Double) -> Void

    @State private var value: Double = 0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let progress = duration > 0 ? min(max(value / duration, 0), 1) : 0
            let bufferProgress = duration > 0 ? min(max(buffered / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22)).frame(height: 4)
                Capsule().fill(Color.white.opacity(0.4)).frame(width: width * bufferProgress, height: 4)
                Capsule().fill(Color.accentColor).frame(width: width * progress, height: 4)
                Circle().fill(Color.white).frame(width: 12, height: 12)
                    .offset(x: max(0, width * progress - 6))
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isScrubbing = true
                        let ratio = min(max(drag.location.x / max(width, 1), 0), 1)
                        value = ratio * duration
                        onChange(value)
                    }
                    .onEnded { _ in
                        isScrubbing = false
                        onCommit(value)
                    }
            )
            .onAppear { value = position }
            .onChange(of: position) { newValue in
                if !isScrubbing { value = newValue }
            }
        }
        .frame(height: 22)
    }
}

// MARK: - Overlay hints

enum OverlayHint: Equatable {
    case seek(Double)
    case brightness(Double)
    case volume(Double)

    var text: String {
        switch self {
        case .seek(let value): return PlayerScreen.timeTextStatic(value)
        case .brightness(let value): return "亮度 \(Int(value * 100))%"
        case .volume(let value): return "音量 \(Int(value * 100))%"
        }
    }

    var icon: String {
        switch self {
        case .seek: return "arrow.left.and.right"
        case .brightness: return "sun.max"
        case .volume: return "speaker.wave.2"
        }
    }
}

extension PlayerScreen {
    static func timeTextStatic(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct OverlayBadge: View {
    let hint: OverlayHint

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: hint.icon).font(.system(size: 22))
            Text(hint.text).font(.system(size: 14, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Options

struct PlayerOptionsSheet: View {
    @ObservedObject var model: PlayerModel
    @Environment(\.dismiss) private var dismiss

    private let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        NavigationStack {
            List {
                Section("播放速度") {
                    ForEach(speeds, id: \.self) { speed in
                        Button {
                            model.setSpeed(speed)
                        } label: {
                            HStack {
                                Text(speed == 1 ? "正常" : String(format: "%.2gx", speed)).foregroundStyle(.primary)
                                Spacer()
                                if abs(model.speed - speed) < 0.001 { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                }
                Section("画面比例") {
                    ForEach(AspectMode.allCases) { mode in
                        Button {
                            model.aspect = mode
                        } label: {
                            HStack {
                                Text(mode.title).foregroundStyle(.primary)
                                Spacer()
                                if model.aspect == mode { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                }
                Section {
                    LabeledContent("播放引擎", value: AppSettings.shared.values.defaultEngine.title)
                    LabeledContent("线路", value: model.currentStream?.name ?? "默认")
                    LabeledContent("格式", value: model.currentStream?.effectiveMIME ?? "自动识别")
                }
            }
            .navigationTitle("播放设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
