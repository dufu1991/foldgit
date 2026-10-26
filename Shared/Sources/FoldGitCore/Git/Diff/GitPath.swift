import Foundation

enum GitPath {
    /// Decode Git's C-quoted path bytes before interpreting UTF-8.
    static func decode(_ raw: String) -> String {
        guard raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        let input = Array(raw.dropFirst().dropLast().utf8)
        var output: [UInt8] = []
        var index = 0
        while index < input.count {
            let byte = input[index]
            if byte != 92 { output.append(byte); index += 1; continue }
            index += 1
            guard index < input.count else { break }
            let escaped = input[index]
            if (48...55).contains(escaped) {
                var value = 0
                var count = 0
                while index < input.count, count < 3, (48...55).contains(input[index]) {
                    value = value * 8 + Int(input[index] - 48)
                    index += 1
                    count += 1
                }
                output.append(UInt8(truncatingIfNeeded: value))
                continue
            }
            switch escaped {
            case 116: output.append(9)
            case 110: output.append(10)
            case 114: output.append(13)
            case 97: output.append(7)
            case 98: output.append(8)
            case 118: output.append(11)
            case 102: output.append(12)
            default: output.append(escaped)
            }
            index += 1
        }
        return String(bytes: output, encoding: .utf8) ?? raw
    }

    static func withoutPrefix(_ path: String) -> String {
        let decoded = decode(path)
        return decoded.hasPrefix("a/") || decoded.hasPrefix("b/") ? String(decoded.dropFirst(2)) : decoded
    }
}
