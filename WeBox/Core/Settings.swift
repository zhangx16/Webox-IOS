//
//  Settings.swift
//  WeBox for iOS
//
//  Preferences exposed in 设置 → 外观与显示 / 播放设置 / 首页内容 / 接口缓存.
//

import Foundation
import SwiftUI

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "明亮"
        case .dark: return "黑暗"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum PlaybackEngine: String, Codable, CaseIterable, Identifiable {
    case system
    case vlc
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "系统解码（AVPlayer）"
        case .vlc: return "兼容引擎（libVLC，需集成 VLCKit）"
        }
    }
    var isAvailable: Bool {
        switch self {
        case .system: return true
        case .vlc: return VLCBridge.isAvailable
        }
    }
}

enum AspectMode: String, Codable, CaseIterable, Identifiable {
    case fit, fill, stretch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fit: return "适应"
        case .fill: return "裁切"
        case .stretch: return "拉伸"
        }
    }
    var avLayerVideoGravity: AVLayerVideoGravity {
        switch self {
        case .fit: return .resizeAspect
        case .fill: return .resizeAspectFill
        case .stretch: return .resize
        }
    }
    func next() -> AspectMode {
        switch self {
        case .fit: return .fill
        case .fill: return .stretch
        case .stretch: return .fit
        }
    }
}

struct SettingsValues: Codable, Equatable {
    var appearance: AppearanceMode = .system
    var posterColumns: Int = 3
    var defaultEngine: PlaybackEngine = .system
    var defaultSpeed: Double = 1.0
    var defaultAspect: AspectMode = .fit
    var preferHardwareDecode: Bool = true
    var bufferMegabytes: Int = 128
    var bufferSeconds: Int = 30
    var seekForward: Int = 10
    var seekBackward: Int = 10
    var longPressSpeed: Double = 2.0
    var brightnessGesture: Bool = true
    var volumeGesture: Bool = true
    var rememberProgress: Bool = true
    var autoPlayNext: Bool = true
    var rememberBrowseHistory: Bool = true
    var tmdbAPIKey: String = ""
    var tmdbService: String = "https://api.themoviedb.org/3"
    var imageCacheMegabytes: Int = 200
    var apiCacheMinutes: Int = 5
    var homeSections: [String] = ["discover", "favorites", "downloads"]
    var catalogLanguage: String = "zh-CN"
    var installedAt: Date = Date()
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var values: SettingsValues {
        didSet {
            guard values != oldValue else { return }
            save()
        }
    }

    private let key = "webox.settings.v1"

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(SettingsValues.self, from: data) {
            values = decoded
        } else {
            values = SettingsValues()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func resetPlaybackPreferences() {
        values.defaultSpeed = 1.0
        values.defaultAspect = .fit
        values.preferHardwareDecode = true
        values.bufferMegabytes = 128
        values.bufferSeconds = 30
    }
}

/// Optional libVLC integration point. The Android build ships libmpv; on iOS the
/// system AVPlayer covers HLS/MP4 and VLCKit can be added for extra containers.
enum VLCBridge {
    static var isAvailable: Bool {
        NSClassFromString("VLCMediaPlayer") != nil
    }
}
