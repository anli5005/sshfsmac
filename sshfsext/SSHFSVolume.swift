//
//  SSHFSVolume.swift
//  sshfsmac
//
//  Created by Anthony Li on 5/23/26.
//

import FSKit

enum EOFError: Error {
    case eof
}

enum PendingRequest {
    case awaitingContinuation
    case status(CheckedContinuation<Void, Error>)
    case attrs(CheckedContinuation<SFTPAttributes, Error>)
    case handle(CheckedContinuation<Data, Error>)
    case data(CheckedContinuation<Data, Error>)
    case name(CheckedContinuation<[SFTPName], Error>)
}

func mapStatusToError(code: UInt32) -> Error {
    switch code {
    case 1:
        EOFError.eof
    case 2:
        POSIXError(.ENOENT)
    case 3:
        POSIXError(.EACCES)
    case 8:
        POSIXError(.ENOTSUP)
    default:
        POSIXError(.EIO)
    }
}

@globalActor actor SocketWriterActor {
    static let shared = SocketWriterActor()
    
    private init() {}
}

class SSHFSVolume: FSVolume, @unchecked Sendable {
    private let socket: FileHandle
    var requestedMountOptions = FSVolume.MountOptions.readOnly
    var xattrOperationsInhibited = false
    var blocksDSStore = false
    @MainActor private var pendingRequests = [UInt32: PendingRequest]()
    @MainActor private var isOpen = true
    @MainActor private var nextID: UInt32 = 0
    @MainActor private var fileIDAssignments = [String: FSItem.Identifier]()
    @MainActor private var fileItemAssignments = [String: SSHFSItem]()
    @MainActor private var nextFileID: UInt64 = 3
    @MainActor private var directoryCookies = [UInt64: (Data, [SFTPName])]()
    @MainActor private var nextCookie: UInt64 = 1
    
    let supportsHardlinks: Bool
    let useOpenSSHQuirks = true
    let base: String
    
    init(identifier: FSVolume.Identifier, name: FSFileName, socket: FileHandle, base: String, extensions: [(String, String)]) throws {
        if !extensions.contains(where: { $0.0 == SFTPPOSIXRenameRequest.extensionName && $0.1 == "1" }) {
            throw POSIXError(.ENOTSUP)
        }
        
        self.socket = socket
        self.supportsHardlinks = extensions.contains(where: { $0.0 == "hardlink@openssh.com" && $0.1 == "1" })
        self.base = base
        super.init(volumeID: identifier, volumeName: name)
    }
    
    @MainActor func assignID() -> UInt32 {
        let prevID = nextID
        repeat {
            let id = nextID
            nextID &+= 1
            
            if pendingRequests[id] == nil {
                pendingRequests[id] = .awaitingContinuation
                return id
            }
        } while prevID != nextID
        
        fatalError("Ran out of request IDs")
    }
    
    @MainActor func releaseID(_ id: UInt32) {
        pendingRequests[id] = nil
    }
    
