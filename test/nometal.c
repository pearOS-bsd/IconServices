/* Test helper (macOS): a process with no Metal device, as on pearOS: MTLCreateSystemDefaultDevice -> nil, MTLCopyAllDevices -> empty. */
#include <CoreFoundation/CoreFoundation.h>
extern void *MTLCreateSystemDefaultDevice(void);
extern CFArrayRef MTLCopyAllDevices(void);
static void *my_default(void) { return 0; }
static CFArrayRef my_all(void) { return CFArrayCreate(0, 0, 0, &kCFTypeArrayCallBacks); }
__attribute__((used, section("__DATA,__interpose"))) static struct { const void *a, *b; } interpose[] = {
	{ (const void *)my_default, (const void *)MTLCreateSystemDefaultDevice }, { (const void *)my_all, (const void *)MTLCopyAllDevices } };
