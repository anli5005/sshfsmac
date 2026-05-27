//
//  socket.c
//  sshfsmac
//
//  Created by Anthony Li on 5/22/26.
//

#include "socket.h"

#include <sys/socket.h>

int get_socket_pair(struct socketpair_result *result) {
    int fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == -1) return -1;
    result->clientfd = fds[0];
    result->sshfd = fds[1];
    return 0;
}
