//
//  SourceManagement.swift
//  WeBox for iOS
//
//  管理内容源: import from link / file / text, edit script parameters, update.
//

import SwiftUI
import UniformTypeIdentifiers

struct SourceListView: View {
    @EnvironmentObject private var library: Library
    @State private var showImport = false
    @State private var pendingDeletion: ContentSource?

    var body: some View {
        List {
            if library.sources.isEmpty {
                Section {
                    Text("还没有可用的内容源").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            ForEach(library.sources) { source in
                NavigationLink {
                    SourceSettingsView(source: source)
                } label: {
                    HStack(spacing: 10) {
                        if let icon = source.icon, !icon.isEmpty {
                            RemoteImage(urlString: icon)
                                .frame(width: 34, height: 34)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            Image(systemName: "shippingbox")
                                .frame(width: 34, height: 34)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.displayName).font(.system(size: 14, weight: .medium))
                            Text("\(source.kind.title) · v\(source.version)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !source.enabled {
                            Text("已停用").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { pendingDeletion = source } label: { Label("删除", systemImage: "trash") }
                }
            }
        }
        .navigationTitle("管理内容源")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImport = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showImport) { ImportSourceView() }
        .confirmationDialog("删除内容源？", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { source in
            Button("删除 \(source.displayName)", role: .destructive) {
                SourceManager.shared.invalidate(sourceID: source.id)
                library.remove(source)
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        }
    }
}

struct ImportSourceView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case link, file, text
        var id: String { rawValue }
        var title: String {
            switch self {
            case .link: return "导入链接"
            case .file: return "本地文件"
            case .text: return "粘贴脚本"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .link
    @State private var link = ""
    @State private var text = ""
    @State private var showPicker = false
    @State private var busy = false
    @State private var message: String?
    @State private var success = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("导入方式", selection: $mode) {
                    ForEach(Mode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)

                switch mode {
                case .link:
                    Section("内容源链接") {
                        TextField("https://example.com/source.js", text: $link)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Section {
                        Text("支持 JS 脚本、M3U 直播列表与 VOD 接口配置，导入后自动识别。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                case .file:
                    Section {
                        Button("选择文件") { showPicker = true }
                        Text("支持 .js / .json / .m3u / .txt，一次最多选择 100 个文件。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                case .text:
                    Section("脚本内容") {
                        TextEditor(text: $text).frame(minHeight: 180).font(.system(size: 12, design: .monospaced))
                    }
                }

                if let message {
                    Section {
                        Text(message).font(.system(size: 12))
                            .foregroundStyle(success ? .green : .red)
                    }
                }
            }
            .navigationTitle("导入内容源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(busy ? "正在导入…" : "导入") { Task { await performImport() } }
                        .disabled(busy)
                }
            }
            .fileImporter(isPresented: $showPicker,
                          allowedContentTypes: [.plainText, .json, .data, UTType(filenameExtension: "m3u") ?? .data, UTType(filenameExtension: "js") ?? .data],
                          allowsMultipleSelection: true) { result in
                Task { await importFiles(result) }
            }
        }
    }

    private func performImport() async {
        message = nil
        do {
            switch mode {
            case .link:
                guard !link.isEmpty else { throw ScriptError.message("请输入完整的 HTTP 或 HTTPS 链接") }
                busy = true
                let source = try await SourceManager.shared.importURL(link)
                success = true
                message = "已导入 \(source.displayName)"
            case .text:
                guard !text.isEmpty else { throw ScriptError.message("脚本无效或过大") }
                busy = true
                let source = try await SourceManager.shared.importScript(text: text, name: "本地脚本")
                success = true
                message = "已导入 \(source.displayName)"
            case .file:
                showPicker = true
            }
        } catch {
            success = false
            message = error.localizedDescription
        }
        busy = false
    }

    private func importFiles(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            busy = true
            var imported: [String] = []
            var failures: [String] = []
            for url in urls.prefix(100) {
                do {
                    let source = try await SourceManager.shared.importFile(url)
                    imported.append(source.displayName)
                } catch {
                    failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            success = failures.isEmpty
            message = imported.isEmpty
                ? failures.joined(separator: "\n")
                : "已导入 \(imported.count) 个内容源" + (failures.isEmpty ? "" : "；\(failures.count) 个失败")
            busy = false
        case .failure(let error):
            success = false
            message = error.localizedDescription
        }
    }
}

struct SourceSettingsView: View {
    let source: ContentSource

    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var metadata: SourceMetadata?
    @State private var values: [String: String] = [:]
    @State private var jsonText = "{}"
    @State private var message: String?
    @State private var busy = false
    @State private var loaded = false

    private var current: ContentSource { library.source(id: source.id) ?? source }

    var body: some View {
        Form {
            Section {
                LabeledContent("名称", value: current.displayName)
                LabeledContent("类型", value: current.kind.title)
                LabeledContent("版本", value: current.version)
                if let url = current.sourceURL {
                    LabeledContent("来源", value: url).lineLimit(1)
                }
            }

            if current.kind == .xptv {
                Section {
                    TextEditor(text: $jsonText)
                        .frame(minHeight: 140)
                        .font(.system(size: 12, design: .monospaced))
                } header: {
                    Text("脚本配置（JSON）")
                } footer: {
                    Text("按脚本要求填写 JSON；无需额外配置时保留 {}。")
                }
            }

            if let metadata, !metadata.settingsFields.isEmpty {
                Section("内容源配置") {
                    ParamForm(fields: metadata.settingsFields, values: $values)
                }
            }

            Section {
                Toggle("启用此内容源", isOn: Binding(
                    get: { current.enabled },
                    set: { _ in library.toggle(current) }
                ))
            }

            Section {
                Button(busy ? "正在保存…" : "保存并读取分类") { Task { await save() } }
                    .disabled(busy)
                Button("删除此内容源", role: .destructive) {
                    SourceManager.shared.invalidate(sourceID: current.id)
                    library.remove(current)
                    dismiss()
                }
            }

            if let message {
                Section { Text(message).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(current.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            loaded = true
            values = current.params
            jsonText = current.params["__xptv_config"] ?? "{}"
            do {
                let provider = try SourceManager.shared.provider(for: current)
                metadata = try await provider.loadMetadata()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func save() async {
        busy = true
        message = nil
        var params = values
        if current.kind == .xptv {
            let valid = jsonText.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } != nil
            guard valid else {
                message = "请输入有效的 JSON 对象"
                busy = false
                return
            }
            params["__xptv_config"] = jsonText
        }
        do {
            let provider = try SourceManager.shared.provider(for: current)
            if let script = provider as? ScriptProvider {
                metadata = try await script.configure(params)
            }
            library.setParams(params, for: current)
            message = "配置已保存"
        } catch {
            message = error.localizedDescription
        }
        busy = false
    }
}
