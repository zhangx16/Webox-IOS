//
//  Log.swift
//  WeBox for iOS
//
//  Diagnostics log (设置 → 诊断日志). Mirrors the Android host's log export
//  (WeBox-diagnostics.txt) so support flows stay identical.
//

import Foundation

final class Log: ObservableObject {
    static let shared = Log()

    @Published private(set) var lines: [String] = []

    private let queue = DispatchQueue(label: "webox.log")
    private let limit = 2000
    private let fileURL: URL = Files.root.appendingPathComponent("WeBox-diagnostics.txt")
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private init() {
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            lines = text.split(separator: "\n").map(String.init).suffix(400).map { $0 }
        }
    }

    func debug(_ message: String) { write("DEBUG", message) }
    func info(_ message: String) { write("INFO", message) }
    func warn(_ message: String) { write("WARN", message) }
    func error(_ message: String) { write("ERROR", message) }

    func write(_ level: String, _ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(level) \(message)"
        queue.async { [weak self] in
            guard let self else { return }
            self.append(line)
        }
    }

    private func append(_ line: String) {
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            if let data = (line + "\n").data(using: .utf8) { handle.write(data) }
            try? handle.close()
        } else {
            try? (line + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        }
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > self.limit {
                self.lines.removeFirst(self.lines.count - self.limit)
            }
        }
    }

    func clear() {
        queue.async {
            try? FileManager.default.removeItem(at: self.fileURL)
        }
        DispatchQueue.main.async { self.lines = [] }
    }

    var exportURL: URL { fileURL }

    func exportText() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? lines.joined(separator: "\n")
    }
}
