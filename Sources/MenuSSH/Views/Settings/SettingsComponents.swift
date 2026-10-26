import SwiftUI

/// magpie 风格的设置卡片：圆角背景 + 分隔线，内部一行一项。
@MainActor
struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey?
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                Group { content }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
        }
    }
}

/// 一行设置：左侧标题 + 说明，右侧控件。
@MainActor
struct SettingsRow<Accessory: View>: View {
    let title: Text
    let subtitle: Text?
    var showsDivider: Bool
    @ViewBuilder var accessory: Accessory

    init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        showsDivider: Bool = true,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.init(title: Text(title), subtitleText: subtitle.map { Text($0) }, showsDivider: showsDivider, accessory: accessory)
    }

    /// 说明文字需要拼接 / 原样显示（路径、版本号）时使用。
    init(
        title: Text,
        subtitleText: Text?,
        showsDivider: Bool = true,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitleText
        self.showsDivider = showsDivider
        self.accessory = accessory()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    title.font(.system(size: 13, weight: .medium))
                    if let subtitle {
                        subtitle
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                accessory
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            if showsDivider {
                Divider().padding(.leading, 14)
            }
        }
    }
}

/// 分段选择器（magpie 的“跟随系统 / 浅色 / 深色”样式）。
@MainActor
struct SegmentedSetting<Value: Hashable & Identifiable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> LocalizedStringKey

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options) { option in
                Text(title(option)).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}