    @MainActor private func dispatch(reply: any SFTPServerReply) {
        switch reply {
        case let status as SFTPStatusReply:
            switch pendingRequests.removeValue(forKey: status.id) {
            case .status(let continuation):
                if status.code == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: mapStatusToError(code: status.code))
                }
            case .name(let continuation):
                continuation.resume(throwing: mapStatusToError(code: status.code))
            case .attrs(let continuation):
                continuation.resume(throwing: mapStatusToError(code: status.code))
            case .handle(let continuation):
                continuation.resume(throwing: mapStatusToError(code: status.code))
            case .data(let continuation):
                continuation.resume(throwing: mapStatusToError(code: status.code))
            case .awaitingContinuation, nil:
                break
            }
        case let name as SFTPNameReply:
            switch pendingRequests.removeValue(forKey: name.id) {
            case .status(let continuation):
                continuation.resume(throwing: POSIXError(.EIO))
            case .name(let continuation):
                continuation.resume(returning: name.names)
            case .attrs(let continuation):
                continuation.resume(throwing: POSIXError(.EIO))
            case .handle(let continuation):
                continuation.resume(throwing: POSIXError(.EIO))
            case .data(let continuation):
                continuation.resume(throwing: POSIXError(.EIO))
            case .awaitingContinuation, nil:
                break
            }
        case let attrs as SFTPAttributesReply:
            switch pendingRequests.removeValue(forKey: attrs.id) {
            case .status(let continuation):
                continuation.resume(throwing: POSIXError(.EIO))
            case .name(let continuation):
                continuation.resume(throwing: POSIXError(.EIO))
            case .attrs(let continuation):
                continuation.resume(returning: attrs.attributes)
            case .handle(let continuation):
                continuation.resume(throwing: POSIXError(.EIO))
            case .data(let continuation):
                continuation.resume(throwing: POSIXError(.EIO))
            case .awaitingContinuation, nil:
                break
            }
        case let handle as SFTPHandleReply:
            switch pendingRequests.removeValue(forKey: handle.id) {
            case .status(let continuation):
                continuation.resume(throwing: POSIXError(.EIO))
            case .name(let continuation):
                continuation.resume(throwing: POSIXError(.EIO))
            case .attrs(let continuation):
                continuation.resume(throwing: POSIXError(.EIO))
            case .handle(let continuation):
                continuation.resume(returning: handle.handle)
            case .data(let continuation):
                continuation.resume(throwing: POSIXError(.EIO))
            case .awaitingContinuation, nil:
                break
            }
        case let data as SFTPDataReply:
            switch pendingRequests.removeValue(forKey: data.id) {
            case .status(let continuation):
                continuation.resume(throwing: POSIXError(.EIO))
            case .name(let continuation):
                continuation.resume(throwing: POSIXError(.EIO))
            case .attrs(let continuation):
                continuation.resume(throwing: POSIXError(.EIO))
            case .handle(let continuation):
                continuation.resume(throwing: POSIXError(.EIO))
            case .data(let continuation):
                continuation.resume(returning: data.data)
            case .awaitingContinuation, nil:
                break
            }
        default:
            break
        }
    }
    
    @SocketWriterActor func send(_ packet: any SFTPClientMessage) throws {
        try socket.write(packet: packet)
    }
    
    @SocketWriterActor func sendAndWaitForStatus(_ packet: any SFTPClientMessage & SFTPIdentifiedPacket) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.sync {
                pendingRequests[packet.id] = .status(continuation)
            }
            
            do {
                try send(packet)
            } catch {
                DispatchQueue.main.sync {
                    pendingRequests[packet.id] = nil
                }
                
                continuation.resume(throwing: error)
            }
        }
    }
    
    @SocketWriterActor func sendAndWaitForAttrs(_ packet: any SFTPClientMessage & SFTPIdentifiedPacket) async throws -> SFTPAttributes {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.sync {
                pendingRequests[packet.id] = .attrs(continuation)
            }
            
            do {
                try send(packet)
            } catch {
                DispatchQueue.main.sync {
                    pendingRequests[packet.id] = nil
                }
                
                continuation.resume(throwing: error)
            }
        }
    }
    
    @SocketWriterActor func
    sendAndWaitForName(_ packet: any SFTPClientMessage & SFTPIdentifiedPacket) async throws -> [SFTPName] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.sync {
                pendingRequests[packet.id] = .name(continuation)
            }
            
            do {
                try send(packet)
            } catch {
                DispatchQueue.main.sync {
                    pendingRequests[packet.id] = nil
                }
                
                continuation.resume(throwing: error)
            }
        }
    }
    
    @SocketWriterActor func sendAndWaitForData(_ packet: any SFTPClientMessage & SFTPIdentifiedPacket) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.sync {
                pendingRequests[packet.id] = .data(continuation)
            }
            
            do {
                try send(packet)
            } catch {
                DispatchQueue.main.sync {
                    pendingRequests[packet.id] = nil
                }
                
                continuation.resume(throwing: error)
            }
        }
    }
    
    @SocketWriterActor func sendAndWaitForHandle(_ packet: any SFTPClientMessage & SFTPIdentifiedPacket) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.sync {
                pendingRequests[packet.id] = .handle(continuation)
            }
            
            do {
                try send(packet)
            } catch {
                DispatchQueue.main.sync {
                    pendingRequests[packet.id] = nil
                }
                
                continuation.resume(throwing: error)
            }
        }
    }
    
    private func processReplies() {
        while true {
            let isOpen = DispatchQueue.main.sync { self.isOpen }
            if !isOpen {
                break
            }
            
            do {
                let packet = try socket.readReply()
                DispatchQueue.main.sync {
                    dispatch(reply: packet)
                }
            } catch {
                continue
            }
        }
    }
    
    @MainActor private func identifier(for path: String) -> FSItem.Identifier {
        if let assignment = fileIDAssignments[path] {
            return assignment
        }
        
        let identifier = FSItem.Identifier(rawValue: nextFileID)!
        nextFileID += 1
        
        fileIDAssignments[path] = identifier
        return identifier
    }
}

