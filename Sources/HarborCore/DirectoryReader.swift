import Darwin
import Foundation

public struct DirectoryReadError: Error, Sendable {
    public let code: Int32

    public var isPermissionDenied: Bool { code == EACCES || code == EPERM }
    public var isMissing: Bool { code == ENOENT || code == ENOTDIR }
    public var message: String { String(cString: strerror(code)) }
}

/// 用 getattrlistbulk 一次系统调用批量读出一批条目的名称、类型、时间、大小，
/// 比 FileManager 逐个取属性快得多（数据见 HarborBench）。
public enum DirectoryReader {
    private static let bufferSize = 256 * 1024

    public static func read(_ directory: URL) throws(DirectoryReadError) -> [FileItem] {
        let fd = open(directory.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw DirectoryReadError(code: errno) }
        defer { close(fd) }

        // 请求的属性。缓冲区里按位值从小到大排列，RETURNED_ATTRS 永远排第一
        let common: attrgroup_t = attr(ATTR_CMN_RETURNED_ATTRS) | attr(ATTR_CMN_NAME) | attr(ATTR_CMN_OBJTYPE)
            | attr(ATTR_CMN_CRTIME) | attr(ATTR_CMN_MODTIME) | attr(ATTR_CMN_FLAGS)
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = common
        request.fileattr = attr(ATTR_FILE_DATALENGTH)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var items: [FileItem] = []
        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw DirectoryReadError(code: errno)
            }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                if let item = parseEntry(entry + 4) { items.append(item) }
                entry += length
            }
        }
        return items
    }

    /// 没有 FSOPT_PACK_INVAL_ATTRS 时，没返回的属性不占位置，所以按 returned 位逐个判断
    private static func parseEntry(_ start: UnsafeRawPointer) -> FileItem? {
        var field = start
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size

        guard returned.commonattr & attr(ATTR_CMN_NAME) != 0 else { return nil }
        let ref = field.loadUnaligned(as: attrreference_t.self)
        // attr_length 包含结尾的 NUL
        let nameBytes = UnsafeRawBufferPointer(start: field + Int(ref.attr_dataoffset), count: max(Int(ref.attr_length) - 1, 0))
        let name = String(decoding: nameBytes, as: UTF8.self)
        field += MemoryLayout<attrreference_t>.size

        var objType: fsobj_type_t = 0
        if returned.commonattr & attr(ATTR_CMN_OBJTYPE) != 0 {
            objType = field.loadUnaligned(as: fsobj_type_t.self)
            field += MemoryLayout<fsobj_type_t>.size
        }
        var created = Date(timeIntervalSince1970: 0)
        if returned.commonattr & attr(ATTR_CMN_CRTIME) != 0 {
            created = date(field.loadUnaligned(as: timespec.self))
            field += MemoryLayout<timespec>.size
        }
        var modified = Date(timeIntervalSince1970: 0)
        if returned.commonattr & attr(ATTR_CMN_MODTIME) != 0 {
            modified = date(field.loadUnaligned(as: timespec.self))
            field += MemoryLayout<timespec>.size
        }
        var flags: UInt32 = 0
        if returned.commonattr & attr(ATTR_CMN_FLAGS) != 0 {
            flags = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }
        var size: Int64?
        if returned.fileattr & attr(ATTR_FILE_DATALENGTH) != 0 {
            size = field.loadUnaligned(as: off_t.self)
        }

        let kind: FileItem.Kind = switch objType {
        case VREG.rawValue: .file
        case VDIR.rawValue: .directory
        case VLNK.rawValue: .symlink
        default: .other
        }
        let isPackage = kind == .directory && FileTypes.isPackageExtension((name as NSString).pathExtension)
        return FileItem(
            name: name,
            kind: kind,
            isPackage: isPackage,
            isHidden: name.hasPrefix(".") || flags & UInt32(UF_HIDDEN) != 0,
            size: kind == .directory ? nil : (size ?? 0),
            modified: modified,
            created: created
        )
    }

    private static func attr<T: BinaryInteger>(_ value: T) -> attrgroup_t {
        attrgroup_t(truncatingIfNeeded: value)
    }

    private static func date(_ ts: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000)
    }
}
