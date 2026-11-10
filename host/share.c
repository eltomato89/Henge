/* The folder and clipboard a virtual Mac shares with the device it runs on.

   The folder is a small WebDAV server, because macOS has a WebDAV client built in, so it mounts like any
   network drive with nothing to install for that part. The network hands each connection the guest makes to
   10.0.2.4:80 to a Unix socket in the app's own storage: no TCP port is open, so other apps can't reach this.

   /.henge/ is not part of the folder. It has the clipboard, where the helper inside macOS (tools/henge-agent.m)
   waits for the device's clipboard and sends the guest's, and what it takes to install that helper.

   Locks are accepted but not enforced: macOS only writes to a server that offers them, and there is one client. */
#include "share.h"

#include <copyfile.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <removefile.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <strings.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define HEAD_MAX (32 * 1024)
#define SMALL_BODY_MAX (16 * 1024 * 1024) /* a clipboard, or a request's XML */
#define TEMP_PREFIX ".henge-put-"

static char root[PATH_MAX];
static char agent_path[PATH_MAX];

/* ---- the clipboard ---- */

static pthread_mutex_t clip_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t clip_cond = PTHREAD_COND_INITIALIZER;
static char *device_clip; /* the device's, for the guest */
static unsigned long device_seq;
static char *guest_clip; /* the guest's, until the device takes it */
static time_t agent_seen;

void hv_share_set_clipboard(const char *text) {
    pthread_mutex_lock(&clip_mu);
    free(device_clip);
    device_clip = strdup(text);
    device_seq++;
    pthread_cond_broadcast(&clip_cond);
    pthread_mutex_unlock(&clip_mu);
}

char *hv_share_take_clipboard(void) {
    pthread_mutex_lock(&clip_mu);
    char *text = guest_clip;
    guest_clip = NULL;
    pthread_mutex_unlock(&clip_mu);
    return text;
}

long hv_share_agent_seen(void) {
    pthread_mutex_lock(&clip_mu);
    long ago = agent_seen ? (long)(time(NULL) - agent_seen) : -1;
    pthread_mutex_unlock(&clip_mu);
    return ago;
}

/* ---- connections ---- */

typedef struct Conn {
    int fd;
    char buf[64 * 1024]; /* read ahead */
    size_t at, have;
} Conn;

typedef struct Request {
    char method[16];
    char target[HEAD_MAX]; /* as sent, without the query */
    char path[PATH_MAX];   /* decoded */
    char query[128];
    char destination[PATH_MAX]; /* decoded path */
    char if_header[256];
    long long length;
    int chunked, expect_continue, close, overwrite, depth;
    long long range_from, range_to; /* -1: none */
    long chunk_left;
    int body_done;
} Request;

/* A growing string for XML. */
typedef struct Text {
    char *s;
    size_t len, cap;
} Text;

static void add(Text *t, const char *s, size_t n) {
    if (t->len + n + 1 > t->cap) {
        t->cap = (t->len + n + 1) * 2;
        t->s = realloc(t->s, t->cap);
    }
    memcpy(t->s + t->len, s, n);
    t->len += n;
    t->s[t->len] = 0;
}

static void adds(Text *t, const char *s) { add(t, s, strlen(s)); }

static void addf(Text *t, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
#include <stdarg.h>
static void addf(Text *t, const char *fmt, ...) {
    char line[1024];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    if (n > 0) add(t, line, (size_t)n < sizeof line ? (size_t)n : sizeof line - 1);
}

static void add_xml(Text *t, const char *s) {
    for (; *s; s++) {
        switch (*s) {
        case '&': adds(t, "&amp;"); break;
        case '<': adds(t, "&lt;"); break;
        case '>': adds(t, "&gt;"); break;
        case '"': adds(t, "&quot;"); break;
        default: add(t, s, 1);
        }
    }
}

static void add_url(Text *t, const char *s) {
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || strchr("-._~/", c)) add(t, s, 1);
        else addf(t, "%%%02X", c);
    }
}

static int send_all(int fd, const void *p, size_t n) {
    const char *c = p;
    while (n) {
        ssize_t w = send(fd, c, n, 0);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return -1;
        c += w, n -= (size_t)w;
    }
    return 0;
}

static ssize_t conn_read(Conn *c, void *out, size_t n) {
    if (c->at < c->have) {
        size_t take = c->have - c->at < n ? c->have - c->at : n;
        memcpy(out, c->buf + c->at, take);
        c->at += take;
        return (ssize_t)take;
    }
    for (;;) {
        ssize_t r = recv(c->fd, out, n, 0);
        if (r < 0 && errno == EINTR) continue;
        return r;
    }
}

/* A line of a chunked body's framing. */
static int conn_line(Conn *c, char *line, size_t cap) {
    size_t n = 0;
    while (n + 1 < cap) {
        char ch;
        if (conn_read(c, &ch, 1) != 1) return -1;
        if (ch == '\n') {
            if (n && line[n - 1] == '\r') n--;
            line[n] = 0;
            return 0;
        }
        line[n++] = ch;
    }
    return -1;
}

/* The next piece of the request's body: >0 bytes, 0 at its end, <0 if the connection broke. */
static ssize_t body_read(Conn *c, Request *r, void *out, size_t n) {
    if (r->body_done) return 0;
    if (r->chunked) {
        if (r->chunk_left == 0) {
            char line[64];
            if (conn_line(c, line, sizeof line) != 0) return -1;
            if (!line[0] && conn_line(c, line, sizeof line) != 0) return -1; /* the CRLF ending the last chunk */
            r->chunk_left = strtol(line, NULL, 16);
            if (r->chunk_left < 0) return -1;
            if (r->chunk_left == 0) {
                while (conn_line(c, line, sizeof line) == 0 && line[0]) {} /* trailers */
                r->body_done = 1;
                return 0;
            }
        }
        size_t take = (size_t)r->chunk_left < n ? (size_t)r->chunk_left : n;
        ssize_t got = conn_read(c, out, take);
        if (got <= 0) return -1;
        r->chunk_left -= got;
        return got;
    }
    if (r->length <= 0) {
        r->body_done = 1;
        return 0;
    }
    size_t take = (unsigned long long)r->length < n ? (size_t)r->length : n;
    ssize_t got = conn_read(c, out, take);
    if (got <= 0) return -1;
    r->length -= got;
    return got;
}

static void body_ready(Conn *c, Request *r) {
    if (r->expect_continue) {
        r->expect_continue = 0;
        static const char go[] = "HTTP/1.1 100 Continue\r\n\r\n";
        send_all(c->fd, go, sizeof go - 1);
    }
}

