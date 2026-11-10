//
//  WeBoxApp.swift
//  WeBox for iOS
//
//  A native SwiftUI port of WeBox 0.1.64 (dev.webox.app): JavaScript content sources
//  (WeBox Script 1.0 + XPTV), M3U live playlists and AppleCMS VOD sources, with an
//  AVPlayer based 播放器 and offline downloads.
//

import SwiftUI

@main
struct WeBoxApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var library = Library.shared
    @StateObject private var downloads = DownloadManager.shared

    init() {
        Store.shared.removeExpired()
        Log.shared.info("WeBox iOS 启动，协议版本 \(ScriptEngine.protocolVersion)")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(downloads)
                .preferredColorScheme(settings.values.appearance.colorScheme)
                .tint(.accentColor)
        }
    }
}
