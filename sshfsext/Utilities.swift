//
//  Utilities.swift
//  sshfsmac
//
//  Created by Anthony Li on 5/23/26.
//

import Foundation
import FSKit
import Network

extension Data {
    func readUInt32(at offset: Int) throws -> UInt32 {
        guard offset + MemoryLayout<UInt32>.size <= count else {
            throw POSIXError(.EPIPE)
        }
        
        return withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
    
    func readUInt32(at offset: inout Int) throws -> UInt32 {
        let result = try readUInt32(at: offset)
        offset += MemoryLayout<UInt32>.size
        return result
    }
    
    func readUInt64(at offset: Int) throws -> UInt64 {
        guard offset + MemoryLayout<UInt64>.size <= count else {
            throw POSIXError(.EPIPE)
        }
        
        return withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }
    
    func readUInt64(at offset: inout Int) throws -> UInt64 {
        let result = try readUInt64(at: offset)
        offset += MemoryLayout<UInt64>.size
        return result
    }
    
    func readBytes(at offset: inout Int) throws -> Data {
        let length = try readUInt32(at: &offset)
        guard offset + Int(length) <= count else {
            throw POSIXError(.EPIPE)
        }
        
        let data = self[offset..<offset + Int(length)]
        offset += Int(length)
        return data
    }
    
    func readString(at offset: inout Int) throws -> String {
        let data = try readBytes(at: &offset)
        guard let string = String(data: data, encoding: .utf8) else {
            throw POSIXError(.EIO)
        }
        
        return string
    }
    
    var lengthEncoded: Data {
        var data = Data(capacity: count + MemoryLayout<UInt32>.size)
        data.append(UInt32(count).bytes)
        data.append(self)
        return data
    }
}

extension NetworkFixedWidthInteger {
    var bytes: Data {
        return withUnsafePointer(to: bigEndian) { pointer in
            Data(bytes: pointer, count: MemoryLayout<Self>.size)
        }
    }
}

protocol SFTPClientMessage {
    associatedtype Payload: DataProtocol
    
    static var type: UInt8 { get }
    func payload() -> Payload
}

protocol SFTPClientExtensionMessage: SFTPClientMessage, SFTPIdentifiedPacket {
    static var extensionName: String { get }
    func extensionPayload() -> Data
}

extension SFTPClientExtensionMessage {
    static var type: UInt8 { 200 }
    func payload() -> Data {
        id.bytes + Self.extensionName.data(using: .utf8)!.lengthEncoded + extensionPayload()
    }
}

protocol SFTPIdentifiedPacket {
    var id: UInt32 { get }
}

protocol SFTPServerReply {
    static var type: UInt8 { get }
    static func parse(from buffer: Data) -> Self?
}

struct SFTPInitPacket: SFTPClientMessage {
    static var type: UInt8 { 1 }
    
    func payload() -> some DataProtocol {
        let version: UInt32 = 3
        return version.bytes
    }
}

struct SFTPOpenRequest: SFTPClientMessage, SFTPIdentifiedPacket {
    static var type: UInt8 { 3 }
    
    struct Flags: OptionSet {
        var rawValue: UInt32
        
        static let read = Flags(rawValue: 0x00000001)
        static let write = Flags(rawValue: 0x00000002)
        static let create = Flags(rawValue: 0x00000008)
        static let exclusiveCreate: Flags = [.create, Flags(rawValue: 0x00000020)]
    }
    
    let id: UInt32
    let path: Data
    let flags: Flags
    let attributes: SFTPAttributes
    
    func payload() -> some DataProtocol {
        id.bytes + path.lengthEncoded + flags.rawValue.bytes + attributes.encode()
    }
}

struct SFTPCloseRequest: SFTPClientMessage, SFTPIdentifiedPacket {
    static var type: UInt8 { 4 }
    
    let id: UInt32
    let handle: Data
    
    func payload() -> some DataProtocol {
        id.bytes + handle.lengthEncoded
    }
}

struct SFTPReadRequest: SFTPClientMessage, SFTPIdentifiedPacket {
    static var type: UInt8 { 5 }
    
    let id: UInt32
    let handle: Data
    let offset: UInt64
    let length: UInt32
    
    func payload() -> some DataProtocol {
        id.bytes + handle.lengthEncoded + offset.bytes + length.bytes
    }
}

struct SFTPWriteRequest: SFTPClientMessage, SFTPIdentifiedPacket {
    static var type: UInt8 { 6 }
    
    let id: UInt32
    let handle: Data
    let offset: UInt64
    let data: Data
    