/* Reads what is left of a body, so the connection can carry on. Returns -1 if it can't. */
static int body_discard(Conn *c, Request *r) {
    char junk[8192];
    body_ready(c, r);
    for (;;) {
        ssize_t got = body_read(c, r, junk, sizeof junk);
        if (got == 0) return 0;
        if (got < 0) return -1;
    }
}

static char *body_small(Conn *c, Request *r, size_t *len) {
    Text t = {0};
    char piece[16384];
    body_ready(c, r);
    for (;;) {
        ssize_t got = body_read(c, r, piece, sizeof piece);
        if (got < 0 || t.len + (size_t)got > SMALL_BODY_MAX) {
            free(t.s);
            return NULL;
        }
        if (got == 0) break;
        add(&t, piece, (size_t)got);
    }
    add(&t, "", 0);
    *len = t.len;
    return t.s;
}

static int respond(Conn *c, Request *r, int status, const char *reason, const char *headers, const char *body, size_t len) {
    char head[2048];
    int n = snprintf(head, sizeof head, "HTTP/1.1 %d %s\r\nServer: Henge\r\nContent-Length: %zu\r\n%s%s\r\n", status, reason, len,
                     headers ? headers : "", r->close ? "Connection: close\r\n" : "");
    if (send_all(c->fd, head, (size_t)n) != 0) return -1;
    return (body && len && strcmp(r->method, "HEAD") != 0) ? send_all(c->fd, body, len) : 0;
}

static int respond_empty(Conn *c, Request *r, int status, const char *reason) {
    return respond(c, r, status, reason, NULL, NULL, 0);
}

/* ---- paths ---- */

static int hex(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Percent-decodes a URL path, and refuses any that could leave the folder. */
static int decode_path(const char *in, char *out, size_t cap) {
    size_t n = 0;
    for (const char *p = in; *p; p++) {
        int c = (unsigned char)*p;
        if (c == '%') {
            int a = hex(p[1]), b = a < 0 ? -1 : hex(p[2]);
            if (a < 0 || b < 0) return -1;
            c = a * 16 + b;
            p += 2;
            if (c == 0) return -1;
        }
        if (n + 1 >= cap) return -1;
        out[n++] = (char)c;
    }
    out[n] = 0;
    if (out[0] != '/') return -1;
    for (const char *s = out; s; s = strchr(s + 1, '/')) {
        const char *part = s + 1, *end = strchr(part, '/');
        size_t len = end ? (size_t)(end - part) : strlen(part);
        if (len == 2 && part[0] == '.' && part[1] == '.') return -1;
    }
    return 0;
}

static int local_path(const char *path, char *out, size_t cap) {
    int n = snprintf(out, cap, "%s%s", root, path);
    if (n < 0 || (size_t)n >= cap) return -1;
    while (n > 1 && out[n - 1] == '/') out[--n] = 0;
    return 0;
}

/* ---- what the guest must never be served ---- */

/* Documents holds things that are the device's, not the Mac's. The inventory below is the
   audit of every filename the host app itself reads, executes, follows, or writes
   in Documents (citations are to the app sources; see the design record):
     henge.log, henge-prev.log            HengeLog.swift:55,81 (the log and its previous run)
     henge-native.log, henge-native-prev.log
                                          HengeLog.swift:116,120,149,150 (native stderr capture,
                                          replayed into the next run's henge.log)
     henge-env.txt                        EngineTuning.swift:41 (parsed KEY=VALUE, applied via
                                          setenv before each Mac starts: engine control)
     trace-on                             EngineTuning.swift:39-40 (its mere existence at the
                                          HV_PVG_TRACE_FILE path enables the GPU trace,
                                          checked with access(F_OK) in pvg_lite.c / pvg_metal.m)
     henge-autopilot.txt                  Autopilot.swift:41 (followed line by line as commands)
     henge-autopilot-once.txt             Autopilot.swift:33 (renamed to henge-autopilot.txt at
                                          launch and followed: a one-shot command plant)
     StikJIT (directory component)        JITSetup.swift:42 (the pairing directory)
     pairingFile.plist                    JITSetup.swift:44 (the JIT pairing file itself; it was
                                          previously covered only transitively, and only in
                                          exact case, by the StikJIT component above)
   The pairingFile-<UUID>.plist pattern (HengeJITHelper.swift:36) is denied too: the helper
   writes those under Library, not Documents, so this is defence in depth for copies.
   When the served root is Documents itself, or any folder containing these, they are not
   listed, read, written, or deleted through the share: a request for one answers 404, as
   if it were not there. The default Documents/Shared root contains none of them, so this
   changes nothing there.
   This is defence in depth, not a guarantee: it cannot see hardlinks, and the machine-import
   inbox (Machines.swift:144,154: any Documents folder holding disk.img, machine.json,
   auxiliary.bin and AVPBooter.vmapple2.bin is adopted) cannot be closed by filename without
   also denying the Exports the app itself writes for the user to copy out. */
/* ASCII case-insensitive component equality. The host filesystem is case-insensitive by
   default, so an exact-case match is a bypass (HENGE.LOG is henge.log to the disk but was
   not to the old check). The fold here is ASCII only, tolower() per byte, and that is NOT
   the whole defence: the host volume folds some non-ASCII spellings onto these ASCII
   names too (filesystem probes read one file through its U+017F long-s and U+212A
   Kelvin-sign spellings), so a non-ASCII lookalike CAN be the same file to the
   filesystem, and therefore to the app. What closes those spellings is not this fold:
   resolved_local() canonicalises with realpath(), which returns the on-disk spelling,
   and re-runs this deny over the resolved path's root-relative components, so a folded
   spelling arrives at the check already canonicalised to the denied name. The
   resolved-path re-check is the load-bearing defence for non-ASCII folds; it must not
   be removed as redundant with this request-path fold. */
static int component_denied(const char *part, size_t len) {
    static const char *names[] = {"henge.log", "henge-prev.log", "henge-native.log", "henge-native-prev.log",
                                  "henge-env.txt", "trace-on", "henge-autopilot.txt", "henge-autopilot-once.txt",
                                  "StikJIT", "pairingFile.plist"};
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) {
        if (strlen(names[i]) != len) continue;
        size_t j = 0;
        while (j < len && tolower((unsigned char)part[j]) == tolower((unsigned char)names[i][j])) j++;
        if (j == len) return 1;
    }
    /* pairingFile-<UUID>.plist, any case (see the inventory note above). */
    static const char pre[] = "pairingfile-", suf[] = ".plist";
    if (len > sizeof pre - 1 + sizeof suf - 1) {
        size_t j = 0;
        while (j < sizeof pre - 1 && tolower((unsigned char)part[j]) == pre[j]) j++;
        if (j == sizeof pre - 1) {
            size_t k = 0, off = len - (sizeof suf - 1);
            while (k < sizeof suf - 1 && tolower((unsigned char)part[off + k]) == suf[k]) k++;
            if (k == sizeof suf - 1) return 1;
        }
    }
    return 0;
}

