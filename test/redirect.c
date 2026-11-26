/* Test helper (macOS): renames Mach services for one process, so that Apple's client code can be pointed at our services, and ours can listen beside Apple's
 * (SIP does not let the real iconservices jobs be booted out).  IS_REDIRECT="from=to,from=to"; inserted with DYLD_INSERT_LIBRARIES.  Not part of the product. */
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <dispatch/dispatch.h>
#include <xpc/xpc.h>
static const char *map(const char *name)
{
	static char buf[4096];
	const char *r = getenv("IS_REDIRECT");
	if (!r || !name) return name;
	strncpy(buf, r, sizeof buf - 1);
	for (char *save = NULL, *p = strtok_r(buf, ",", &save); p; p = strtok_r(NULL, ",", &save)) {
		char *eq = strchr(p, '=');
		if (eq) { *eq = 0; if (!strcmp(p, name)) return strdup(eq + 1); }
	}
	return name;
}
static xpc_connection_t my_create(const char *name, dispatch_queue_t q, uint64_t flags) { return xpc_connection_create_mach_service(map(name), q, flags); }
__attribute__((used, section("__DATA,__interpose"))) static struct { const void *a, *b; } interpose[] = { { (const void *)my_create, (const void *)xpc_connection_create_mach_service } };