    func payload() -> some DataProtocol {
        id.bytes + handle.lengthEncoded + offset.bytes + data.lengthEncoded
    }
}

struct SFTPLStatRequest: SFTPClientMessage, SFTPIdentifiedPacket {
    static var type: UInt8 { 7 }
    
    let id: UInt32
    let path: Data
    
    func payload() -> some DataProtocol {
        id.bytes + path.lengthEncoded
    }
}

struct SFTPSetStatRequest: SFTPClientMessage, SFTPIdentifiedPacket {
    static var type: UInt8 { 9 }
    
    let id: UInt32
    let path: Data
    let attributes: SFTPAttributes
    
    func payload() -> some DataProtocol {
        id.bytes + path.lengthEncoded + attributes.encode()
    }
}

struct SFTPOpenDirRequest: SFTPClientMessage, SFTPIdentifiedPacket {
    static var type: UInt8 { 11 }
    
    let id: UInt32
    let path: Data
    
    func payload() -> some DataProtocol {
        id.bytes + path.lengthEncoded
    }
}

struct SFTPReadDirRequest: SFTPClientMessage, SFTPIdentifiedPacket {
    static var type: UInt8 { 12 }
    
    let id: UInt32
    let handle: Data
    
    func payload() -> some DataProtocol {
        id.bytes + handle.lengthEncoded
    }
}

struct SFTPRemoveRequest: SFTPClientMessage, SFTPIdentifiedPacket {
    static var type: UInt8 { 13 }
    
    let id: UInt32
    let path: Data
    
    func payload() -> some DataProtocol {
        id.bytes + path.lengthEncoded
    }
}

struct SFTPMkdirRequest: SFTPClientMessage, SFTPIdentifiedPacket {
    static var type: UInt8 { 14 }
    
    let id: UInt32
    let path: Data
    let attributes: SFTPAttributes
    
    func payload() -> some DataProtocol {
        id.bytes + path.lengthEncoded + attributes.encode()
    }
}

struct SFTPRmdirRequest: SFTPClientMessage, SFTPIdentifiedPacket {
    static var type: UInt8 { 15 }
    
    let id: UInt32
    let path: Data
    
    func payload() -> some DataProtocol {
        id.bytes + path.lengthEncoded
    }
}

struct SFTPRealPathRequest: SFTPClientMessage, SFTPIdentifiedPacket {
    static var type: UInt8 { 16 }
    
    let id: UInt32
    let path: Data
    
    func payload() -> some DataProtocol {
        id.bytes + path.lengthEncoded
    }
}

struct SFTPReadLinkRequest: SFTPClientMessage, SFTPIdentifiedPacket {
    static var type: UInt8 { 19 }
    
    let id: UInt32
    let path: Data
    
    func payload() -> some DataProtocol {
        id.bytes + path.lengthEncoded
    }
}

struct SFTPSymlinkRequest: SFTPClientMessage, SFTPIdentifiedPacket {
    static var type: UInt8 { 19 }
    
    let id: UInt32
    let linkPath: Data
    let targetPath: Data
    let useOpenSSHQuirks: Bool
    
    func payload() -> some DataProtocol {
        if useOpenSSHQuirks {
            return id.bytes + targetPath.lengthEncoded + linkPath.lengthEncoded
        } else {
            return id.bytes + linkPath.lengthEncoded + targetPath.lengthEncoded
        }
    }
}

struct SFTPPOSIXRenameRequest: SFTPClientExtensionMessage {
    static var extensionName: String { "posix-rename@openssh.com" }
    let id: UInt32
    
    let oldPath: Data
    let newPath: Data
    
    func extensionPayload() -> Data {
        oldPath.lengthEncoded + newPath.lengthEncoded
    }
}

struct SFTPHardLinkRequest: SFTPClientExtensionMessage {
    static var extensionName: String { "hardlink@openssh.com" }
    let id: UInt32
    
    let existingPath: Data
    let newPath: Data
    
    func extensionPayload() -> Data {
        existingPath.lengthEncoded + newPath.lengthEncoded
    }
}

struct SFTPStatusReply: SFTPServerReply, SFTPIdentifiedPacket {
    static var type: UInt8 { 101 }
    
    let id: UInt32
    let code: UInt32
    
    static func parse(from buffer: Data) -> SFTPStatusReply? {
        guard let id = try? buffer.readUInt32(at: 0),
              let code = try? buffer.readUInt32(at: 4) else {
            return nil
        }
        
        return .init(id: id, code: code)
    }
}

struct SFTPHandleReply: SFTPServerReply, SFTPIdentifiedPacket {
    static var type: UInt8 { 102 }
    
    let id: UInt32
    let handle: Data
    