static int share_denied(const char *path) {
    const char *p = path;
    while (*p) {
        while (*p == '/') p++;
        if (!*p) break;
        const char *end = strchr(p, '/');
        size_t len = end ? (size_t)(end - p) : strlen(p);
        if (component_denied(p, len)) return 1;
        if (!end) break;
        p = end;
    }
    return 0;
}

/* ---- resolved-path containment ----
   SYMLINK POLICY (stated; the redesign's core decision):
   - A symlink is followed only when its fully resolved target stays inside the served
     root and is not itself a denied name. A link from inside the root to another place
     inside the root therefore keeps working (it is ordinary served content), while any
     link, at any depth, whose target leaves the root is refused for every method.
   - The final component is treated the same as an intermediate one: the old code's
     O_NOFOLLOW in do_get covered only the final component, so an intermediate symlink
     escaped the root entirely. Resolution here is over the whole path.
   - Creates differ from reads because the target may not exist yet: the deepest existing
     ancestor is canonicalised with realpath() and the not-yet-existing remainder is
     appended. A remainder component cannot be a symlink (it does not exist), so the
     create lands inside the root exactly when its existing parent does. If the final
     component DOES exist and is a symlink to an existing target, realpath() resolves it
     and the outside/denied rules apply, so a PUT or MKCOL cannot be redirected out.
   - A broken symlink (target missing) resolves as parent + its own name for reads:
     reads fail at open as before. But "component absent" and "component present as a
     dangling symlink" are different facts, and creates must not confuse them
     because realpath() fails on a dangling link, so the loop
     below strips it as if it were a not-yet-existing remainder, and a handler that
     creates by opening the final path (LOCK's O_CREAT) then follows the link and
     creates its target, possibly outside the root, possibly a denied
     existence-checked name such as henge-autopilot-once.txt or trace-on.
     resolved_local_create() therefore refuses any path with a dangling component
     for the handlers that create through the final path (LOCK, MKCOL). The other
     create-class handlers are safe by their own mechanism, wire-verified, and keep
     their behaviour: PUT writes a temp file beside the target and renames it over
     the final component, which replaces a dangling link itself inside the root and
     never follows it; MOVE's rename has the same replace-the-link property at its
     destination; COPY to a dangling destination fails inside copyfile (409) and
     creates nothing. MKCOL goes through resolved_local_create() anyway, so its
     refusal rests on this check, not on mkdir's EEXIST.
   - Final-component link semantics follow POSIX link
     semantics, per operation: DELETE removes the link itself, never its target, and
     MOVE moves the link itself at both ends (a destination link is replaced, never
     followed); recursion happens only into real directories. Intermediate
     components still resolve under containment exactly as above. Reads (GET,
     PROPFIND, PROPPATCH, and COPY's source) keep follow semantics for live in-root
     links, as do PUT and COPY destinations (write-through to an in-root target;
     refused when the target is outside or denied). A final link is an object
     inside the root, so deleting or moving it touches nothing outside the root
     whatever it points at: the target is never read, written, or removed by those
     operations. Copying FROM a live symlink whose target is outside is refused
     like any other outside resolution.
   - A DELETE of a link whose path ends in a trailing slash is refused (403): the
     trailing slash leaves no final component name for link-final resolution to
     act on, so the request is declined rather than operated on. The refusal is
     decided behavior (a trailing slash on a link is a malformed delete), not a
     gap: the link is neither followed nor removed.
   - The denylist is re-checked on the RESOLVED path's root-relative components, so an
     innocently named link to a denied file (inside or outside the root) is refused.
     The check is root-relative, never absolute, so a served root that happens to sit
     under a folder named e.g. "trace-on" is not self-denied.
   - Known residual: this is a check-then-use design. Between resolution and the syscall
     a concurrent writer could swap a component for a symlink (the guest has no symlink
     operation in this protocol, but MOVE can relocate a host-planted link). Closing that
     race needs dirfd/openat-style traversal, which is a larger change than this redesign;
     it is named here so the limit is on record, not discovered later.
   Returns 0 with the canonical local path in out, or -1 to refuse. Refusals surface as
   each handler's existing failure status (404 for reads, 403 for writes): no content or
   metadata of an outside or denied target is ever served either way. */
static int resolved_local(const char *path, char *out, size_t cap) {
    char cand[PATH_MAX], work[PATH_MAX], canon[PATH_MAX], resolved[PATH_MAX];
    char remainder[PATH_MAX] = "";
    if (local_path(path, cand, sizeof cand) != 0) return -1;
    snprintf(work, sizeof work, "%s", cand);
    for (;;) {
        if (realpath(work, canon)) {
            int n = remainder[0] ? snprintf(resolved, sizeof resolved, "%s%s", canon, remainder)
                                 : snprintf(resolved, sizeof resolved, "%s", canon);
            if (n < 0 || (size_t)n >= sizeof resolved) return -1;
            break;
        }
        if (errno != ENOENT && errno != ENOTDIR) return -1;
        char *slash = strrchr(work, '/');
        if (!slash || slash == work) return -1; /* reached the filesystem root without resolving */
        char tail[PATH_MAX];
        if (snprintf(tail, sizeof tail, "%s%s", slash, remainder) >= (int)sizeof tail) return -1;
        snprintf(remainder, sizeof remainder, "%s", tail);
        *slash = 0;
    }
    size_t rl = strlen(root);
    int contained = !strcmp(resolved, root) || (rl == 1 && resolved[0] == '/') ||
                    (!strncmp(resolved, root, rl) && resolved[rl] == '/');
    if (!contained) return -1;
    if (share_denied(!strcmp(resolved, root) ? "/" : resolved + rl)) return -1;
    if ((size_t)snprintf(out, cap, "%s", resolved) >= cap) return -1;
    return 0;
}

/* ---- dangling components and link-final resolution ---- */

/* 1 when any component of cand (the unresolved root-join of a request path) exists as
   a symlink whose target does not resolve: a dangling link, at any depth. realpath()
   on the full path cannot see this case (it fails, and the strip loop in
   resolved_local() treats the component as absent), so it is checked directly, one
   prefix at a time. A live link, wherever it points, is not dangling: containment
   and the deny re-check in resolved_local() judge live links. */
static int has_dangling_component(const char *cand) {
    char buf[PATH_MAX];
    if (snprintf(buf, sizeof buf, "%s", cand) >= (int)sizeof buf) return 1;
    for (char *p = buf + 1;; p++) {
        if (*p != '/' && *p != 0) continue;
        char save = *p;
        *p = 0;
        struct stat lst;
        if (lstat(buf, &lst) == 0 && S_ISLNK(lst.st_mode)) {
            char rp[PATH_MAX];
            if (!realpath(buf, rp)) return 1;
        }
        if (!save) break;
        *p = save;
    }
    return 0;
}

