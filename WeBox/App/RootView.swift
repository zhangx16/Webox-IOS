//
//  RootView.swift
//  WeBox for iOS
//

import SwiftUI

struct RootView: View {
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                DiscoverView()
            }
            .tabItem { Label("发现", systemImage: "sparkles.tv") }
            .tag(0)

            FavoritesView()
                .tabItem { Label("收藏", systemImage: "heart") }
                .tag(1)

            DownloadsView()
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
                .tag(2)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(3)
        }
    }
}