    static func parse(from buffer: Data) -> SFTPHandleReply? {
        var offset = 4
        guard let id = try? buffer.readUInt32(at: 0),
              let handle = try? buffer.readBytes(at: &offset) else {
            return nil
        }
        
        return .init(id: id, handle: handle)
    }
}

struct SFTPDataReply: SFTPServerReply, SFTPIdentifiedPacket {
    static var type: UInt8 { 103 }
    
    let id: UInt32
    let data: Data
    
    static func parse(from buffer: Data) -> SFTPDataReply? {
        var offset = 4
        guard let id = try? buffer.readUInt32(at: 0),
              let data = try? buffer.readBytes(at: &offset) else {
            return nil
        }
        
        return .init(id: id, data: data)
    }
}

struct SFTPNameReply: SFTPServerReply, SFTPIdentifiedPacket {
    static var type: UInt8 { 104 }
    
    let id: UInt32
    let names: [SFTPName]
    
    static func parse(from buffer: Data) -> SFTPNameReply? {
        do {
            var offset = 0
            var names = [SFTPName]()
            
            let id = try buffer.readUInt32(at: &offset)
            let count = try buffer.readUInt32(at: &offset)
            names.reserveCapacity(Int(count))
            
            for _ in 0..<count {
                let name = try buffer.readString(at: &offset)
                _ = try buffer.readBytes(at: &offset)
                let attributes = try SFTPAttributes.parse(from: buffer, at: &offset)
                names.append(SFTPName(filename: name, attributes: attributes))
            }
            
            return .init(id: id, names: names)
        } catch {
            return nil
        }
    }
}

struct SFTPAttributesReply: SFTPServerReply, SFTPIdentifiedPacket {
    static var type: UInt8 { 105 }
    
    let id: UInt32
    let attributes: SFTPAttributes
    
    static func parse(from buffer: Data) -> SFTPAttributesReply? {
        do {
            var offset = 0
            
            let id = try buffer.readUInt32(at: &offset)
            let attributes = try SFTPAttributes.parse(from: buffer, at: &offset)
            
            return .init(id: id, attributes: attributes)
        } catch {
            return nil
        }
    }
}

struct SFTPAttributes {
    var size: UInt64?
    var ownership: (uid: UInt32, gid: UInt32)?
    var permissions: UInt32?
    var times: (a: UInt32, m: UInt32)?
    
    struct Flags: OptionSet {
        var rawValue: UInt32
        
        static let size = Flags(rawValue: 0x00000001)
        static let uidgid = Flags(rawValue: 0x00000002)
        static let permissions = Flags(rawValue: 0x00000004)
        static let acmodtime = Flags(rawValue: 0x00000008)
        static let extended = Flags(rawValue: 0x80000000)
    }
    
    var isEmpty: Bool {
        size == nil && ownership == nil && permissions == nil && times == nil
    }
    
    func encode() -> Data {
        var buffer = Data()
        
        var flags = Flags(rawValue: 0)
        
        if let size {
            flags.insert(.size)
            buffer.append(size.bytes)
        }
        
        if let ownership {
            flags.insert(.uidgid)
            buffer.append(ownership.uid.bytes)
            buffer.append(ownership.gid.bytes)
        }
        
        if let permissions {
            flags.insert(.permissions)
            buffer.append(permissions.bytes)
        }
        
        if let times {
            flags.insert(.acmodtime)
            buffer.append(times.a.bytes)
            buffer.append(times.m.bytes)
        }
        
        return flags.rawValue.bytes + buffer
    }
    
    static func parse(from buffer: Data, at offset: inout Int) throws -> SFTPAttributes {
        var attributes = Self()
        let flags = Flags(rawValue: try buffer.readUInt32(at: &offset))
        
        if flags.contains(.size) {
            attributes.size = try buffer.readUInt64(at: &offset)
        }
        
        if flags.contains(.uidgid) {
            let uid = try buffer.readUInt32(at: &offset)
            let gid = try buffer.readUInt32(at: &offset)
            attributes.ownership = (uid, gid)
        }
        
        if flags.contains(.permissions) {
            attributes.permissions = try buffer.readUInt32(at: &offset)
        }
        
        if flags.contains(.acmodtime) {
            let a = try buffer.readUInt32(at: &offset)
            let m = try buffer.readUInt32(at: &offset)
            attributes.times = (a, m)
        }
        
        if flags.contains(.extended) {
            let extendedCount = try buffer.readUInt32(at: &offset)
            for _ in 0..<extendedCount {
                _ = try buffer.readBytes(at: &offset)
                _ = try buffer.readBytes(at: &offset)
            }
        }
        
        return attributes
    }
}

extension SFTPAttributes {
    var type: FSItem.ItemType {
        guard let permissions else {
            return .file
        }
        
        switch permissions & UInt32(S_IFMT) {
        case UInt32(S_IFDIR):
            return .directory
        case UInt32(S_IFLNK):
            return .symlink
        case UInt32(S_IFBLK):
            return .blockDevice
        case UInt32(S_IFCHR):
            return .charDevice
        case UInt32(S_IFIFO):
            return .file
        case UInt32(S_IFREG):
            return .file
        case UInt32(S_IFSOCK):
            return .socket
        default:
            return .unknown
        }
    }
    