/* resolved_local() for create-class handlers that act through the final path (LOCK,
   MKCOL): additionally refuse when any component of the requested path exists as a
   dangling symlink, so a create can never be redirected through a broken link to a
   target outside the root (or to a denied existence-checked name inside it). */
static int resolved_local_create(const char *path, char *out, size_t cap) {
    char cand[PATH_MAX];
    if (local_path(path, cand, sizeof cand) != 0) return -1;
    if (has_dangling_component(cand)) return -1;
    return resolved_local(path, out, cap);
}

/* resolved_local() with POSIX final-component link semantics, for DELETE and for
   MOVE at both ends: when the final component exists as a symlink, the result is
   the link's own path (its parent resolved under the usual containment and deny
   rules), never the link's target. Any other path resolves exactly as
   resolved_local(). The final name is deny-checked here as a belt, because the
   returned path is built from the request name, not resolved. */
static int resolved_local_linkfinal(const char *path, char *out, size_t cap) {
    char cand[PATH_MAX];
    struct stat lst;
    if (local_path(path, cand, sizeof cand) != 0) return -1;
    if (lstat(cand, &lst) != 0 || !S_ISLNK(lst.st_mode)) return resolved_local(path, out, cap);
    const char *slash = strrchr(path, '/');
    if (!slash || !slash[1]) return -1;
    if (component_denied(slash + 1, strlen(slash + 1))) return -1;
    char parent[PATH_MAX], pres[PATH_MAX];
    if (slash == path) snprintf(parent, sizeof parent, "/");
    else if ((size_t)(slash - path) >= sizeof parent) return -1;
    else snprintf(parent, sizeof parent, "%.*s", (int)(slash - path), path);
    if (resolved_local(parent, pres, sizeof pres) != 0) return -1;
    int n = pres[strlen(pres) - 1] == '/' ? snprintf(out, cap, "%s%s", pres, slash + 1)
                                          : snprintf(out, cap, "%s/%s", pres, slash + 1);
    if (n < 0 || (size_t)n >= cap) return -1;
    return 0;
}

/* ---- the folder ---- */

static void add_entry(Text *t, const char *url_path, const char *name, const struct stat *st, int is_root) {
    int dir = S_ISDIR(st->st_mode);
    char modified[64], created[64];
    struct tm tm;
    gmtime_r(&st->st_mtimespec.tv_sec, &tm);
    strftime(modified, sizeof modified, "%a, %d %b %Y %H:%M:%S GMT", &tm);
    gmtime_r(&st->st_birthtimespec.tv_sec, &tm);
    strftime(created, sizeof created, "%Y-%m-%dT%H:%M:%SZ", &tm);
    adds(t, "<D:response><D:href>");
    add_url(t, url_path);
    if (dir && url_path[strlen(url_path) - 1] != '/') adds(t, "/");
    adds(t, "</D:href><D:propstat><D:prop><D:displayname>");
    add_xml(t, name);
    addf(t, "</D:displayname><D:getlastmodified>%s</D:getlastmodified><D:creationdate>%s</D:creationdate>", modified, created);
    if (dir) {
        adds(t, "<D:resourcetype><D:collection/></D:resourcetype>");
    } else {
        addf(t, "<D:resourcetype/><D:getcontentlength>%lld</D:getcontentlength><D:getcontenttype>application/octet-stream</D:getcontenttype>"
                "<D:getetag>\"%llx-%llx\"</D:getetag>",
             (long long)st->st_size, (unsigned long long)st->st_size, (unsigned long long)st->st_mtimespec.tv_sec);
    }
    adds(t, "<D:supportedlock><D:lockentry><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockentry></D:supportedlock>"
            "<D:lockdiscovery/>");
    if (is_root) {
        struct statfs fs;
        if (statfs(root, &fs) == 0) {
            addf(t, "<D:quota-available-bytes>%llu</D:quota-available-bytes><D:quota-used-bytes>%llu</D:quota-used-bytes>",
                 (unsigned long long)fs.f_bavail * fs.f_bsize, (unsigned long long)(fs.f_blocks - fs.f_bfree) * fs.f_bsize);
        }
    }
    adds(t, "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>");
}

static int do_propfind(Conn *c, Request *r) {
    if (body_discard(c, r) != 0) return -1;
    char local[PATH_MAX];
    struct stat st;
    if (resolved_local(r->path, local, sizeof local) != 0 || stat(local, &st) != 0) return respond_empty(c, r, 404, "Not Found");
    Text t = {0};
    adds(&t, "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:multistatus xmlns:D=\"DAV:\">");
    const char *slash = strrchr(r->path, '/');
    int is_root = strcmp(r->path, "/") == 0;
    add_entry(&t, r->path, is_root ? "Henge" : (slash && slash[1] ? slash + 1 : r->path), &st, is_root);
    if (S_ISDIR(st.st_mode) && r->depth != 0) {
        DIR *d = opendir(local);
        struct dirent *e;
        while (d && (e = readdir(d))) {
            if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..") || !strncmp(e->d_name, TEMP_PREFIX, strlen(TEMP_PREFIX))) continue;
            char child[PATH_MAX], url[PATH_MAX];
            struct stat cs;
            if (snprintf(child, sizeof child, "%s/%s", local, e->d_name) >= (int)sizeof child) continue;
            if (snprintf(url, sizeof url, "%s%s%s", r->path, r->path[strlen(r->path) - 1] == '/' ? "" : "/", e->d_name) >= (int)sizeof url) continue;
            if (share_denied(url)) continue; /* device-private names are not listed */
            if (lstat(child, &cs) != 0 || !(S_ISREG(cs.st_mode) || S_ISDIR(cs.st_mode))) continue; /* no links out of the folder */
            add_entry(&t, url, e->d_name, &cs, 0);
        }
        if (d) closedir(d);
    }
    adds(&t, "</D:multistatus>");
    int rc = respond(c, r, 207, "Multi-Status", "Content-Type: application/xml; charset=utf-8\r\n", t.s, t.len);
    free(t.s);
    return rc;
}

static int do_proppatch(Conn *c, Request *r) {
    if (body_discard(c, r) != 0) return -1;
    Text t = {0};
    adds(&t, "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:multistatus xmlns:D=\"DAV:\"><D:response><D:href>");
    add_url(&t, r->path);
    adds(&t, "</D:href><D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>");
    int rc = respond(c, r, 207, "Multi-Status", "Content-Type: application/xml; charset=utf-8\r\n", t.s, t.len);
    free(t.s);
    return rc;
}

