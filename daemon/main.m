/* iconservicesd: the store of IconServices (Mach service com.apple.iconservices.store), wire-compatible with macOS 26.7.2.
 * Protocol ISStoreServiceProtocol (research/docs/ICONSERVICES-WIRE.md 2.2): the agent writes rendered units through it, every client asks it where the store is.
 * The units are files <UUID>.isdata in /Library/Caches/com.apple.iconservices.store; this process is their only writer (on the Mac it runs as _iconservices).
 * Our own code (BSD-2-Clause); the NSXPC protocol object comes from IconServices.framework at run time. */
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <unistd.h>

static void Log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void Log(NSString *fmt, ...)
{
	if (!getenv("ISD_LOG")) return;
	va_list a; va_start(a, fmt); NSString *s = [[NSString alloc] initWithFormat: fmt arguments: a]; va_end(a);
	fprintf(stderr, "iconservicesd: %s\n", s.UTF8String);
}

static NSString *const kStorePath = @"/Library/Caches/com.apple.iconservices.store";

/* a read extension for the store directory, as the Mac gives its clients; FreeBSD has no sandbox: an empty string then (our clients do not consume it) */
static NSString *SandboxExtension(NSString *path)
{
	static char *(*issue)(const char *, const char *, uint32_t);
	static dispatch_once_t once;
	dispatch_once(&once, ^{ issue = (char *(*)(const char *, const char *, uint32_t))dlsym(RTLD_DEFAULT, "sandbox_extension_issue_file"); });
	char *t = issue ? issue("com.apple.app-sandbox.read", path.fileSystemRepresentation, 0) : NULL;
	NSString *s = t ? @(t) : @"";
	free(t);
	return s;
}

static NSString *StoreDirectory(NSString *domain)
{
	/* the Mac always passes domain nil (research U7); a domain is kept in a subdirectory so that it cannot reach outside the store */
	if (domain.length == 0) return kStorePath;
	if ([domain containsString: @"/"] || [domain hasPrefix: @"."]) return nil;
	return [kStorePath stringByAppendingPathComponent: domain];
}

@interface StoreService : NSObject <NSXPCListenerDelegate>
@end

@implementation StoreService
- (void)fetchCachePathForDomain:(NSString *)domain completion:(void (^)(NSString *, NSString *))completion
{
	NSString *dir = StoreDirectory(domain);
	if (dir) mkdir(dir.fileSystemRepresentation, 0711);
	Log(@"cache path for domain %@: %@", domain, dir);
	completion(dir, dir ? SandboxExtension(dir) : nil);
}
- (void)addData:(NSData *)data withUUID:(NSUUID *)uuid domain:(NSString *)domain completion:(void (^)(BOOL))completion
{
	NSString *dir = StoreDirectory(domain);
	if (!dir || !data || !uuid) { completion(NO); return; }
	mkdir(dir.fileSystemRepresentation, 0711);
	NSString *file = [dir stringByAppendingPathComponent: [uuid.UUIDString stringByAppendingPathExtension: @"isdata"]];
	/* written to a temporary name and renamed: a client that maps the unit never sees a half-written file */
	NSString *tmp = [file stringByAppendingFormat: @".%d", getpid()];
	BOOL ok = [data writeToFile: tmp options: 0 error: NULL] && chmod(tmp.fileSystemRepresentation, 0644) == 0 && rename(tmp.fileSystemRepresentation, file.fileSystemRepresentation) == 0;
	if (!ok) unlink(tmp.fileSystemRepresentation);
	Log(@"add %@ (%lu bytes): %d", uuid.UUIDString, (unsigned long)data.length, ok);
	completion(ok);
}
- (void)removeItemWithUUID:(NSUUID *)uuid domain:(NSString *)domain completion:(void (^)(BOOL))completion
{
	NSString *dir = StoreDirectory(domain);
	if (!dir || !uuid) { completion(NO); return; }
	NSString *file = [dir stringByAppendingPathComponent: [uuid.UUIDString stringByAppendingPathExtension: @"isdata"]];
	completion(unlink(file.fileSystemRepresentation) == 0);
}
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)c
{
	Protocol *p = NSProtocolFromString(@"ISStoreServiceProtocol");
	Log(@"connection (protocol %s)", p ? "found" : "MISSING");
	if (!p) return NO;
	c.exportedInterface = [NSXPCInterface interfaceWithProtocol: p];
	c.exportedObject = self;
	[c resume];
	return YES;
}
@end

int main(void)
{
	@autoreleasepool {
		if (!dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_NOW)) { fprintf(stderr, "iconservicesd: IconServices.framework: %s\n", dlerror()); return 1; }
		StoreService *service = [StoreService new];
		NSXPCListener *listener = [[NSXPCListener alloc] initWithMachServiceName: @"com.apple.iconservices.store"];
		listener.delegate = service;
		[listener resume];
		[[NSRunLoop currentRunLoop] run];
	}
	return 0;
}