extension SSHFSVolume: FSVolume.Operations {
    func activate(options: FSTaskOptions) async throws -> FSItem {
        if options.taskOptions.contains(["-o", "ro"]) || options.taskOptions.contains(["-o", "rdonly"]) {
            requestedMountOptions.insert(.readOnly)
        } else {
            requestedMountOptions.remove(.readOnly)
        }
        
        if options.taskOptions.contains(["-o", "nodsstore"]) {
            blocksDSStore = true
        }
        
        await MainActor.run {
            fileIDAssignments[base] = .rootDirectory
        }
        
        DispatchQueue.global().async {
            self.processReplies()
        }
        
        let item = SSHFSItem(parent: .parentOfRoot, id: .rootDirectory, path: base, name: FSFileName(string: ""))
        await MainActor.run {
            fileItemAssignments[base] = item
        }
        
        return item
    }
    
    func deactivate(options: FSDeactivateOptions = []) async throws {
        await MainActor.run {
            isOpen = false
        }
        
        try socket.close()
    }
    
    func mount(options: FSTaskOptions) async throws {}
    
    func unmount() async {}
    
    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest) async throws -> (FSItem, FSFileName) {
        var attributes = SFTPAttributes()
        attributes.apply(request: newAttributes)
        
        guard let name = name.string, let directory = directory as? SSHFSItem else {
            throw POSIXError(.EINVAL)
        }
        
        if blocksDSStore, name == ".DS_Store" {
            throw POSIXError(.EPERM)
        }
        
        guard let path = directory.resolve(name),  let pathData = path.data(using: .utf8) else {
            throw POSIXError(.EINVAL)
        }
        
        switch type {
        case .file:
            let packet = SFTPOpenRequest(id: await assignID(), path: pathData, flags: [.read, .exclusiveCreate], attributes: attributes)
            let handle = try await sendAndWaitForHandle(packet)
            
            Task {
                try await sendAndWaitForStatus(SFTPCloseRequest(id: assignID(), handle: handle))
            }
        case .directory:
            let packet = SFTPMkdirRequest(id: await assignID(), path: pathData, attributes: attributes)
            try await sendAndWaitForStatus(packet)
        case .symlink:
            throw POSIXError(.EINVAL)
        default:
            throw POSIXError(.ENOTSUP)
        }
        
        let fskitName = FSFileName(string: name)
        let item = SSHFSItem(parent: directory.id, id: await identifier(for: path), path: path, name: fskitName)
        await MainActor.run {
            fileItemAssignments[path] = item
        }
        
        return (item, fskitName)
    }
    
    func lookupItem(named name: FSFileName, inDirectory directory: FSItem) async throws -> (FSItem, FSFileName) {
        guard let name = name.string, let directory = directory as? SSHFSItem, let path = directory.resolve(name) else {
            throw POSIXError(.EINVAL)
        }
        
        if let item = await fileItemAssignments[path] {
            return (item, item.name)
        }
        
        guard let pathData = path.data(using: .utf8) else {
            throw POSIXError(.EINVAL)
        }
        
        async let names = sendAndWaitForName(SFTPRealPathRequest(id: assignID(), path: pathData))
        _ = try await sendAndWaitForAttrs(SFTPLStatRequest(id: assignID(), path: pathData))
        
        guard let realPath = try await names.first?.filename else {
            throw POSIXError(.EIO)
        }
        
        let realName = realPath.split(separator: "/").last ?? ""
        guard let itemPath = directory.resolve(realName) else {
            throw POSIXError(.EIO)
        }
        
        let fskitName = FSFileName(string: String(realName))
        let item = await MainActor.run {
            let item = SSHFSItem(parent: directory.id, id: identifier(for: itemPath), path: itemPath, name: fskitName)
            fileItemAssignments[itemPath] = item
            return item
        }
        
        return (item, fskitName)
    }
    
    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem) async throws {
        guard let item = item as? SSHFSItem, let name = name.string, let directory = directory as? SSHFSItem, let path = directory.resolve(name), let pathData = path.data(using: .utf8) else {
            throw POSIXError(.EINVAL)
        }
        
        let attributes = try await sendAndWaitForAttrs(SFTPLStatRequest(id: assignID(), path: pathData))
        if attributes.type == .directory {
            try await sendAndWaitForStatus(SFTPRmdirRequest(id: assignID(), path: pathData))
        } else {
            try await sendAndWaitForStatus(SFTPRemoveRequest(id: assignID(), path: pathData))
        }
        
        item.path = nil
    }
    
    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?) async throws -> FSFileName {
        guard let item = item as? SSHFSItem, let sourceDirectory = sourceDirectory as? SSHFSItem, let sourceName = sourceName.string, let destinationDirectory = destinationDirectory as? SSHFSItem, let destinationName = destinationName.string, let sourcePath = sourceDirectory.resolve(sourceName) else {
            throw POSIXError(.EINVAL)
        }
        
        guard let sourcePathData = sourcePath.data(using: .utf8) else {
            throw POSIXError(.EIO)
        }
        
        guard let destinationPath = destinationDirectory.resolve(destinationName), let destinationPathData = destinationPath.data(using: .utf8) else {
            throw POSIXError(.EINVAL)
        }
        
        try await sendAndWaitForStatus(SFTPPOSIXRenameRequest(id: assignID(), oldPath: sourcePathData, newPath: destinationPathData))
        item.path = destinationPath
        
        let fskitName = FSFileName(string: destinationName)
        item.name = fskitName
        
        await MainActor.run {
            fileItemAssignments[sourcePath] = nil
            fileItemAssignments[destinationPath] = item
        }
        
        return fskitName
    }
    
    func reclaimItem(_ item: FSItem) async throws {
        guard let item = item as? SSHFSItem else {
            throw POSIXError(.EINVAL)
        }
        
        let handles = await MainActor.run {
            let handles = item.directoryCookies.compactMap {
                directoryCookies[$0]?.0
            }
            
            item.directoryCookies.forEach { directoryCookies.removeValue(forKey: $0) }
            item.directoryCookies.removeAll()
            return handles
        }
        
        try await withThrowingTaskGroup { group in
            handles.forEach { handle in
                group.addTask {
                    try await self.sendAndWaitForStatus(SFTPCloseRequest(id: self.assignID(), handle: handle))
                }
            }
            
            try await group.waitForAll()
        }
    }
    
    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem) async throws -> FSFileName {
        guard supportsHardlinks else {
            throw POSIXError(.ENOTSUP)
        }
        
        guard let item = item as? SSHFSItem, let directory = directory as? SSHFSItem, let name = name.string, let itemPath = item.path else {
            throw POSIXError(.EINVAL)
        }
        
        guard let existingPathData = itemPath.data(using: .utf8) else {
            throw POSIXError(.EIO)
        }
        
        guard let newPath = directory.resolve(name), let newPathData = newPath.data(using: .utf8) else {
            throw POSIXError(.EINVAL)
        }
        
        try await sendAndWaitForStatus(SFTPHardLinkRequest(id: assignID(), existingPath: existingPathData, newPath: newPathData))
        return FSFileName(string: name)
    }
    
    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName) async throws -> (FSItem, FSFileName) {
        guard let name = name.string, let directory = directory as? SSHFSItem else {
            throw POSIXError(.EINVAL)
        }
        
        guard let path = directory.resolve(name), let pathData = path.data(using: .utf8) else {
            throw POSIXError(.EINVAL)
        }
        
        let packet = SFTPSymlinkRequest(id: await assignID(), linkPath: pathData, targetPath: contents.data, useOpenSSHQuirks: useOpenSSHQuirks)
        try await sendAndWaitForStatus(packet)
        
        let fskitName = FSFileName(string: name)
        let item = SSHFSItem(parent: directory.id, id: await identifier(for: path), path: path, name: fskitName)
        await MainActor.run {
            fileItemAssignments[path] = item
        }
        
        return (item, fskitName)
    }
    
    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        guard let item = item as? SSHFSItem, let pathData = item.path?.data(using: .utf8) else {
            throw POSIXError(.EINVAL)
        }
        
        let names = try await sendAndWaitForName(SFTPReadLinkRequest(id: assignID(), path: pathData))
        guard let name = names.first?.filename else {
            throw POSIXError(.EIO)
        }
        
        return FSFileName(string: name)
    }
        
    func attributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem) async throws -> FSItem.Attributes {
        guard let item = item as? SSHFSItem, let pathData = item.path?.data(using: .utf8) else {
            throw POSIXError(.EINVAL)
        }
        
        let attrs = try await sendAndWaitForAttrs(SFTPLStatRequest(id: assignID(), path: pathData))
        return attrs.toFSKitAttributes(request: desiredAttributes, identifier: item.id, parent: item.parent)
    }
    
    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem) async throws -> FSItem.Attributes {
        var attributes = SFTPAttributes()
        attributes.apply(request: newAttributes)
        
        guard let item = item as? SSHFSItem, let pathData = item.path?.data(using: .utf8) else {
            throw POSIXError(.EINVAL)
        }
        
        if !attributes.isEmpty {
            try await sendAndWaitForStatus(SFTPSetStatRequest(id: assignID(), path: pathData, attributes: attributes))
        }
        
        let serverAttrs = try await sendAndWaitForAttrs(SFTPLStatRequest(id: assignID(), path: pathData))
        return serverAttrs.toFSKitAttributes(request: nil, identifier: item.id, parent: item.parent)
    }
    
    func enumerateDirectory(_ directory: FSItem, startingAt oldCookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker) async throws -> FSDirectoryVerifier {
        guard let item = directory as? SSHFSItem, let pathData = item.path?.data(using: .utf8) else {
            throw POSIXError(.EINVAL)
        }
        
        let handle: Data
        let newCookie: FSDirectoryCookie
        let unflushedEntries: [SFTPName]
        let verifier = FSDirectoryVerifier.initial
        
        if oldCookie == .initial {
            handle = try await sendAndWaitForHandle(SFTPOpenDirRequest(id: assignID(), path: pathData))
            newCookie = await MainActor.run {
                let cookie = nextCookie
                nextCookie += 1
                
                directoryCookies[cookie] = (handle, [])
                item.directoryCookies.insert(cookie)
                
                return FSDirectoryCookie(cookie)
            }
            
            unflushedEntries = []
        } else {
            let cookieValue = try await MainActor.run {
                guard let theHandle = directoryCookies[oldCookie.rawValue] else {
                    throw FSError(.invalidDirectoryCookie)
                }
                
                return theHandle
            }
            
            handle = cookieValue.0
            newCookie = oldCookie
            unflushedEntries = cookieValue.1
        }
                
        for (i, entry) in unflushedEntries.enumerated() {
            guard let entryPath = item.resolve(entry.filename) else {
                throw POSIXError(.EIO)
            }
            
            let identifier = await identifier(for: entryPath)
            switch packer.pack(name: entry, identifier: identifier, parent: item, attributes: attributes, nextCookie: newCookie) {
            case .outOfSpace:
                await MainActor.run {
                    directoryCookies[newCookie.rawValue] = (handle, Array(unflushedEntries[i..<unflushedEntries.endIndex]))
                }
                
                return verifier
            default:
                break
            }
        }
        
        var names: [SFTPName]
        repeat {
            do {
                names = try await sendAndWaitForName(SFTPReadDirRequest(id: assignID(), handle: handle))
            } catch EOFError.eof {
                names = []
            } catch {
                throw error
            }
            
            for (i, name) in names.enumerated() {
                guard let entryPath = item.resolve(name.filename) else {
                    throw POSIXError(.EIO)
                }
                
                let identifier = await identifier(for: entryPath)
                switch packer.pack(name: name, identifier: identifier, parent: item, attributes: attributes, nextCookie: newCookie) {
                case .outOfSpace:
                    await MainActor.run { [names] in
                        directoryCookies[newCookie.rawValue] = (handle, Array(names[i..<names.endIndex]))
                    }
                    
                    return verifier
                default:
                    break
                }
            }
        } while !names.isEmpty
        
        await MainActor.run {
            item.directoryCookies.remove(newCookie.rawValue)

            Task {
                try await sendAndWaitForStatus(SFTPCloseRequest(id: assignID(), handle: handle))
            }
            
            directoryCookies[newCookie.rawValue] = nil
        }
        
        return verifier
    }
    
    func synchronize(flags: FSSyncFlags) async throws {
        throw POSIXError(.ENOSYS)
    }
    
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsHardLinks = supportsHardlinks
        capabilities.supports64BitObjectIDs = true
        return capabilities
    }
    
    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: "SSHFS")
        return result
    }
}

