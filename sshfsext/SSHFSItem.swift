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
    let path: String
    let parent: FSItem.Identifier
    
    var read = HandleState.closed
    var write = HandleState.closed
    var directoryCookies = Set<UInt64>()
    
    init(parent: FSItem.Identifier, id: FSItem.Identifier, path: String) {
        self.id = id
        self.parent = parent
        self.path = path
    }
    
    func resolve(_ subpath: some StringProtocol) -> String {
        if path.isEmpty {
            String(subpath)
        } else {
            path + "/" + subpath
        }
    }
}
