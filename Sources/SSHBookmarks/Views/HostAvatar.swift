import SSHBookmarksCore
import SwiftUI

/// Termius 风格的圆角方形首字母头像，颜色由站点 id 稳定生成。
@MainActor
struct HostAvatar: View {
    let host: SSHHost
    var size: CGFloat = 28

    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .red]

    private var color: Color {
        Self.palette[host.avatarColorIndex(paletteCount: Self.palette.count)]
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(verbatim: host.avatarInitial)
                    .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}

/// 一行站点（菜单栏面板与主窗口共用）。
@MainActor
struct HostRow: View {
    let host: SSHHost
    var groupName: String?

    var body: some View {
        HStack(spacing: 10) {
            HostAvatar(host: host)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(verbatim: host.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if host.isFavorite {
                        Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)
                    }
                }
                Text(verbatim: host.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let groupName, !groupName.isEmpty {
                Text(verbatim: groupName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier(UITestID.hostGroup(host.label))
            }
            if !host.tags.isEmpty {
                Text(verbatim: host.tags.prefix(2).joined(separator: ", "))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: hostAccessibilityLabel))
        .accessibilityIdentifier(UITestID.host(host.label))
    }

    private var hostAccessibilityLabel: String {
        var parts = [host.label]
        if !host.subtitle.isEmpty { parts.append(host.subtitle) }
        if host.isFavorite { parts.append(String(localized: "Favorite")) }
        if let groupName, !groupName.isEmpty { parts.append(groupName) }
        return parts.joined(separator: ", ")
    }
}

extension HostSection {
    /// 内置分区标题走本地化。子分组显示「父 / 子」。
    func title(in library: HostLibrary) -> Text {
        switch kind {
        case .recent: return Text("Recent")
        case .favorites: return Text("Favorites")
        case .group(let g): return Text(verbatim: library.groupPath(id: g.id))
        case .ungrouped: return Text("Ungrouped")
        }
    }
}
