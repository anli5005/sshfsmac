//
//  sshfsext.swift
//  sshfsext
//
//  Created by Anthony Li on 5/22/26.
//

import ExtensionFoundation
import Foundation
import FSKit

@main
struct sshfsext : UnaryFileSystemExtension {
    var fileSystem : FSUnaryFileSystem & FSUnaryFileSystemOperations {
        sshfsextFileSystem()
    }
}