extension SSHFSVolume: FSVolume.PathConfOperations {
    var maximumLinkCount: Int {
        if supportsHardlinks {
            65000
        } else {
            1
        }
    }
    
    var maximumFileSize: UInt64 {
        UInt64.max
    }
    
    var restrictsOwnershipChanges: Bool {
        true
    }
    
    var truncatesLongNames: Bool {
        false
    }
    
    var maximumNameLength: Int {
        Int(UInt32.max)
    }
    
    var maximumXattrSize: Int {
        4096
    }
}

extension SSHFSVolume: FSVolume.OpenCloseOperations {
    @MainActor private func openReadHandle(for item: SSHFSItem, pathData: Data) async throws {
        switch item.read {
        case .closed:
            break
        case .pending(let task):
            _ = try await task.value
            return
        case .open:
            return
        }
        
        let task = Task {
            do {
                let request = SFTPOpenRequest(id: assignID(), path: pathData, flags: .read, attributes: SFTPAttributes())
                let handle = try await sendAndWaitForHandle(request)
                item.read = .open(handle)
                return handle
            } catch {
                item.read = .closed
                throw error
            }
        }
        
        item.read = .pending(task)
        _ = try await task.value
    }
    
    @MainActor private func openWriteHandle(for item: SSHFSItem, pathData: Data) async throws {
        switch item.write {
        case .closed:
            break
        case .pending(let task):
            _ = try await task.value
            return
        case .open:
            return
        }
        
        let task = Task {
            do {
                let request = SFTPOpenRequest(id: assignID(), path: pathData, flags: .write, attributes: SFTPAttributes())
                let handle = try await sendAndWaitForHandle(request)
                item.write = .open(handle)
                return handle
            } catch {
                item.write = .closed
                throw error
            }
        }
        
        item.write = .pending(task)
        _ = try await task.value
    }
    
