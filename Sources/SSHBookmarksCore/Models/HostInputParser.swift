import Foundation

/// 编辑器输入解析：端口、标签、名称。纯函数，便于测试。
public enum HostInputParser {
    public enum PortError: Error, Equatable, Sendable {
        case notANumber
        case outOfRange
    }

    /// 空字符串 → nil（使用 ssh 默认 / ssh_config）；否则必须是 1...65535 的十进制整数。
    public static func parsePort(_ text: String) throws -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else { throw PortError.notANumber }
        guard let value = Int(trimmed), (1...65535).contains(value) else { throw PortError.outOfRange }
        return value
    }

    /// 标签：按半角 / 全角逗号、顿号、换行拆分；去首尾空白、去控制字符；忽略大小写去重（保留首次写法）。
    public static func parseTags(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，、;；\n\r")
        var seen = Set<String>()
        var result: [String] = []
        for raw in text.components(separatedBy: separators) {
            let tag = normalizedName(raw)
            guard !tag.isEmpty else { continue }
            if seen.insert(tag.lowercased()).inserted { result.append(tag) }
        }
        return result
    }

    /// 标签数组 → 编辑框文本。
    public static func formatTags(_ tags: [String]) -> String {
        tags.joined(separator: ", ")
    }

    /// 名称（标签名 / 分组名 / 站点名）：去掉控制与格式字符，合并连续空白，去首尾空白。
    public static func normalizedName(_ text: String) -> String {
        let cleaned = String(
            String.UnicodeScalarView(
                text.unicodeScalars.map { scalar -> Unicode.Scalar in
                    switch scalar.properties.generalCategory {
                    case .control, .format, .lineSeparator, .paragraphSeparator: return " "
                    default: return scalar
                    }
                }))
        return cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

public extension SSHHost {
    /// 头像上显示的首字母：取名称（为空时取主机名）的第一个字符并大写。
    var avatarInitial: String {
        let source = HostInputParser.normalizedName(label).isEmpty ? hostname : HostInputParser.normalizedName(label)
        guard let first = source.first(where: { !$0.isWhitespace }) else { return "?" }
        return String(first).uppercased()
    }

    /// 稳定的头像颜色序号（由 id 决定，跨启动不变）。
    func avatarColorIndex(paletteCount: Int) -> Int {
        guard paletteCount > 0 else { return 0 }
        let sum = id.uuidString.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return abs(sum) % paletteCount
    }
}
