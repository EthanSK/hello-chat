// Remote readers choose one archive day and UUID. Paths supplied by callers are never opened.
import Darwin
import Foundation

enum HControlArchive {
    static func days(before: String, limit: Int, root: URL = TranscriptArchive.directory) throws -> [String] {
        guard before.isEmpty || validDay(before) else { throw HControlFailure.invalid("Use an empty cursor or a YYYY-MM-DD day.") }
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return Array(items.compactMap { item -> String? in
            let name = item.lastPathComponent
            guard validDay(name), before.isEmpty || name < before,
                  let values = try? item.resourceValues(forKeys: [.isDirectoryKey,.isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            return name
        }.sorted(by: >).prefix(limit))
    }

    static func documents(day: String, after: String, limit: Int, root: URL = TranscriptArchive.directory) throws -> [String] {
        guard validDay(day), after.isEmpty || UUID(uuidString: after) != nil else { throw HControlFailure.invalid("Invalid archive day or UUID cursor.") }
        let directory = root.appendingPathComponent(day)
        let attributes = try directory.resourceValues(forKeys: [.isDirectoryKey,.isSymbolicLinkKey])
        guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw HControlFailure.unavailable("Unknown archive day.") }
        let items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return Array(items.compactMap { item -> String? in
            guard item.pathExtension == "json", let id = UUID(uuidString: item.deletingPathExtension().lastPathComponent),
                  id.uuidString > after.uppercased(), let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return id.uuidString
        }.sorted().prefix(limit))
    }

    static func read(day: String, id text: String, offset: Int, limit: Int, root: URL = TranscriptArchive.directory) throws -> [String: Any] {
        guard validDay(day), let id = UUID(uuidString: text), offset >= 0, (1...32768).contains(limit) else { throw HControlFailure.invalid("Invalid archive selection.") }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw HControlFailure.unavailable("No transcript archive on this Mac.") }
        defer { close(rootFD) }
        let dayFD = openat(rootFD, day, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dayFD >= 0 else { throw HControlFailure.unavailable("Unknown archive day.") }
        defer { close(dayFD) }
        let file = openat(dayFD, id.uuidString + ".json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw HControlFailure.unavailable("Unknown archive document.") }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw HControlFailure.unavailable("Invalid archive document.") }
        guard offset <= info.st_size else { throw HControlFailure.invalid("The offset exceeds the document size.") }
        try handle.seek(toOffset: UInt64(offset))
        let bytes = try handle.read(upToCount: limit) ?? Data()
        return ["id": id.uuidString, "day": day, "encoding": "base64", "format": "application/json",
                "offset": offset, "nextOffset": offset + bytes.count, "totalBytes": info.st_size, "data": bytes.base64EncodedString()]
    }

    private static func validDay(_ day: String) -> Bool {
        day.utf8.count == 10 && day.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil
    }
}