    @MainActor private func closeReadHandle(for item: SSHFSItem) async throws {
        var handle: Data
        
        switch item.read {
        case .closed:
            return
        case .pending(let task):
            do {
                handle = try await task.value
            } catch {
                return
            }
        case .open(let data):
            handle = data
        }
        
        let request = SFTPCloseRequest(id: assignID(), handle: handle)
        try await sendAndWaitForStatus(request)
        item.read = .closed
    }
    
    @MainActor private func closeWriteHandle(for item: SSHFSItem) async throws {
        var handle: Data
        
        switch item.write {
        case .closed:
            return
        case .pending(let task):
            do {
                handle = try await task.value
            } catch {
                return
            }
        case .open(let data):
            handle = data
        }
        
        let request = SFTPCloseRequest(id: assignID(), handle: handle)
        try await sendAndWaitForStatus(request)
        item.write = .closed
    }
    
    func openItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
        guard let item = item as? SSHFSItem, let pathData = item.path?.data(using: .utf8) else {
            throw POSIXError(.EINVAL)
        }
        
        var readTask: Task<Void, Error>?
        var writeTask: Task<Void, Error>?
        
        if modes.contains(.read) {
            readTask = Task {
                try await openReadHandle(for: item, pathData: pathData)
            }
        }
        
