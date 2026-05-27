//
//  sshfsxpcProtocol.swift
//  sshfsxpc
//
//  Created by Anthony Li on 5/22/26.
//

import Foundation

/// The protocol that this service will vend as its API. This protocol will also need to be visible to the process hosting the service.
@objc protocol sshfsxpcProtocol {
    func connect(to url: URL, with reply: @escaping (FileHandle?, NSError?) -> Void)
    func hello(with reply: @escaping () -> Void)
}

/*
 To use the service from an application or other process, use NSXPCConnection to establish a connection to the service by doing something like this:
 
 connectionToService = NSXPCConnection(serviceName: "dev.anli.macos.sshfsmac.sshfsxpc")
 connectionToService.remoteObjectInterface = NSXPCInterface(with: (any sshfsxpcProtocol).self)
 connectionToService.resume()
 
 Once you have a connection to the service, you can use it like this:
 
 if let proxy = connectionToService.remoteObjectProxy as? sshfsxpcProtocol {
 proxy.performCalculation(firstNumber: 23, secondNumber: 19) { result in
 NSLog("Result of calculation is: \(result)")
 }
 }
 
 And, when you are finished with the service, clean up the connection like this:
 
 connectionToService.invalidate()
 */
