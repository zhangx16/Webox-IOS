//
//  Components.swift
//  WeBox for iOS
//
//  Shared SwiftUI building blocks: cached artwork, poster cards, parameter forms.
//

import SwiftUI
import UIKit

// MARK: - Image cache

final class ImageCache {
    static let shared = ImageCache()
    private let memory = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "webox.imagecache", attributes: .concurrent)

    private init() {
        memory.countLimit = 220
    }

    func cached(_ key: String) -> UIImage? {
        memory.object(forKey: key as NSString)
    }

    func load(_ raw: String) async -> UIImage? {
        guard let url = URL(string: raw) else { return nil }
        if let cached = cached(raw) { return cached }
        let key = CryptoBridge.md5Hex(raw)
        let file = Files.imageCacheDirectory.appendingPathComponent(key)
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory.setObject(image, forKey: raw as NSString)
            return image
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("WeBox/0.3.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let image = UIImage(data: data) else { return nil }
        memory.setObject(image, forKey: raw as NSString)
        try? data.write(to: file, options: .atomic)
        return image
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: Files.imageCacheDirectory)
        try? FileManager.default.createDirectory(at: Files.imageCacheDirectory, withIntermediateDirectories: true)
    }
}

struct RemoteImage: View {
    let urlString: String?
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.14))
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(.tertiary)
            }
        }
        .task(id: urlString) {
            guard let urlString, !urlString.isEmpty else { image = nil; return }
            if let cached = ImageCache.shared.cached(urlString) { image = cached; return }
            image = await ImageCache.shared.load(urlString)
        }
        .clipped()
    }
}

// MARK: - Cards

struct PosterCard: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(urlString: item.poster)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if item.isLiveContent {
                        Text("直播")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.red.opacity(0.85), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
            Text(item.displayTitle)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
            if let subtitle = item.description, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct WideCard: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 10) {
            RemoteImage(urlString: item.poster)
                .frame(width: 62, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if let subtitle = item.description, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                if let rating = item.ratingText {
                    Text("评分 \(rating)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let icon: String
    let title: String
    var message: String? = nil
    var action: (title: String, handler: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 15, weight: .medium))
            if let message {
                Text(message).font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }
            if let action {
                Button(action.title, action: action.handler).buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Parameter form

struct ParamForm: View {
    let fields: [ParamSpec]
    @Binding var values: [String: String]

    var body: some View {
        ForEach(fields.filter { $0.isEnabled }) { field in
            switch field.type.lowercased() {
            case "select", "enumeration":
                HStack {
                    Text(field.title)
                    Spacer()
                    Picker("", selection: binding(for: field)) {
                        if field.required != true {
                            Text("全部").tag("")
                        }
                        ForEach(field.options) { option in
                            Text(option.title).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            case "boolean":
                Toggle(field.title, isOn: boolBinding(for: field))
            case "number":
                HStack {
                    Text(field.title)
                    Spacer()
                    TextField(field.placeholder ?? "0", text: binding(for: field))
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 140)
                }
            default:
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.title).font(.system(size: 13, weight: .medium))
                    TextField(field.placeholder ?? "", text: binding(for: field))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(field.type.lowercased() == "url" ? .URL : .default)
                    if let help = field.description, !help.isEmpty {
                        Text(help).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Script metadata prefixes setting names (__wbSetting_x); the script itself reads
    /// the original field key, so persistence must use nativeField.key when present.
    private func storageKey(for field: ParamSpec) -> String {
        field.nativeField?["key"]?.stringValue ?? field.name
    }

    private func binding(for field: ParamSpec) -> Binding<String> {
        let key = storageKey(for: field)
        return Binding(
            get: { values[key] ?? field.value ?? "" },
            set: { values[key] = $0 }
        )
    }

    private func boolBinding(for field: ParamSpec) -> Binding<Bool> {
        let key = storageKey(for: field)
        return Binding(
            get: { (values[key] ?? field.value ?? "false") == "true" },
            set: { values[key] = $0 ? "true" : "false" }
        )
    }
}

// MARK: - Grid

struct PosterGrid: View {
    let items: [MediaItem]
    var columns: Int

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: max(2, min(columns, 6)))
    }

    var body: some View {
        LazyVGrid(columns: gridColumns, spacing: 14) {
            ForEach(items) { item in
                NavigationLink(value: item) {
                    PosterCard(item: item)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
