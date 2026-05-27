//
//  sshfsxpc.swift
//  sshfsxpc
//
//  Created by Anthony Li on 5/22/26.
//

import Foundation
import OSLog

let logger = Logger(subsystem: "dev.anli.macos.sshfsext", category: "sshfsxpc")

/// This object implements the protocol which we have defined. It provides the actual behavior for the service. It is 'exported' by the service to make it available to the process hosting the service over an NSXPCConnection.
class sshfsxpc: NSObject, sshfsxpcProtocol {
    @objc func connect(to url: URL, with reply: @escaping (FileHandle?, NSError?) -> Void) {
        logger.error("GOT REQUEST TO CONNECT \(url)")
        
        var fds = socketpair_result()
        guard get_socket_pair(&fds) != -1 else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh", directoryHint: .notDirectory)
        
        // TODO: Sanitize this
        guard var connectionString = url.host() else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }
        
        if let user = url.user() {
            connectionString = "\(user)@\(connectionString)"
        }
        
        let nullHandle = FileHandle(forReadingAtPath: "/dev/null")!
        let sshSocketHandle = FileHandle(fileDescriptor: fds.sshfd)
        
        process.arguments = ["-x", "-a", connectionString, "-s", "sftp"]
        process.currentDirectoryURL = URL(filePath: "/", directoryHint: .isDirectory)
        process.standardError = nullHandle
        process.standardOutput = sshSocketHandle
        process.standardInput = sshSocketHandle
        
        do {
            try process.run()
        } catch {
            reply(nil, error as NSError)
            return
        }
        
        try! nullHandle.close()
        try! sshSocketHandle.close()
        
        let clientHandle = FileHandle(fileDescriptor: fds.clientfd, closeOnDealloc: true)
        reply(clientHandle, nil)
    }
    
    @objc func hello(with reply: @escaping () -> Void) {
        reply()
    }
}
