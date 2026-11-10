//
//  SettingsView.swift
//  WeBox for iOS
//
//  设置: 外观与显示、播放设置、首页内容、影视资料、缓存、备份与恢复、诊断日志.
//

import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadManager

    @State private var showImport = false
    @State private var backupURL: URL?
    @State private var showRestore = false
    @State private var alertMessage: String?
    @State private var showCacheCleared = false

    var body: some View {
        NavigationStack {
            Form {
                Section("内容与来源") {
                    NavigationLink {
                        SourceListView()
                    } label: {
                        LabeledContent("管理内容源", value: "\(library.sources.count)")
                    }
                    Button { showImport = true } label: {
                        Label("导入内容源", systemImage: "square.and.arrow.down")
                    }
                    NavigationLink {
                        LogView()
                    } label: {
                        LabeledContent("诊断日志", value: "\(Log.shared.lines.count) 条")
                    }
                }

                Section("外观与显示") {
                    Picker("外观模式", selection: $settings.values.appearance) {
                        ForEach(AppearanceMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    Picker("海报密度", selection: $settings.values.posterColumns) {
                        Text("3 列 · 标准").tag(3)
                        Text("4 列 · 紧凑").tag(4)
                        Text("5 列 · 密集").tag(5)
                    }
                }

                Section("播放设置") {
                    Picker("默认播放引擎", selection: $settings.values.defaultEngine) {
                        ForEach(PlaybackEngine.allCases) { engine in
                            Text(engine.isAvailable ? engine.title : engine.title + "（未集成）").tag(engine)
                        }
                    }
                    Picker("默认播放速度", selection: $settings.values.defaultSpeed) {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                            Text(speed == 1 ? "正常" : String(format: "%.2gx", speed)).tag(speed)
                        }
                    }
                    Picker("默认画面比例", selection: $settings.values.defaultAspect) {
                        ForEach(AspectMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    Toggle("优先使用设备解码器", isOn: $settings.values.preferHardwareDecode)
                    Stepper(value: $settings.values.bufferSeconds, in: 5...120, step: 5) {
                        LabeledContent("视频缓冲时长", value: "\(settings.values.bufferSeconds) 秒")
                    }
                    Stepper(value: $settings.values.bufferMegabytes, in: 16...1024, step: 16) {
                        LabeledContent("视频缓冲大小", value: "\(settings.values.bufferMegabytes) MB")
                    }
                }

                Section("播放器与手势") {
                    Stepper(value: $settings.values.seekForward, in: 5...120, step: 5) {
                        LabeledContent("快进时间", value: "\(settings.values.seekForward) 秒")
                    }
                    Stepper(value: $settings.values.seekBackward, in: 5...120, step: 5) {
                        LabeledContent("回退时间", value: "\(settings.values.seekBackward) 秒")
                    }
                    Picker("长按倍速", selection: $settings.values.longPressSpeed) {
                        ForEach([1.5, 2.0, 3.0], id: \.self) { speed in
                            Text(String(format: "%.1fx", speed)).tag(speed)
                        }
                    }
                    Toggle("左侧纵滑调亮度", isOn: $settings.values.brightnessGesture)
                    Toggle("右侧纵滑调音量", isOn: $settings.values.volumeGesture)
                    Toggle("记住播放进度", isOn: $settings.values.rememberProgress)
                    Toggle("自动播放下一集", isOn: $settings.values.autoPlayNext)
                }

                Section("首页内容") {
                    Text("选择你希望在首页看到的分区").font(.system(size: 12)).foregroundStyle(.secondary)
                    Toggle("最近浏览", isOn: Binding(
                        get: { settings.values.homeSections.contains("favorites") },
                        set: { toggleHomeSection("favorites", enabled: $0) }
                    ))
                    Toggle("保存浏览记录", isOn: $settings.values.rememberBrowseHistory)
                    Button("清空浏览记录") {
                        library.clearBrowseHistory()
                        alertMessage = "浏览记录已清空"
                    }
                }

                Section("影视资料与海报") {
                    SecureField("TMDB API Key（可选）", text: $settings.values.tmdbAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("服务地址", text: $settings.values.tmdbService)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("恢复默认服务") {
                        settings.values.tmdbService = "https://api.themoviedb.org/3"
                    }
                    Text("使用 TMDB 官方 API 时，请在设置中填写自己的 API Key。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                Section("接口缓存与存储") {
                    Stepper(value: $settings.values.apiCacheMinutes, in: 0...120, step: 5) {
                        LabeledContent("接口缓存时效", value: settings.values.apiCacheMinutes == 0 ? "不缓存" : "\(settings.values.apiCacheMinutes) 分钟")
                    }
                    Stepper(value: $settings.values.imageCacheMegabytes, in: 50...2048, step: 50) {
                        LabeledContent("图片缓存", value: "\(settings.values.imageCacheMegabytes) MB")
                    }
                    Button("清除图片缓存") {
                        ImageCache.shared.clear()
                        alertMessage = "图片缓存已清理"
                    }
                    Button("清除接口缓存") {
                        CacheControl.bump()
                        Store.shared.removeExpired()
                        alertMessage = "接口缓存已清理"
                    }
                    LabeledContent("下载任务", value: "\(downloads.records.count)")
                    LabeledContent("已用空间", value: ByteCountFormatter.string(fromByteCount: Files.directorySize(Files.downloadsDirectory), countStyle: .file))
                }

                Section("数据备份与恢复") {
                    if let backupURL {
                        ShareLink(item: backupURL) { Label("导出备份（WeBox-backup.json）", systemImage: "square.and.arrow.up") }
                    } else {
                        Button("导出备份") { exportBackup() }
                    }
                    Button("恢复备份") { showRestore = true }
                }

                Section("关于") {
                    LabeledContent("当前版本", value: "0.1.64 (iOS)")
                    NavigationLink("开源许可") { LicensesView() }
                    LabeledContent("构建于", value: "WeBox iOS")
                }
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showImport) { ImportSourceView() }
            .fileImporter(isPresented: $showRestore,
                          allowedContentTypes: [.json, .data],
                          allowsMultipleSelection: false) { result in
                Task { await restore(result) }
            }
            .alert("提示", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
                Button("知道了") { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    private func toggleHomeSection(_ name: String, enabled: Bool) {
        var sections = settings.values.homeSections
        if enabled {
            if !sections.contains(name) { sections.append(name) }
        } else {
            sections.removeAll { $0 == name }
        }
        settings.values.homeSections = sections
    }

    private func exportBackup() {
        do {
            backupURL = try BackupService.export()
            alertMessage = "备份已导出"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func restore(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                try BackupService.restore(from: url)
                alertMessage = "恢复完成"
            } catch {
                alertMessage = error.localizedDescription
            }
        case .failure(let error):
            alertMessage = error.localizedDescription
        }
    }
}

struct LogView: View {
    @StateObject private var log = Log.shared
    @State private var shareURL: URL?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(log.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
        .background(Theme.background)
        .navigationTitle("诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: Log.shared.exportURL) { Image(systemName: "square.and.arrow.up") }
                Button(role: .destructive) { Log.shared.clear() } label: { Image(systemName: "trash") }
            }
        }
    }
}

struct LicensesView: View {
    private var text: String {
        ScriptAssets.text("web-licenses.txt") ?? "运行时组件采用 MIT / Apache-2.0 许可。"
    }

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("开源许可")
    }
}

@MainActor
enum BackupService {
    struct Backup: Codable {
        var version: Int
        var exportedAt: Date
        var settings: SettingsValues
        var sources: [ContentSource]
        var favorites: [FavoriteEntry]
    }

    static func export() throws -> URL {
        var sources = Library.shared.sources
        for index in sources.indices {
            if let file = sources[index].scriptFile {
                sources[index].scriptText = try? String(contentsOf: Files.scriptsDirectory.appendingPathComponent(file), encoding: .utf8)
            }
            for key in sources[index].params.keys where key.lowercased().contains("cookie") {
                throw ScriptError.message("内容源包含 Cookie 字段，请移除后再备份")
            }
        }
        let backup = Backup(version: 1, exportedAt: Date(),
                            settings: AppSettings.shared.values,
                            sources: sources,
                            favorites: Library.shared.favorites)
        let data = try JSONEncoder().encode(backup)
        guard data.count <= 16 * 1024 * 1024 else { throw ScriptError.message("备份超过 16 MB 限制") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WeBox-backup.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func restore(from url: URL) throws {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.count <= 16 * 1024 * 1024 else { throw ScriptError.message("备份超过 16 MB 限制") }
        guard let backup = try? JSONDecoder().decode(Backup.self, from: data), backup.version == 1 else {
            throw ScriptError.message("不支持的备份格式或版本")
        }
        for source in backup.sources {
            var restored = source
            if let text = source.scriptText, !text.isEmpty {
                let fileName = "\(source.id.replacingOccurrences(of: "/", with: "_")).js"
                try text.write(to: Files.scriptsDirectory.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
                restored.scriptFile = fileName
                restored.scriptText = nil
            }
            Library.shared.upsert(restored)
        }
        AppSettings.shared.values = backup.settings
    }
}
