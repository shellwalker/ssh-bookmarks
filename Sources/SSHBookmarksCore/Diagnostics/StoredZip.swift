import Foundation

/// 不压缩的 ZIP，方便在没有 Compression 的 Linux 单测里往返检查内容。
public enum StoredZip {
    public static func archive(_ files: [(name: String, data: Data)]) -> Data {
        var locals = Data()
        var central = Data()
        var entries: [(name: Data, data: Data, crc: UInt32, offset: UInt32)] = []
        for file in files {
            let name = Data(file.name.utf8)
            let crc = CRC32.hash(file.data)
            let offset = UInt32(locals.count)
            entries.append((name, file.data, crc, offset))
            locals.append(localHeader(name: name, data: file.data, crc: crc))
            locals.append(file.data)
        }
        let centralStart = UInt32(locals.count)
        for entry in entries {
            central.append(centralHeader(name: entry.name, data: entry.data, crc: entry.crc, offset: entry.offset))
        }
        var result = locals
        result.append(central)
        result.append(endOfCentralDirectory(count: UInt16(entries.count), size: UInt32(central.count), offset: centralStart))
        return result
    }

    private static func localHeader(name: Data, data: Data, crc: UInt32) -> Data {
        var header = Data()
        header.appendU32(0x0403_4B50)
        header.appendU16(20)
        header.appendU16(0)
        header.appendU16(0)
        header.appendU16(0)
        header.appendU16(0)
        header.appendU32(crc)
        header.appendU32(UInt32(data.count))
        header.appendU32(UInt32(data.count))
        header.appendU16(UInt16(name.count))
        header.appendU16(0)
        header.append(name)
        return header
    }

    private static func centralHeader(name: Data, data: Data, crc: UInt32, offset: UInt32) -> Data {
        var header = Data()
        header.appendU32(0x0201_4B50)
        header.appendU16(0x0314)
        header.appendU16(20)
        header.appendU16(0)
        header.appendU16(0)
        header.appendU16(0)
        header.appendU16(0)
        header.appendU32(crc)
        header.appendU32(UInt32(data.count))
        header.appendU32(UInt32(data.count))
        header.appendU16(UInt16(name.count))
        header.appendU16(0)
        header.appendU16(0)
        header.appendU16(0)
        header.appendU16(0)
        header.appendU32(0)
        header.appendU32(offset)
        header.append(name)
        return header
    }

    private static func endOfCentralDirectory(count: UInt16, size: UInt32, offset: UInt32) -> Data {
        var header = Data()
        header.appendU32(0x0605_4B50)
        header.appendU16(0)
        header.appendU16(0)
        header.appendU16(count)
        header.appendU16(count)
        header.appendU32(size)
        header.appendU32(offset)
        header.appendU16(0)
        return header
    }
}

enum CRC32 {
    static func hash(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }
}

extension Data {
    fileprivate mutating func appendU16(_ value: UInt16) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: 2))
    }

    fileprivate mutating func appendU32(_ value: UInt32) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: 4))
    }
}