static int do_get(Conn *c, Request *r) {
    if (body_discard(c, r) != 0) return -1;
    char local[PATH_MAX];
    struct stat st;
    if (resolved_local(r->path, local, sizeof local) != 0) return respond_empty(c, r, 404, "Not Found");
    int fd = open(local, O_RDONLY | O_NOFOLLOW);
    if (fd < 0 || fstat(fd, &st) != 0) {
        if (fd >= 0) close(fd);
        return respond_empty(c, r, 404, "Not Found");
    }
    if (S_ISDIR(st.st_mode)) {
        close(fd);
        return respond_empty(c, r, 405, "Method Not Allowed");
    }
    long long from = 0, to = st.st_size - 1;
    int partial = 0;
    if (r->range_from >= 0 || r->range_to >= 0) {
        if (r->range_from < 0) { /* the last N bytes */
            from = st.st_size > r->range_to ? st.st_size - r->range_to : 0;
        } else {
            from = r->range_from;
            if (r->range_to >= 0 && r->range_to < to) to = r->range_to;
        }
        if (from >= st.st_size && st.st_size > 0) {
            close(fd);
            char h[80];
            snprintf(h, sizeof h, "Content-Range: bytes */%lld\r\n", (long long)st.st_size);
            return respond(c, r, 416, "Range Not Satisfiable", h, NULL, 0);
        }
        partial = 1;
    }
    long long len = st.st_size ? to - from + 1 : 0;
    char modified[64];
    struct tm tm;
    gmtime_r(&st.st_mtimespec.tv_sec, &tm);
    strftime(modified, sizeof modified, "%a, %d %b %Y %H:%M:%S GMT", &tm);
    char head[1024];
    int n = snprintf(head, sizeof head,
                     "HTTP/1.1 %s\r\nServer: Henge\r\nContent-Length: %lld\r\nContent-Type: application/octet-stream\r\nAccept-Ranges: bytes\r\n"
                     "Last-Modified: %s\r\nETag: \"%llx-%llx\"\r\n",
                     partial ? "206 Partial Content" : "200 OK", len, modified, (unsigned long long)st.st_size,
                     (unsigned long long)st.st_mtimespec.tv_sec);
    if (partial) n += snprintf(head + n, sizeof head - (size_t)n, "Content-Range: bytes %lld-%lld/%lld\r\n", from, to, (long long)st.st_size);
    n += snprintf(head + n, sizeof head - (size_t)n, "%s\r\n", r->close ? "Connection: close\r\n" : "");
    int rc = send_all(c->fd, head, (size_t)n);
    if (rc == 0 && strcmp(r->method, "HEAD") != 0) {
        static const size_t piece = 256 * 1024;
        char *buf = malloc(piece);
        long long at = from, left = len;
        while (rc == 0 && left > 0) {
            ssize_t got = pread(fd, buf, (size_t)left < piece ? (size_t)left : piece, at);
            if (got <= 0) rc = -1;
            else {
                rc = send_all(c->fd, buf, (size_t)got);
                at += got, left -= got;
            }
        }
        free(buf);
    }
    close(fd);
    return rc;
}

/* Into a temporary file beside it, then renamed, so a transfer cut short leaves the old file alone. */
static int do_put(Conn *c, Request *r) {
    char local[PATH_MAX], temp[PATH_MAX];
    struct stat st;
    if (resolved_local(r->path, local, sizeof local) != 0) {
        body_discard(c, r);
        return respond_empty(c, r, 403, "Forbidden");
    }
    int existed = stat(local, &st) == 0;
    if (existed && S_ISDIR(st.st_mode)) {
        if (body_discard(c, r) != 0) return -1;
        return respond_empty(c, r, 405, "Method Not Allowed");
    }
    char *slash = strrchr(local, '/');
    size_t dir_len = (size_t)(slash - local);
    if (snprintf(temp, sizeof temp, "%.*s/" TEMP_PREFIX "XXXXXX", (int)dir_len, local) >= (int)sizeof temp) {
        body_discard(c, r);
        return respond_empty(c, r, 414, "URI Too Long");
    }
    int fd = mkstemp(temp);
    if (fd < 0) {
        int gone = errno == ENOENT;
        if (body_discard(c, r) != 0) return -1;
        return gone ? respond_empty(c, r, 409, "Conflict") : respond_empty(c, r, 507, "Insufficient Storage");
    }
    fchmod(fd, 0644);
    body_ready(c, r);
    static const size_t piece = 256 * 1024;
    char *buf = malloc(piece);
    int full = 0;
    for (;;) {
        ssize_t got = body_read(c, r, buf, piece);
        if (got < 0) { /* the client went away: no response to give */
            close(fd);
            unlink(temp);
            free(buf);
            return -1;
        }
        if (got == 0) break;
        if (!full) {
            for (ssize_t done = 0; done < got;) {
                ssize_t w = write(fd, buf + done, (size_t)(got - done));
                if (w < 0 && errno == EINTR) continue;
                if (w <= 0) {
                    full = 1;
                    break;
                }
                done += w;
            }
        }
    }
    free(buf);
    close(fd);
    if (full || rename(temp, local) != 0) {
        unlink(temp);
        return respond_empty(c, r, 507, "Insufficient Storage");
    }
    return existed ? respond_empty(c, r, 204, "No Content") : respond_empty(c, r, 201, "Created");
}

static int remove_path(const char *local) {
    struct stat st;
    if (lstat(local, &st) != 0) return -1;
    if (S_ISDIR(st.st_mode)) return removefile(local, NULL, REMOVEFILE_RECURSIVE);
    return unlink(local);
}

static int do_delete(Conn *c, Request *r) {
    if (body_discard(c, r) != 0) return -1;
    char local[PATH_MAX];
    if (strcmp(r->path, "/") == 0 || resolved_local_linkfinal(r->path, local, sizeof local) != 0) return respond_empty(c, r, 403, "Forbidden");
    if (remove_path(local) != 0) return errno == ENOENT ? respond_empty(c, r, 404, "Not Found") : respond_empty(c, r, 403, "Forbidden");
    return respond_empty(c, r, 204, "No Content");
}

static int do_mkcol(Conn *c, Request *r) {
    if (body_discard(c, r) != 0) return -1;
    char local[PATH_MAX];
    if (resolved_local_create(r->path, local, sizeof local) != 0) return respond_empty(c, r, 403, "Forbidden");
    if (mkdir(local, 0755) == 0) return respond_empty(c, r, 201, "Created");
    if (errno == EEXIST) return respond_empty(c, r, 405, "Method Not Allowed");
    if (errno == ENOENT) return respond_empty(c, r, 409, "Conflict");
    return respond_empty(c, r, 403, "Forbidden");
}

