//
//  Library.swift
//  WeBox for iOS
//
//  App level state: content sources, favorites, watch history and downloads.
//

import Foundation
import SwiftUI

@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var sources: [ContentSource] = []
    @Published private(set) var favorites: [FavoriteEntry] = []
    @Published private(set) var browseHistory: [BrowseHistoryEntry] = []
    @Published private(set) var downloads: [DownloadRecord] = []

    private let sourceKind = "source"
    private let favoriteKind = "favorite"
    private let browseKind = "browse"
    private let progressKind = "progress"

    private init() {
        reload()
    }

    func reload() {
        let decoder = JSONDecoder()
        sources = Store.shared.all(kind: sourceKind).compactMap { entry in
            try? decoder.decode(ContentSource.self, from: Data(entry.json.utf8))
        }
        favorites = Store.shared.all(kind: favoriteKind).compactMap { entry in
            try? decoder.decode(FavoriteEntry.self, from: Data(entry.json.utf8))
        }
        browseHistory = Store.shared.all(kind: browseKind).compactMap { entry in
            try? decoder.decode(BrowseHistoryEntry.self, from: Data(entry.json.utf8))
        }
        sortFavorites()
    }

    // MARK: - Sources

    func upsert(_ source: ContentSource) {
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
        persistSource(source)
        objectWillChange.send()
    }

    func remove(_ source: ContentSource) {
        sources.removeAll { $0.id == source.id }
        Store.shared.remove(kind: sourceKind, id: source.id)
        Store.shared.removeAll(kind: "kv.\(source.id)")
        if let file = source.scriptFile {
            try? FileManager.default.removeItem(at: Files.scriptsDirectory.appendingPathComponent(file))
        }
        objectWillChange.send()
    }

    func remove(ids: [String]) {
        for id in ids {
            if let source = sources.first(where: { $0.id == id }) { remove(source) }
        }
    }

    func source(id: String) -> ContentSource? {
        sources.first { $0.id == id }
    }

    func setParams(_ params: [String: String], for source: ContentSource) {
        var updated = source
        updated.params = params
        updated.updatedAt = Date()
        upsert(updated)
    }

    func toggle(_ source: ContentSource) {
        var updated = source
        updated.enabled.toggle()
        upsert(updated)
    }

    private func persistSource(_ source: ContentSource) {
        guard let data = try? JSONEncoder().encode(source) else { return }
        Store.shared.put(kind: sourceKind, id: source.id, json: String(decoding: data, as: UTF8.self),
                         num: source.updatedAt.timeIntervalSince1970)
    }

    // MARK: - Favorites

    func isFavorite(_ link: String) -> Bool {
        favorites.contains { $0.link == link }
    }

    func toggleFavorite(_ item: MediaItem, source: ContentSource) {
        let link = item.link ?? item.id
        if let index = favorites.firstIndex(where: { $0.link == link }) {
            favorites.remove(at: index)
            Store.shared.remove(kind: favoriteKind, id: link)
        } else {
            let entry = FavoriteEntry(link: link, item: item, sourceID: source.id, sourceName: source.displayName, addedAt: Date())
            favorites.insert(entry, at: 0)
            if let data = try? JSONEncoder().encode(entry) {
                Store.shared.put(kind: favoriteKind, id: link, json: String(decoding: data, as: UTF8.self),
                                 num: entry.addedAt.timeIntervalSince1970)
            }
        }
        objectWillChange.send()
    }

    func removeFavorite(link: String) {
        favorites.removeAll { $0.link == link }
        Store.shared.remove(kind: favoriteKind, id: link)
        objectWillChange.send()
    }

    private func sortFavorites() {
        favorites.sort { $0.addedAt > $1.addedAt }
    }

    // MARK: - Browse history

    func recordBrowse(_ item: MediaItem, source: ContentSource) {
        guard AppSettings.shared.values.rememberBrowseHistory else { return }
        let link = item.link ?? item.id
        let entry = BrowseHistoryEntry(link: link, item: item, sourceID: source.id,
                                       sourceName: source.displayName, watchedAt: Date())
        if let data = try? JSONEncoder().encode(entry) {
            Store.shared.put(kind: browseKind, id: "\(source.id)|\(link)", json: String(decoding: data, as: UTF8.self),
                             num: entry.watchedAt.timeIntervalSince1970)
        }
        let all = Store.shared.all(kind: browseKind)
        if all.count > 200 {
            for entry in all.dropFirst(200) {
                Store.shared.remove(kind: browseKind, id: entry.id)
            }
        }
        reload()
    }

    func clearBrowseHistory() {
        Store.shared.removeAll(kind: browseKind)
        browseHistory = []
    }

    // MARK: - Progress

    func progress(for link: String) -> PlaybackProgress? {
        guard let json = Store.shared.get(kind: progressKind, id: link),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PlaybackProgress.self, from: data)
    }

    func saveProgress(link: String, sourceID: String, position: Double, duration: Double) {
        guard AppSettings.shared.values.rememberProgress else { return }
        let record = PlaybackProgress(link: link, sourceID: sourceID, position: position,
                                      duration: duration, updatedAt: Date())
        if let data = try? JSONEncoder().encode(record) {
            Store.shared.put(kind: progressKind, id: link, json: String(decoding: data, as: UTF8.self),
                             num: record.updatedAt.timeIntervalSince1970)
        }
    }

    func clearProgress(link: String) {
        Store.shared.remove(kind: progressKind, id: link)
    }

    // MARK: - Downloads

    func setDownloads(_ records: [DownloadRecord]) {
        downloads = records
    }
}
