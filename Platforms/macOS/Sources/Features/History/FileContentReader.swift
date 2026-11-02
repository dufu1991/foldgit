import Darwin
import Foundation

struct FileContentMetadata: Equatable, Sendable {
    let size: Int64
    let device: Int32
    let inode: UInt64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    let isRegularFile: Bool

    init(_ info: stat) {
        size = info.st_size
        device = info.st_dev
        inode = info.st_ino
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
        isRegularFile = info.st_mode & S_IFMT == S_IFREG
    }
}

enum FileContentRestriction: Equatable, Sendable {
    case tooLarge, tooManyLines, lineTooLong, binary, encoding, notRegular
}

struct FileContentLayout: Sendable {
    let lineCount: Int
    let maximumColumns: Int
    var lineStarts: [Int] = [0]
}

struct FileContentSnapshot: Sendable {
    enum Content: Sendable {
        case text(String, plain: Bool, layout: FileContentLayout = .init(lineCount: 1, maximumColumns: 0))
        case requiresLoad
        case unavailable(FileContentRestriction)
    }

    let metadata: FileContentMetadata
    let content: Content
}

enum FileContentReader {
    static let automaticLimit = 1_024 * 1_024
    static let maximumBytes = 10 * 1_024 * 1_024
    static let maximumLines = 100_000
    static let maximumLineLength = 20_000

    static func inspect(_ url: URL) throws -> FileContentMetadata {
        try Task.checkCancellation()
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { Darwin.lstat($0!, &info) }
        guard result == 0 else { throw posixError() }
        return FileContentMetadata(info)
    }

    static func read(_ url: URL, allowLarge: Bool) throws -> FileContentSnapshot {
        let initial = try inspect(url)
        guard initial.isRegularFile else {
            return FileContentSnapshot(metadata: initial, content: .unavailable(.notRegular))
        }
        guard initial.size <= maximumBytes else {
            return FileContentSnapshot(metadata: initial, content: .unavailable(.tooLarge))
        }
        guard initial.size <= automaticLimit || allowLarge else {
            return FileContentSnapshot(metadata: initial, content: .requiresLoad)
        }

        // Never follow links or block on a special file if it replaces the selected file mid-read.
        let descriptor = url.withUnsafeFileSystemRepresentation {
            Darwin.open($0!, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        let metadata = FileContentMetadata(info)
        guard metadata.isRegularFile else {
            return FileContentSnapshot(metadata: metadata, content: .unavailable(.notRegular))
        }
        let limit = allowLarge ? maximumBytes : automaticLimit
        var data = Data()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(64 * 1_024, limit + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > limit {
                guard fstat(descriptor, &info) == 0 else { throw posixError() }
                let current = FileContentMetadata(info)
                return FileContentSnapshot(metadata: current, content:
                    allowLarge || current.size > maximumBytes ? .unavailable(.tooLarge) : .requiresLoad)
            }
        }
        try Task.checkCancellation()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard FileContentMetadata(info) == metadata else {
            throw CocoaError(.fileReadUnknown)
        }
        let content = try decode(data, plain: data.count > automaticLimit)
        return FileContentSnapshot(metadata: metadata, content: content)
    }

    static func decode(_ data: Data, plain: Bool) throws -> FileContentSnapshot.Content {
        let source: String?
        if data.starts(with: [0xFF, 0xFE]) {
            source = try strictUTF16(data.dropFirst(2), littleEndian: true)
        } else if data.starts(with: [0xFE, 0xFF]) {
            source = try strictUTF16(data.dropFirst(2), littleEndian: false)
        } else {
            let bytes = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
            source = String(data: bytes, encoding: .utf8)
        }
        guard let source else { return .unavailable(.encoding) }
        var lines = 1
        var length = 0
        var previousWasCR = false
        var columns = 0
        var maximumColumns = 0
        var lineStarts = [0]
        for (index, unit) in source.utf16.enumerated() {
            if index % 4_096 == 0 { try Task.checkCancellation() }
            if unit == 0 || (unit < 32 && unit != 9 && unit != 10 && unit != 13 && unit != 12) {
                return .unavailable(.binary)
            }
            if unit == 10 || unit == 13 || unit == 0x2028 || unit == 0x2029 {
                maximumColumns = max(maximumColumns, columns)
                columns = 0
                if unit != 10 || !previousWasCR {
                    lines += 1
                    lineStarts.append(index + 1)
                } else {
                    lineStarts[lineStarts.count - 1] = index + 1
                }
                length = 0
                if lines > maximumLines { return .unavailable(.tooManyLines) }
            } else {
                length += 1
                columns = unit == 9 ? (columns / 4 + 1) * 4 : columns + (unit >= 0x2E80 ? 2 : 1)
                if length > maximumLineLength { return .unavailable(.lineTooLong) }
            }
            previousWasCR = unit == 13
        }
        return .text(source, plain: plain, layout: FileContentLayout(
            lineCount: lines, maximumColumns: max(maximumColumns, columns), lineStarts: lineStarts))
    }

    private static func strictUTF16(_ data: Data.SubSequence, littleEndian: Bool) throws -> String? {
        guard data.count.isMultiple(of: 2) else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(data.count / 2)
        var highSurrogate = false
        var offset = data.startIndex
        while offset < data.endIndex {
            if (offset - data.startIndex) % 8_192 == 0 { try Task.checkCancellation() }
            let first = UInt16(data[offset])
            let second = UInt16(data[offset + 1])
            let unit = littleEndian ? first | second << 8 : first << 8 | second
            if highSurrogate {
                guard (0xDC00...0xDFFF).contains(unit) else { return nil }
                highSurrogate = false
            } else if (0xD800...0xDBFF).contains(unit) {
                highSurrogate = true
            } else if (0xDC00...0xDFFF).contains(unit) {
                return nil
            }
            units.append(unit)
            offset += 2
        }
        guard !highSurrogate else { return nil }
        return String(decoding: units, as: UTF16.self)
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
