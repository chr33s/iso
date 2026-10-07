/* Guest-side canary (Gate O): which host vsock ports accept a connection.
 *     vsock-probe PORT...   -> one JSON object {"port": "open"|"refused"|...}
 * Built on the host (arm64 macOS) and copied into the guest. */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/vsock.h>
#include <unistd.h>

int main(int argc, char **argv) {
    printf("{");
    for (int i = 1; i < argc; i++) {
        unsigned port = (unsigned)strtoul(argv[i], NULL, 10);
        int fd = socket(AF_VSOCK, SOCK_STREAM, 0);
        const char *result = "socket_failed";
        if (fd >= 0) {
            struct sockaddr_vm a;
            memset(&a, 0, sizeof a);
            a.svm_len = sizeof a;
            a.svm_family = AF_VSOCK;
            a.svm_cid = VMADDR_CID_HOST;
            a.svm_port = port;
            if (connect(fd, (struct sockaddr *)&a, sizeof a) == 0) result = "open";
            else if (errno == ECONNREFUSED || errno == ECONNRESET) result = "refused";
            else if (errno == ETIMEDOUT) result = "timeout";
            else result = strerror(errno);
            close(fd);
        }
        printf("%s\"%u\": \"%s\"", i > 1 ? ", " : "", port, result);
    }
    printf("}\n");
    return 0;
}
