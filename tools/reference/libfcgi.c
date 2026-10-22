/* Independently written interoperability fixture, Apache-2.0.
 * Uses the system libfcgi API; not linked into the MoonFCGI library. */
#include <fcgiapp.h>
#include <fastcgi.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc != 2 || FCGX_Init() != 0) return 1;
    int listener = FCGX_OpenSocket(argv[1], 128);
    if (listener < 0) return 2;
    FCGX_Request request;
    if (FCGX_InitRequest(&request, listener, 0) != 0) return 3;
    while (FCGX_Accept_r(&request) == 0) {
        char bytes[8192]; int n;
        if (request.role == FCGI_AUTHORIZER) {
            const char *auth = FCGX_GetParam("HTTP_AUTHORIZATION", request.envp);
            if (auth && strcmp(auth, "Bearer demo-token") == 0)
                FCGX_PutS("Status: 200 OK\r\nVariable-REMOTE_USER: demo\r\n\r\n", request.out);
            else FCGX_PutS("Status: 403 Forbidden\r\nContent-Type: application/octet-stream\r\n\r\nForbidden", request.out);
        } else {
            if (request.role == FCGI_FILTER) {
                while (FCGX_GetStr(bytes, sizeof(bytes), request.in) > 0) {}
                if (FCGX_StartFilterData(request.in) < 0) return 4;
            }
            FCGX_PutS("Status: 200 OK\r\nContent-Type: application/octet-stream\r\n\r\n", request.out);
            FCGX_FFlush(request.out);
            while ((n = FCGX_GetStr(bytes, sizeof(bytes), request.in)) > 0) {
                if (FCGX_PutStr(bytes, n, request.out) != n) return 5;
                FCGX_FFlush(request.out);
            }
        }
        FCGX_Finish_r(&request);
    }
    return 0;
}