static int do_move_copy(Conn *c, Request *r, int move) {
    if (body_discard(c, r) != 0) return -1;
    char from[PATH_MAX], to[PATH_MAX];
    struct stat st;
    if (!r->destination[0] || strcmp(r->path, "/") == 0 ||
        (move ? resolved_local_linkfinal(r->path, from, sizeof from) : resolved_local(r->path, from, sizeof from)) != 0 ||
        (move ? resolved_local_linkfinal(r->destination, to, sizeof to) : resolved_local(r->destination, to, sizeof to)) != 0)
        return respond_empty(c, r, 400, "Bad Request");
    /* MOVE's source may be a dangling link (the link itself is what moves), so its
       existence is an lstat question; COPY reads through its source, so stat. */
    if ((move ? lstat(from, &st) : stat(from, &st)) != 0) return respond_empty(c, r, 404, "Not Found");
    int existed = stat(to, &st) == 0;
    if (existed && !r->overwrite) return respond_empty(c, r, 412, "Precondition Failed");
    if (existed && strcmp(from, to) != 0 && remove_path(to) != 0) return respond_empty(c, r, 403, "Forbidden");
    int rc = move ? rename(from, to) : copyfile(from, to, NULL, COPYFILE_ALL | COPYFILE_RECURSIVE);
    if (rc != 0) return errno == ENOENT ? respond_empty(c, r, 409, "Conflict") : respond_empty(c, r, 403, "Forbidden");
    return existed ? respond_empty(c, r, 204, "No Content") : respond_empty(c, r, 201, "Created");
}

static int do_lock(Conn *c, Request *r) {
    if (body_discard(c, r) != 0) return -1;
    static unsigned long counter;
    char token[128];
    const char *open_ = strchr(r->if_header, '<'), *end = open_ ? strchr(open_, '>') : NULL;
    if (open_ && end && (size_t)(end - open_) < sizeof token) { /* a refresh keeps its token */
        snprintf(token, sizeof token, "%.*s", (int)(end - open_ - 1), open_ + 1);
    } else {
        snprintf(token, sizeof token, "opaquelocktoken:henge-%lx-%lx", (unsigned long)time(NULL), __atomic_add_fetch(&counter, 1, __ATOMIC_RELAXED));
    }
    int status = 200;
    char local[PATH_MAX];
    struct stat st;
    /* Resolve (create-strict: a dangling final or intermediate link refuses) before
       making the empty file: a refused LOCK must not create through a link. */
    if (resolved_local_create(r->path, local, sizeof local) != 0) return respond_empty(c, r, 403, "Forbidden");
    if (stat(local, &st) != 0) { /* locking a name that isn't there makes an empty file */
        int fd = open(local, O_CREAT | O_WRONLY, 0644);
        if (fd < 0) return respond_empty(c, r, 409, "Conflict");
        close(fd);
        status = 201;
    }
    Text t = {0};
    addf(&t, "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:prop xmlns:D=\"DAV:\"><D:lockdiscovery><D:activelock>"
             "<D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope><D:depth>0</D:depth>"
             "<D:timeout>Second-3600</D:timeout><D:locktoken><D:href>%s</D:href></D:locktoken></D:activelock></D:lockdiscovery></D:prop>",
         token);
    char headers[256];
    snprintf(headers, sizeof headers, "Content-Type: application/xml; charset=utf-8\r\nLock-Token: <%s>\r\n", token);
    int rc = respond(c, r, status, status == 201 ? "Created" : "OK", headers, t.s, t.len);
    free(t.s);
    return rc;
}

/* ---- /.henge/ ---- */

/* What "curl -s http://10.0.2.4/.henge/install | sh" runs in macOS. */
static const char install_script[] =
    "#!/bin/sh\n"
    "D=\"$HOME/Library/Application Support/Henge\"\n"
    "P=\"$HOME/Library/LaunchAgents/com.henge.agent.plist\"\n"
    "mkdir -p \"$D\" \"$HOME/Library/LaunchAgents\"\n"
    "launchctl bootout \"gui/$(id -u)/com.henge.agent\" 2>/dev/null\n"
    "curl -fsS http://" HV_SHARE_ADDR "/.henge/agent | gunzip > \"$D/henge-agent\" || { echo 'Could not reach Henge.'; exit 1; }\n"
    "chmod 755 \"$D/henge-agent\"\n"
    "cat > \"$P\" <<EOF\n"
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
    "<plist version=\"1.0\"><dict>\n"
    "<key>Label</key><string>com.henge.agent</string>\n"
    "<key>ProgramArguments</key><array><string>$D/henge-agent</string></array>\n"
    "<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>\n"
    "<key>LimitLoadToSessionType</key><string>Aqua</string>\n"
    "<key>ProcessType</key><string>Background</string>\n"
    "</dict></plist>\n"
    "EOF\n"
    "launchctl bootstrap \"gui/$(id -u)\" \"$P\"\n"
    "echo 'Henge is set up. You can close this window.'\n";

/* What "curl -s http://10.0.2.4/.henge/lighten | sh" runs in macOS: less background work and drawing, for a Mac
   whose CPUs are emulated: less animation and drawing, and the system part (update checks, Time Machine) with the
   Mac's password once. Apple's own background agents can't be turned off with System Integrity Protection on
   (launchctl disable of gui/ agents did not survive a log out on the Mac bench, 2026-11-08), so it doesn't try.
   Reduce Motion and Reduce Transparency need System Settings (a script can't write com.apple.universalaccess).
   Nothing reads the script's own stdin (sh is reading the script from it). */
static const char lighten_script[] =
    "#!/bin/sh\n"
    "echo 'Making macOS lighter for Henge...'\n"
    "defaults write com.apple.universalaccess reduceMotion -bool true 2>/dev/null </dev/null || "
    "echo '  Reduce Motion: turn it on in System Settings, Accessibility, Motion.'\n"
    "defaults write com.apple.universalaccess reduceTransparency -bool true 2>/dev/null </dev/null || "
    "echo '  Reduce Transparency: turn it on in System Settings, Accessibility, Display.'\n"
    "defaults write -g NSAutomaticWindowAnimationsEnabled -bool false </dev/null\n"
    "defaults write -g NSWindowResizeTime -float 0.001 </dev/null\n"
    "defaults write com.apple.dock launchanim -bool false </dev/null\n"
    "defaults -currentHost write com.apple.screensaver idleTime -int 0 </dev/null\n"
    "defaults write com.apple.WindowManager StandardHideWidgets -int 1 </dev/null\n"
    "defaults write com.apple.WindowManager StageManagerHideWidgets -int 1 </dev/null\n"
    "W=\"/System/Library/Desktop Pictures/Solid Colors/Black.png\"\n"
    "[ -f \"$W\" ] || W=$(ls \"/System/Library/Desktop Pictures/Solid Colors/\"*.png 2>/dev/null | head -1)\n"
    "if [ -n \"$W\" ]; then\n"
    "  osascript -l JavaScript - \"$W\" >/dev/null 2>&1 <<'JS'\n"
    "ObjC.import('AppKit');\n"
    "function run(argv) {\n"
    "  var url = $.NSURL.fileURLWithPath(argv[0]), screens = $.NSScreen.screens;\n"
    "  for (var i = 0; i < screens.count; i++)\n"
    "    $.NSWorkspace.sharedWorkspace.setDesktopImageURLForScreenOptionsError(url, screens.objectAtIndex(i), $({}), null);\n"
    "}\n"
    "JS\n"
    "fi\n"
    "killall Dock 2>/dev/null\n"
    "echo 'Done: window and Dock animations, desktop widgets, the screen saver and a moving wallpaper are off.'\n"
    "echo 'Also turn on Reduce Motion and Reduce Transparency: System Settings, Accessibility.'\n"
    "echo 'Log out and back in for all of it to take effect. To undo: curl -s http://" HV_SHARE_ADDR "/.henge/unlighten | sh'\n";