    mutating func apply(request: FSItem.SetAttributesRequest) {
        if request.isValid(.size) {
            size = request.size
            request.consumedAttributes.insert(.size)
        }
        
        if request.isValid(.mode) {
            permissions = request.mode
            request.consumedAttributes.insert(.mode)
        }
        
        if request.isValid(.uid), request.isValid(.gid) {
            ownership = (uid: request.uid, gid: request.gid)
            request.consumedAttributes.formUnion([.uid, .gid])
        }
        
        if request.isValid(.accessTime), request.isValid(.modifyTime) {
            times = (a: UInt32(request.accessTime.tv_sec), m: UInt32(request.modifyTime.tv_sec))
            request.consumedAttributes.formUnion([.accessTime, .modifyTime])
        }
    }
    
    func toFSKitAttributes(request: FSItem.GetAttributesRequest?, identifier: FSItem.Identifier, parent: FSItem.Identifier) -> FSItem.Attributes {
        let attributes = FSItem.Attributes()
        
        if request?.isAttributeWanted(.type) != false {
            attributes.type = type
        }
        
        if request?.isAttributeWanted(.mode) != false {
            attributes.mode = permissions ?? UInt32(S_IFREG | 0o777)
        }
        
        if request?.isAttributeWanted(.size) != false {
            attributes.size = size ?? 0
        }
        
        if request?.isAttributeWanted(.fileID) != false {
            attributes.fileID = identifier
        }
        
        if request?.isAttributeWanted(.parentID) != false {
            attributes.parentID = parent
        }
        
        if request?.isAttributeWanted(.flags) != false {
            attributes.flags = 0
        }
        
        let times = times ?? (0, 0)
                
        if request?.isAttributeWanted(.accessTime) != false {
            attributes.accessTime = timespec(tv_sec: time_t(times.a), tv_nsec: 0)
        }
        
        if request?.isAttributeWanted(.modifyTime) != false {
            attributes.modifyTime = timespec(tv_sec: time_t(times.m), tv_nsec: 0)
        }
        
        let ownership = ownership ?? (0, 0)
        
        if request?.isAttributeWanted(.uid) != false {
            attributes.uid = ownership.uid
        }
        
        if request?.isAttributeWanted(.gid) != false {
            attributes.gid = ownership.gid
        }
        
        return attributes
    }
}

struct SFTPName {
    let filename: String
    let attributes: SFTPAttributes
}

let replyTypes: [SFTPServerReply.Type] = [
    SFTPStatusReply.self,
    SFTPHandleReply.self,
    SFTPDataReply.self,
    SFTPNameReply.self,
    SFTPAttributesReply.self
]

extension FileHandle {
    func write<Packet: SFTPClientMessage>(packet: Packet) throws {
        var header = Data(capacity: 5)
        let payload = packet.payload()
        
        header.append(UInt32(payload.count + 1).bytes)
        header.append(Packet.type)
        try write(contentsOf: header)
        try write(contentsOf: payload)
    }
    
    func read(bytes: Int) throws -> Data {
        var data = Data(capacity: bytes)
        while data.count < bytes {
            let part = try read(upToCount: bytes - data.count)
            guard let part, !part.isEmpty else {
                throw POSIXError(.EPIPE)
            }
            
            data.append(part)
        }
        
        return data
    }
    
    func readReply() throws -> any SFTPServerReply {
        let lengthData = try read(bytes: 4)
        let length = try lengthData.readUInt32(at: 0)
        if length == 0 {
            throw POSIXError(.EIO)
        }
        
        let remainingData = try read(bytes: Int(length))
        let type = remainingData[0]
        
        guard let replyType = replyTypes.first(where: { $0.type == type }) else {
            throw POSIXError(.EIO)
        }
        
        guard let reply = replyType.parse(from: Data(remainingData[1..<remainingData.count])) else {
            throw POSIXError(.EIO)
        }
        
        return reply
    }
}
