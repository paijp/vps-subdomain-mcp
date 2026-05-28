/*
 * list-containers.c  –  setuid-root Podman container lister
 *
 * Build:
 *   cc -O2 -std=c11 -Wall -Wextra -static -o list-containers list-containers.c
 *   chown root:root list-containers && chmod 4755 list-containers
 *
 * Output:  name TAB ip TAB state NEWLINE  (one line per container, all=true)
 * stderr + exit(1) on any error.  No execve/popen/system.  No env vars read.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

#define SOCK_PATH "/run/podman/podman.sock"
#define REQUEST   "GET /containers/json?all=true HTTP/1.0\r\nHost: d\r\n\r\n"
#define RESP_MAX  (1 << 20)  /* 1 MiB ceiling */

static void die(const char *msg) {
    fprintf(stderr, "list-containers: %s\n", msg);
    exit(1);
}

/*
 * Return malloc'd copy of the first JSON string for key.
 * Handles both  "key": "val"  and  "key": ["val", ...]  forms.
 * Returns "" (static) when not found.
 */
static const char *json_str(const char *hay, const char *key) {
    static char empty[] = "";
    char needle[64];
    snprintf(needle, sizeof needle, "\"%s\"", key);
    const char *p = strstr(hay, needle);
    if (!p) return empty;
    p += strlen(needle);
    while (*p == ' ' || *p == ':' || *p == '[') p++;  /* skip array bracket */
    if (*p++ != '"') return empty;
    const char *end = p;
    while (*end && *end != '"') { if (*end == '\\') end++; if (*end) end++; }
    size_t len = (size_t)(end - p);
    char  *out = malloc(len + 1);
    if (!out) die("malloc");
    memcpy(out, p, len);
    out[len] = '\0';
    return out;
}

int main(void) {
    /* Connect to Podman socket */
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) die("socket()");
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCK_PATH, sizeof addr.sun_path - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0)
        die("connect(" SOCK_PATH "): is Podman running?");

    /* Send HTTP request */
    if (write(fd, REQUEST, strlen(REQUEST)) < 0) die("write()");

    /* Read full response (bounded) */
    char *buf = malloc(RESP_MAX + 1);
    if (!buf) die("malloc");
    ssize_t total = 0, n;
    while (total < RESP_MAX &&
           (n = read(fd, buf + total, (size_t)(RESP_MAX - total))) > 0)
        total += n;
    close(fd);
    if (total <= 0) die("empty response");
    buf[total] = '\0';

    /* Skip HTTP headers */
    const char *body = strstr(buf, "\r\n\r\n");
    if (!body) body = strstr(buf, "\n\n");
    if (!body) die("malformed HTTP response");
    body += (body[0] == '\r') ? 4 : 2;

    /* Iterate JSON container objects [{...},{...}] */
    const char *p = strchr(body, '[');
    if (!p) die("no JSON array in response");

    while ((p = strchr(p, '{')) != NULL) {
        /* Find matching '}' tracking brace depth */
        int depth = 1;
        const char *q = p + 1;
        while (*q && depth > 0) {
            if (*q == '\\') { q += 2; continue; }   /* skip escaped chars */
            if (*q == '"')  { while (*++q && (*q != '"' || *(q-1) == '\\')); }
            if (*q == '{') depth++;
            else if (*q == '}') depth--;
            if (*q) q++;
        }
        if (depth != 0) break;

        size_t len = (size_t)(q - p);
        char  *obj = malloc(len + 1);
        if (!obj) die("malloc");
        memcpy(obj, p, len);
        obj[len] = '\0';

        const char *name  = json_str(obj, "Names");
        if (name[0] == '/') name++;        /* strip Podman's leading '/' */
        const char *ip    = json_str(obj, "IPAddress");
        const char *state = json_str(obj, "State");

        printf("%s\t%s\t%s\n", name, ip, state);

        free((void *)name); free((void *)ip); free((void *)state); free(obj);
        p = q;
    }

    free(buf);
    return 0;
}