/* And back. The wallpaper stays as it is: pick one in System Settings. */
static const char unlighten_script[] =
    "#!/bin/sh\n"
    "defaults write com.apple.universalaccess reduceMotion -bool false 2>/dev/null </dev/null\n"
    "defaults write com.apple.universalaccess reduceTransparency -bool false 2>/dev/null </dev/null\n"
    "defaults delete -g NSAutomaticWindowAnimationsEnabled 2>/dev/null </dev/null\n"
    "defaults delete -g NSWindowResizeTime 2>/dev/null </dev/null\n"
    "defaults delete com.apple.dock launchanim 2>/dev/null </dev/null\n"
    "defaults -currentHost delete com.apple.screensaver idleTime 2>/dev/null </dev/null\n"
    "defaults write com.apple.WindowManager StandardHideWidgets -int 0 </dev/null\n"
    "defaults write com.apple.WindowManager StageManagerHideWidgets -int 0 </dev/null\n"
    "killall Dock 2>/dev/null\n"
    "echo 'Back as it was, apart from the wallpaper (System Settings, Wallpaper).'\n"
    "echo 'Log out and back in (or restart) for all of it to take effect.'\n";

static int serve_agent(Conn *c, Request *r) {
    if (body_discard(c, r) != 0) return -1;
    int fd = agent_path[0] ? open(agent_path, O_RDONLY) : -1;
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0) {
        if (fd >= 0) close(fd);
        return respond_empty(c, r, 404, "Not Found");
    }
    char *data = malloc((size_t)st.st_size);
    ssize_t got = data ? pread(fd, data, (size_t)st.st_size, 0) : -1;
    close(fd);
    int rc = got == st.st_size ? respond(c, r, 200, "OK", "Content-Type: application/octet-stream\r\n", data, (size_t)got)
                               : respond_empty(c, r, 500, "Internal Server Error");
    free(data);
    return rc;
}

/* GET ?since=N waits up to 25 s for a newer clipboard than N. */
static int clipboard_get(Conn *c, Request *r) {
    if (body_discard(c, r) != 0) return -1;
    unsigned long since = 0;
    const char *q = strstr(r->query, "since=");
    if (q) since = strtoul(q + 6, NULL, 10);
    struct timespec until;
    struct timeval now;
    gettimeofday(&now, NULL);
    until.tv_sec = now.tv_sec + 25;
    until.tv_nsec = now.tv_usec * 1000;
    pthread_mutex_lock(&clip_mu);
    agent_seen = time(NULL);
    while (device_seq <= since && pthread_cond_timedwait(&clip_cond, &clip_mu, &until) != ETIMEDOUT) {}
    agent_seen = time(NULL);
    unsigned long seq = device_seq;
    char *text = seq > since && device_clip ? strdup(device_clip) : NULL;
    pthread_mutex_unlock(&clip_mu);
    char headers[64];
    snprintf(headers, sizeof headers, "X-Henge-Seq: %lu\r\n", seq);
    int rc = text ? respond(c, r, 200, "OK", headers, text, strlen(text)) : respond(c, r, 204, "No Content", headers, NULL, 0);
    free(text);
    return rc;
}

static int clipboard_put(Conn *c, Request *r) {
    size_t len = 0;
    char *text = body_small(c, r, &len);
    if (!text) return -1;
    pthread_mutex_lock(&clip_mu);
    free(guest_clip);
    guest_clip = text;
    agent_seen = time(NULL);
    pthread_mutex_unlock(&clip_mu);
    return respond_empty(c, r, 204, "No Content");
}

static int serve_henge(Conn *c, Request *r) {
    const char *what = r->path + strlen("/.henge/");
    if (!strcmp(what, "install") && !strcmp(r->method, "GET")) {
        if (body_discard(c, r) != 0) return -1;
        return respond(c, r, 200, "OK", "Content-Type: text/plain\r\n", install_script, sizeof install_script - 1);
    }
    if ((!strcmp(what, "lighten") || !strcmp(what, "unlighten")) && !strcmp(r->method, "GET")) {
        if (body_discard(c, r) != 0) return -1;
        const char *s = what[0] == 'l' ? lighten_script : unlighten_script;
        return respond(c, r, 200, "OK", "Content-Type: text/plain\r\n", s, strlen(s));
    }
    if (!strcmp(what, "agent") && !strcmp(r->method, "GET")) return serve_agent(c, r);
    if (!strcmp(what, "clipboard") && !strcmp(r->method, "GET")) return clipboard_get(c, r);
    if (!strcmp(what, "clipboard") && !strcmp(r->method, "PUT")) return clipboard_put(c, r);
    if (body_discard(c, r) != 0) return -1;
    return respond_empty(c, r, 404, "Not Found");
}

/* ---- requests ---- */

static int header_is(const char *line, const char *name, const char **value) {
    size_t n = strlen(name);
    if (strncasecmp(line, name, n) != 0 || line[n] != ':') return 0;
    const char *v = line + n + 1;
    while (*v == ' ' || *v == '\t') v++;
    *value = v;
    return 1;
}

