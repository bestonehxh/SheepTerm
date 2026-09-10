// One declaration libssh keeps in server.h, which we do not otherwise want:
// including that header would pull the whole server-side API into the app.
//
// ssh_send_keepalive sends the global request "keepalive@openssh.com" with
// want_reply set, so the far end is REQUIRED by RFC 4254 §4 to answer (with
// REQUEST_FAILURE, since it does not know the name). That answer is the point:
// ssh_send_ignore, which SheepTerm used before, asks for nothing, so its reply
// — silence — looks exactly the same whether the device is there or gone.
#ifndef SHEEPTERM_LIBSSH_EXTRA_H
#define SHEEPTERM_LIBSSH_EXTRA_H
#include "/opt/homebrew/include/libssh/libssh.h"
LIBSSH_API int ssh_send_keepalive(ssh_session session);
#endif
