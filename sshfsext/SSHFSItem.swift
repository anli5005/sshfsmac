//
//  SSHFSItem.swift
//  sshfsmac
//
//  Created by Anthony Li on 5/26/26.
//

import FSKit

enum HandleState {
    case closed
    case pending(Task<Data, Error>)
    case open(Data)
}

class SSHFSItem: FSItem {
    let id: FSItem.Identifier
    var path: String?
    let parent: FSItem.Identifier
    var name: FSFileName
    
    var read = HandleState.closed
    var write = HandleState.closed
    var directoryCookies = Set<UInt64>()
    
    init(parent: FSItem.Identifier, id: FSItem.Identifier, path: String, name: FSFileName) {
        self.id = id
        self.parent = parent
        self.path = path
        self.name = name
    }
    
    func resolve(_ subpath: some StringProtocol) -> String? {
        guard let path else {
            return nil
        }
        
        if path.isEmpty {
            return String(subpath)
        } else if path == "/" {
            return path + subpath
        } else {
            return path + "/" + subpath
        }
    }
}
