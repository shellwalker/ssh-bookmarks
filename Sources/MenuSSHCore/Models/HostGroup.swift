import Foundation

/// 站点分组。数据模型支持嵌套（parentID），M1 的 UI 先只展示一级。
public struct HostGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var parentID: UUID?
    public var sortOrder: Int
    public var updatedAt: Date
    /// 最后改这条分组的设备。时间戳相同时，字典序更大的 deviceId 胜出。
    public var updatedByDeviceId: String?

    public init(
        id: UUID = UUID(),
        name: String,
        parentID: UUID? = nil,
        sortOrder: Int = 0,
        updatedAt: Date = Date(),
        updatedByDeviceId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.sortOrder = sortOrder
        self.updatedAt = updatedAt
        self.updatedByDeviceId = updatedByDeviceId
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, parentID, sortOrder, updatedAt, updatedByDeviceId
    }

    /// 旧的 hosts.json 没有分组时间戳。缺失时用纪元，避免每次打开都被当成“刚改过”。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
        updatedByDeviceId = try c.decodeIfPresent(String.self, forKey: .updatedByDeviceId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(parentID, forKey: .parentID)
        try c.encode(sortOrder, forKey: .sortOrder)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(updatedByDeviceId, forKey: .updatedByDeviceId)
    }
}
