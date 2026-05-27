//
//  socket.h
//  sshfsmac
//
//  Created by Anthony Li on 5/22/26.
//

#ifndef SSHFSXPC_SOCKET_H
#define SSHFSXPC_SOCKET_H

struct socketpair_result {
    int clientfd;
    int sshfd;
};

int get_socket_pair(struct socketpair_result *result);

#endif