        if modes.contains(.write) {
            writeTask = Task {
                try await openWriteHandle(for: item, pathData: pathData)
            }
        }
        
        let read = await readTask?.result
        let write = await writeTask?.result
        
        switch (read, write) {
        case (.failure(_), .failure(let error)):
            throw error
        case (.failure(let error), .success):
            try? await closeWriteHandle(for: item)
            throw error
        case (.success, .failure(let error)):
            try? await closeReadHandle(for: item)
            throw error
        default:
            break
        }
    }
    
    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
        guard let item = item as? SSHFSItem else {
            throw POSIXError(.EINVAL)
        }
        
        var readTask: Task<Void, Error>?
        var writeTask: Task<Void, Error>?
        
        if !modes.contains(.read) {
            readTask = Task {
                try await closeReadHandle(for: item)
            }
        }
        
        if !modes.contains(.write) {
            writeTask = Task {
                try await closeWriteHandle(for: item)
            }
        }
        
        let read = await readTask?.result
        let write = await writeTask?.result
        
        try read?.get()
        try write?.get()
    }
}

extension SSHFSVolume: FSVolume.ReadWriteOperations {
    static let maxPayloadLength = 32768
    
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) async throws -> Int {
        let length = min(length, buffer.length)
        
        guard let item = item as? SSHFSItem, length >= 0, case .open(let handle) = item.read else {
            throw POSIXError(.EINVAL)
        }
        
        var localOffset = 0
        let remoteBase = UInt64(offset)
        
        while localOffset < length {
            do {
                let requestedLength = min(Self.maxPayloadLength, length - localOffset)
                let request = SFTPReadRequest(id: await assignID(), handle: handle, offset: remoteBase + UInt64(localOffset), length: UInt32(requestedLength))
                let data = try await sendAndWaitForData(request)
                guard data.count <= requestedLength else {
                    throw POSIXError(.EIO)
                }
                
                try buffer.withUnsafeMutableBytes { destination in
                    guard let destination = destination.baseAddress?.advanced(by: localOffset) else {
                        throw POSIXError(.EINVAL)
                    }
                    
                    try data.withUnsafeBytes { source in
                        guard let source = source.baseAddress else {
                            throw POSIXError(.EINVAL)
                        }
                        
                        memcpy(destination, source, data.count)
                    }
                }
                
                localOffset += data.count
                
                if data.count < requestedLength {
                    break
                }
            } catch EOFError.eof {
                break
            }
        }
        
        return localOffset
    }
    
    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int {
        guard let item = item as? SSHFSItem, case .open(let handle) = item.write else {
            throw POSIXError(.EINVAL)
        }
        
        var localOffset = 0
        let remoteBase = UInt64(offset)
        
        while localOffset < contents.count {
            let payloadLength = min(Self.maxPayloadLength, contents.count - localOffset)
            let payload = Data(contents[localOffset..<(localOffset + payloadLength)])
            let request = SFTPWriteRequest(id: await assignID(), handle: handle, offset: remoteBase + UInt64(localOffset), data: payload)
            try await sendAndWaitForStatus(request)
            localOffset += payloadLength
        }
        
        return localOffset
    }
}

