import Foundation

/// 站点分组。数据模型支持嵌套（parentID），M1 的 UI 先只展示一级。
public struct HostGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var parentID: UUID?
    public var sortOrder: Int

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.sortOrder = sortOrder
    }
}
