import AppKit
import CoreServices

/// A file copied in Finder, carried as one clipboard item. Peers that don't
/// know the type keep using the other items Finder put on the pasteboard,
/// such as the file name, so older guests and hosts behave as before.
struct ClipboardFile: Codable, Equatable {
    static let type = "codes.rambo.VirtualBuddy.clipboard-file"
    /// Total size sent for one clipboard change. Larger copies, and copies
    /// that include folders, fall back to the name only.
    static let maximumTotalSize = 64 * 1024 * 1024

    let name: String
    let contents: Data

    init(name: String, contents: Data) {
        self.name = name
        self.contents = contents
    }

    init?(_ item: ClipboardItem) {
        guard item.type == Self.type,
              let file = try? PropertyListDecoder().decode(Self.self, from: item.data) else { return nil }
        self = file
    }

    var item: ClipboardItem? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return (try? encoder.encode(self)).map { ClipboardItem(type: Self.type, data: $0) }
    }

    /// The name as a single path component, so a peer cannot place a file
    /// outside the staging directory.
    var safeName: String {
        let component = (name as NSString).lastPathComponent
        return ["", ".", "..", "/"].contains(component) ? "File" : component
    }

    /// All of the URLs as files, or nil when any is not a regular file or
    /// together they exceed the size limit.
    static func read(_ urls: [URL]) -> [ClipboardFile]? {
        var files: [ClipboardFile] = []
        var total = 0
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize else { return nil }
            total += size
            guard total <= maximumTotalSize, let contents = try? Data(contentsOf: url) else { return nil }
            files.append(ClipboardFile(name: url.lastPathComponent, contents: contents))
        }
        return files.isEmpty ? nil : files
    }
}

/// Where received files wait to be pasted. Only the latest clipboard's files
/// are kept, and each is quarantined like a download.
@MainActor
final class ClipboardFileStaging {
    let root: URL
    private var current: URL?

    init(root: URL) {
        self.root = root
    }

    func stage(_ files: [ClipboardFile]) throws -> [URL] {
        removeCurrent()
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        current = directory
        var used: [String: Int] = [:]
        return try files.map { file in
            var url = directory.appendingPathComponent(uniqueName(file.safeName, used: &used))
            try file.contents.write(to: url, options: .atomic)
            var values = URLResourceValues()
            values.quarantineProperties = [
                kLSQuarantineAgentNameKey as String: "VirtualBuddy",
                kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String
            ]
            try url.setResourceValues(values)
            return url
        }
    }

    func removeCurrent() {
        guard let current else { return }
        try? FileManager.default.removeItem(at: current)
        self.current = nil
    }

    private func uniqueName(_ name: String, used: inout [String: Int]) -> String {
        let count = used[name, default: 0] + 1
        used[name] = count
        guard count > 1 else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "\(base) \(count)" : "\(base) \(count).\(ext)"
    }
}