extension SSHFSVolume: FSVolume.XattrOperations {
    func xattrs(of item: FSItem) async throws -> [FSFileName] {
        []
    }
    
    func xattr(named name: FSFileName, of item: FSItem) async throws -> Data {
        throw POSIXError(.ENOSYS)
    }
    
    func setXattr(named name: FSFileName, to value: Data?, on item: FSItem, policy: FSVolume.SetXattrPolicy) async throws {
        throw POSIXError(.ENOSYS)
    }
}

extension FSDirectoryEntryPacker {
    enum PackStatus {
        case skipped
        case packed
        case outOfSpace
    }
    
    func pack(name: SFTPName, identifier: FSItem.Identifier, parent: SSHFSItem, attributes request: FSItem.GetAttributesRequest?, nextCookie: FSDirectoryCookie) -> PackStatus {
        let attributes: FSItem.Attributes?
        
        if let request {
            if name.filename == "." || name.filename == ".." {
                return .skipped
            }
            
            attributes = name.attributes.toFSKitAttributes(request: request, identifier: identifier, parent: parent.id)
        } else {
            attributes = nil
        }
        
        if packEntry(name: FSFileName(string: name.filename), itemType: name.attributes.type, itemID: identifier, nextCookie: nextCookie, attributes: attributes) {
            return .packed
        } else {
            return .outOfSpace
        }
    }
}