/* 1 with a request, 0 when the client is done, -1 on a malformed one. */
static int read_request(Conn *c, Request *r) {
    static __thread char head[HEAD_MAX];
    size_t n = 0;
    for (;;) {
        char ch;
        ssize_t got = conn_read(c, &ch, 1);
        if (got <= 0) return n ? -1 : 0;
        if (n + 1 >= sizeof head) return -1;
        head[n++] = ch;
        if (n >= 4 && !memcmp(head + n - 4, "\r\n\r\n", 4)) break;
        if (n == 2 && !memcmp(head, "\r\n", 2)) n = 0; /* blank lines between requests */
    }
    head[n] = 0;
    memset(r, 0, sizeof *r);
    r->range_from = r->range_to = -1;
    r->overwrite = 1;
    r->depth = 1;
    char *line = head, *eol = strstr(line, "\r\n");
    *eol = 0;
    char version[16];
    if (sscanf(line, "%15s %32767s %15s", r->method, r->target, version) != 3) return -1;
    char *query = strchr(r->target, '?');
    if (query) {
        *query++ = 0;
        snprintf(r->query, sizeof r->query, "%s", query);
    }
    /* A client may send the whole URL. */
    if (!strncasecmp(r->target, "http://", 7)) {
        char *p = strchr(r->target + 7, '/');
        memmove(r->target, p ? p : "/", strlen(p ? p : "/") + 1);
    }
    if (decode_path(r->target, r->path, sizeof r->path) != 0) return -1;
    if (!strcmp(version, "HTTP/1.0")) r->close = 1;
    for (line = eol + 2; *line; line = eol + 2) {
        eol = strstr(line, "\r\n");
        if (!eol) break;
        *eol = 0;
        const char *v;
        if (header_is(line, "Content-Length", &v)) r->length = strtoll(v, NULL, 10);
        else if (header_is(line, "Transfer-Encoding", &v)) r->chunked = strcasestr(v, "chunked") != NULL;
        else if (header_is(line, "Expect", &v)) r->expect_continue = strcasestr(v, "100-continue") != NULL;
        else if (header_is(line, "Connection", &v)) r->close = strcasestr(v, "close") != NULL || r->close;
        else if (header_is(line, "Depth", &v)) r->depth = v[0] == '0' ? 0 : 1;
        else if (header_is(line, "Overwrite", &v)) r->overwrite = v[0] != 'F' && v[0] != 'f';
        else if (header_is(line, "If", &v)) snprintf(r->if_header, sizeof r->if_header, "%s", v);
        else if (header_is(line, "Destination", &v)) {
            const char *p = v;
            if (!strncasecmp(p, "http://", 7) || !strncasecmp(p, "https://", 8)) {
                p = strchr(strstr(p, "//") + 2, '/');
                if (!p) p = "/";
            }
            if (decode_path(p, r->destination, sizeof r->destination) != 0) r->destination[0] = 0;
        } else if (header_is(line, "Range", &v) && !strncasecmp(v, "bytes=", 6)) {
            long long a = -1, b = -1;
            const char *s = v + 6;
            if (*s == '-') b = strtoll(s + 1, NULL, 10);
            else {
                char *end;
                a = strtoll(s, &end, 10);
                if (*end == '-' && end[1]) b = strtoll(end + 1, NULL, 10);
            }
            r->range_from = a, r->range_to = b;
        }
    }
    return 1;
}

static int handle(Conn *c, Request *r) {
    if (!strncmp(r->path, "/.henge/", 8)) return serve_henge(c, r);
    if (share_denied(r->path) || (r->destination[0] && share_denied(r->destination))) {
        if (body_discard(c, r) != 0) return -1;
        return respond_empty(c, r, 404, "Not Found");
    }
    const char *m = r->method;
    if (!strcmp(m, "OPTIONS")) {
        if (body_discard(c, r) != 0) return -1;
        return respond(c, r, 200, "OK",
                       "DAV: 1, 2\r\nMS-Author-Via: DAV\r\nAllow: OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, PROPFIND, PROPPATCH, MOVE, COPY, LOCK, UNLOCK\r\n", NULL, 0);
    }
    if (!strcmp(m, "PROPFIND")) return do_propfind(c, r);
    if (!strcmp(m, "PROPPATCH")) return do_proppatch(c, r);
    if (!strcmp(m, "GET") || !strcmp(m, "HEAD")) return do_get(c, r);
    if (!strcmp(m, "PUT")) return do_put(c, r);
    if (!strcmp(m, "DELETE")) return do_delete(c, r);
    if (!strcmp(m, "MKCOL")) return do_mkcol(c, r);
    if (!strcmp(m, "MOVE")) return do_move_copy(c, r, 1);
    if (!strcmp(m, "COPY")) return do_move_copy(c, r, 0);
    if (!strcmp(m, "LOCK")) return do_lock(c, r);
    if (!strcmp(m, "UNLOCK")) {
        if (body_discard(c, r) != 0) return -1;
        return respond_empty(c, r, 204, "No Content");
    }
    if (body_discard(c, r) != 0) return -1;
    return respond_empty(c, r, 405, "Method Not Allowed");
}

static void *connection(void *arg) {
    Conn *c = arg;
    Request *r = malloc(sizeof *r);
    for (;;) {
        int got = read_request(c, r);
        if (got <= 0) {
            if (got < 0) {
                memset(r, 0, sizeof *r);
                strcpy(r->method, "GET");
                r->close = 1;
                respond_empty(c, r, 400, "Bad Request");
            }
            break;
        }
        if (getenv("HV_SHARE_LOG")) fprintf(stderr, "share: %s %s\n", r->method, r->path);
        if (handle(c, r) != 0 || r->close) break;
    }
    close(c->fd);
    free(r);
    free(c);
    return NULL;
}

static void *listener(void *arg) {
    int server = (int)(intptr_t)arg;
    for (;;) {
        int fd = accept(server, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR || errno == ECONNABORTED) continue;
            usleep(100000);
            continue;
        }
        int on = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
        Conn *c = calloc(1, sizeof *c);
        c->fd = fd;
        pthread_t t;
        pthread_attr_t a;
        pthread_attr_init(&a);
        pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
        if (pthread_create(&t, &a, connection, c) != 0) {
            close(fd);
            free(c);
        }
        pthread_attr_destroy(&a);
    }
    return NULL;
}

int hv_share_start(const char *folder, const char *socket_path, const char *agent) {
    static int started;
    if (started) return 0;
    if (!realpath(folder, root)) return -1;
    if (agent) snprintf(agent_path, sizeof agent_path, "%s", agent);
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    if (strlen(socket_path) >= sizeof addr.sun_path) {
        fprintf(stderr, "hengevm: share: socket path too long: %s\n", socket_path);
        return -1;
    }
    strcpy(addr.sun_path, socket_path);
    unlink(socket_path);
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server < 0 || bind(server, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(server, 16) != 0) {
        fprintf(stderr, "hengevm: share: %s: %s\n", socket_path, strerror(errno));
        if (server >= 0) close(server);
        return -1;
    }
    chmod(socket_path, 0600);
    pthread_t t;
    pthread_create(&t, NULL, listener, (void *)(intptr_t)server);
    pthread_detach(t);
    started = 1;
    return 0;
}
