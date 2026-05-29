//
//  sshfsextFileSystem.swift
//  sshfsext
//
//  Created by Anthony Li on 5/22/26.
//

import Foundation
import FSKit
import OSLog

let supportedSchemes = [
    "ssh",
    "sshfs",
    "sftp"
]

@objc
class sshfsextFileSystem : FSUnaryFileSystem & FSUnaryFileSystemOperations {
    let logger = Logger(subsystem: "dev.anli.macos.sshfsext", category: "sshfsextFileSystem")
    
    func probeResource(resource: FSResource) async throws -> FSProbeResult {
        guard let resource = resource as? FSGenericURLResource, let scheme = resource.url.scheme, supportedSchemes.contains(scheme) else {
            return .notRecognized
        }
        
        return .recognized(name: "", containerID: FSContainerIdentifier(uuid: UUID()))
    }
    
    func loadResource(resource: FSResource, options: FSTaskOptions) async throws -> FSVolume {
        containerStatus = .ready
        
        guard let resource = resource as? FSGenericURLResource, let scheme = resource.url.scheme, supportedSchemes.contains(scheme) else {
            throw POSIXError(.ENOTSUP)
        }
        
        let connectionToService = NSXPCConnection(serviceName: "dev.anli.macos.sshfsmac.sshfsxpc")
        connectionToService.remoteObjectInterface = NSXPCInterface(with: (any sshfsxpcProtocol).self)
        connectionToService.resume()
        
        defer {
            connectionToService.invalidate()
        }
                
        if let proxy = connectionToService.remoteObjectProxy as? sshfsxpcProtocol {
            let handle = try await withCheckedThrowingContinuation { continuation in
                proxy.connect(to: resource.url) { (handle, error) in
                    if let handle {
                        continuation.resume(returning: handle)
                    } else {
                        continuation.resume(throwing: error!)
                    }
                }
            }
            
            do {
                try handle.write(packet: SFTPInitPacket())
                
                var data = try handle.read(bytes: 9)
                var length: UInt32
                
                while true {
                    length = try data.readUInt32(at: 0)
                    if length >= 5 && length <= 34000, data[4] == 2, try data.readUInt32(at: 5) == 3 {
                        break
                    }
                    
                    data.removeFirst()
                    data.append(try handle.read(bytes: 1))
                }
                
                var extensions = [(String, String)]()
                if length >= 5 {
                    var offset = 0
                    let extensionData = try handle.read(bytes: Int(length) - 5)
                    
                    while offset < extensionData.count {
                        let name = try extensionData.readString(at: &offset)
                        let data = try extensionData.readString(at: &offset)
                        extensions.append((name, data))
                    }
                }
                
                var path = resource.url.path(percentEncoded: false)
                if path.isEmpty {
                    path = "."
                } else if path.hasSuffix("/") {
                    path.removeLast()
                }
                
                let volume = try SSHFSVolume(identifier: FSVolume.Identifier(uuid: UUID()), name: FSFileName(string: resource.url.host(percentEncoded: false) ?? "SSH Filesystem"), socket: handle, base: path, extensions: extensions)
                
                if options.taskOptions.contains(["-o", "xattrfallback"]) {
                    volume.xattrOperationsInhibited = true
                }
                
                return volume
            } catch {
                try handle.close()
                throw error
            }
        } else {
            throw POSIXError(.EIO)
        }
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {
    }
}
