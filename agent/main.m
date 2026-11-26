/* iconservicesagent: the per-user icon renderer of IconServices (Mach service com.apple.iconservices), wire-compatible with macOS 26.7.2.
 * Protocol ISIconCacheServiceProtocol (research/docs/ICONSERVICES-WIRE.md 2.1, 5, 6, 7):
 *   fetchCacheConfigurationWithReply:   where the per-user index is (every client asks once, synchronously, before its first icon)
 *   generateImageWithRequest:reply:     render one icon at one size, store the unit through iconservicesd, add it to the index, reply with the unit
 *   clearAllCachedItemsWithReply:       empty the index
 * Rendering: the recipe of IconServices.framework itself (-[ISGenerationRequest generateImageReturningRecordIdentifiers:], what the real agent calls);
 * where it gives nothing (pearOS without Metal), the icon is drawn here from the bundle's .icns with ImageIO and wrapped in an IFImage unit.
 * Our own code (BSD-2-Clause); the IS / IF classes come from IconServices.framework at run time. */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <unistd.h>
#import "../common/store_index.h"

extern bool _set_user_dir_suffix(const char *suffix);
extern unsigned char *CC_MD5(const void *data, uint32_t len, unsigned char *md);

#define MSG(T, ...) ((T (*)(__VA_ARGS__))objc_msgSend)

static void Log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void Log(NSString *fmt, ...)
{
	if (!getenv("ISAGENT_LOG")) return;
	va_list a; va_start(a, fmt); NSString *s = [[NSString alloc] initWithFormat: fmt arguments: a]; va_end(a);
	fprintf(stderr, "iconservicesagent: %s\n", s.UTF8String);
}

/* <DARWIN_USER_CACHE_DIR>/com.apple.iconservicesagent/../com.apple.iconservices/ : the agent sets its own cache suffix, the index lives next to it (the string of the Mac's reply) */
static NSString *IndexDirectory(void)
{
	char buf[1024];
	if (confstr(_CS_DARWIN_USER_CACHE_DIR, buf, sizeof buf) == 0) return [NSTemporaryDirectory() stringByAppendingPathComponent: @"com.apple.iconservices/"];
	NSString *own = @(buf);
	mkdir(own.fileSystemRepresentation, 0700);
	NSString *dir = [own stringByAppendingString: @"/../com.apple.iconservices/"];
	mkdir(dir.fileSystemRepresentation, 0711);
	return dir;
}

static NSString *SandboxExtension(NSString *path)
{
	char *(*issue)(const char *, const char *, uint32_t) = (char *(*)(const char *, const char *, uint32_t))dlsym(RTLD_DEFAULT, "sandbox_extension_issue_file");
	char *t = issue ? issue("com.apple.app-sandbox.read", path.fileSystemRepresentation, 0) : NULL;
	NSString *s = t ? @(t) : @"";
	free(t);
	return s;
}

/* name-based UUID (version 3, MD5) over the given bytes, the kind of the Mac's unit UUIDs */
static NSUUID *NameUUID(NSData *bytes)
{
	unsigned char md[16];
	CC_MD5(bytes.bytes, (uint32_t)bytes.length, md);
	md[6] = (md[6] & 0x0f) | 0x30; md[8] = (md[8] & 0x3f) | 0x80;
	return [[NSUUID alloc] initWithUUIDBytes: md];
}
static void UUIDBytes(NSUUID *u, uint8_t out[16]) { if (u) [u getUUIDBytes: out]; else memset(out, 0, 16); }

/* the fallback renderer: the largest-enough representation of an .icns, scaled into a square bitmap */
static CGImageRef CopyIcnsImage(CGImageSourceRef src, size_t px)
{
	if (!src) return NULL;
	size_t n = CGImageSourceGetCount(src), best = SIZE_MAX, bestW = 0;
	for (size_t i = 0; i < n; i++) {
		NSDictionary *p = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, i, NULL));
		size_t w = [p[(id)kCGImagePropertyPixelWidth] unsignedLongValue];
		if (best == SIZE_MAX || (bestW < px && w > bestW) || (w >= px && w < bestW)) { best = i; bestW = w; }
	}
	if (best == SIZE_MAX) return NULL;
	CGImageRef im = CGImageSourceCreateImageAtIndex(src, best, NULL);
	if (!im) return NULL;
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGContextRef c = CGBitmapContextCreate(NULL, px, px, 8, px * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
	CGColorSpaceRelease(cs);
	if (!c) { CGImageRelease(im); return NULL; }
	CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
	CGContextDrawImage(c, CGRectMake(0, 0, px, px), im);
	CGImageRelease(im);
	CGImageRef out = CGBitmapContextCreateImage(c);
	CGContextRelease(c);
	return out;
}

static NSURL *BundleIconFile(NSURL *bundle)
{
	NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL: [bundle URLByAppendingPathComponent: @"Contents/Info.plist"]];
	NSString *name = info[@"CFBundleIconFile"];
	if (!name.length) return nil;
	if (!name.pathExtension.length) name = [name stringByAppendingPathExtension: @"icns"];
	return [bundle URLByAppendingPathComponent: [@"Contents/Resources" stringByAppendingPathComponent: name]];
}

static id FallbackImage(id icon, CGFloat points, CGFloat scale)
{
	CGImageSourceRef src = NULL;
	NSString *cls = NSStringFromClass([icon class]);
	if ([cls isEqualToString: @"ISBundleIcon"] && [icon respondsToSelector: @selector(url)]) {
		NSURL *f = BundleIconFile([icon valueForKey: @"url"]);
		if (f) src = CGImageSourceCreateWithURL((__bridge CFURLRef)f, NULL);
	} else if ([cls isEqualToString: @"ISIcnsIcon"] && [icon respondsToSelector: @selector(icnsData)]) {
		NSData *d = [icon valueForKey: @"icnsData"];
		if (d) src = CGImageSourceCreateWithData((__bridge CFDataRef)d, NULL);
	}
	CGImageRef im = CopyIcnsImage(src, (size_t)(points * scale + 0.5));
	if (src) CFRelease(src);
	if (!im) return nil;
	Class IF = NSClassFromString(@"IFImage");
	id out = IF ? MSG(id, id, SEL, CGImageRef, double, CGSize, BOOL)([IF alloc], sel_registerName("initWithCGImage:scale:minimumSize:placeholder:"), im, scale, CGSizeMake(points, points), NO) : nil;
	CGImageRelease(im);
	return out;
}

@interface IconCacheService : NSObject <NSXPCListenerDelegate>
@end

@implementation IconCacheService {
	NSString *indexDir;
	dispatch_queue_t queue;
	NSXPCConnection *store;
}
- (instancetype)init
{
	if ((self = [super init])) { indexDir = IndexDirectory(); queue = dispatch_queue_create("com.apple.iconservices.generation", DISPATCH_QUEUE_SERIAL); }
	return self;
}
- (NSString *)indexPath { return [indexDir stringByAppendingPathComponent: @"store.index"]; }

/* the connection to iconservicesd, privileged like the Mac's (XPC_CONNECTION_MACH_SERVICE_PRIVILEGED) */
- (id)storeProxy
{
	if (!store) {
		store = [[NSXPCConnection alloc] initWithMachServiceName: @"com.apple.iconservices.store" options: NSXPCConnectionPrivileged];
		store.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol: NSProtocolFromString(@"ISStoreServiceProtocol")];
		__weak IconCacheService *weak = self;
		store.invalidationHandler = ^{ IconCacheService *s = weak; if (s) dispatch_async(s->queue, ^{ s->store = nil; }); };
		[store resume];
	}
	return [store remoteObjectProxyWithErrorHandler: ^(NSError *e) { Log(@"store: %@", e); }];
}
- (BOOL)storeData:(NSData *)data uuid:(NSUUID *)uuid
{
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	__block BOOL ok = NO;
	id proxy = [self storeProxy];
	MSG(void, id, SEL, id, id, id, id)(proxy, sel_registerName("addData:withUUID:domain:completion:"), data, uuid, nil, ^(BOOL r) { ok = r; dispatch_semaphore_signal(done); });
	if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) { Log(@"store: no answer"); return NO; }
	return ok;
}

- (void)fetchCacheConfigurationWithReply:(void (^)(id))reply
{
	id conf = [NSClassFromString(@"ISIconCacheConfiguration") new];
	[conf setValue: [NSURL fileURLWithPath: indexDir isDirectory: YES] forKey: @"url"];
	[conf setValue: SandboxExtension(indexDir) forKey: @"sandboxExtension"];
	Log(@"configuration: %@", indexDir);
	@try { reply(conf); } @catch (id e) { Log(@"configuration reply: exception %@", e); }
	Log(@"configuration sent");
}

- (void)clearAllCachedItemsWithReply:(void (^)(BOOL, NSError *))reply
{
	dispatch_async(queue, ^{
		BOOL ok = unlink(self.indexPath.fileSystemRepresentation) == 0 || errno == ENOENT;
		reply(ok, ok ? nil : [NSError errorWithDomain: NSPOSIXErrorDomain code: errno userInfo: nil]);
	});
}

- (void)generateImageWithRequest:(id)request reply:(void (^)(id))reply
{
	dispatch_async(queue, ^{ @autoreleasepool { reply([self responseForRequest: request]); } });
}

- (id)responseForRequest:(id)request
{
	Class R = NSClassFromString(@"ISGenerationResponse");
	id icon = [request valueForKey: @"icon"], desc = [request valueForKey: @"imageDescriptor"];
	if (!icon || !desc) return MSG(id, id, SEL, id)([R alloc], sel_registerName("initWithError:"), [NSError errorWithDomain: NSPOSIXErrorDomain code: EINVAL userInfo: nil]);
	CGSize size = MSG(CGSize, id, SEL)(desc, sel_registerName("size"));
	double scale = MSG(double, id, SEL)(desc, sel_registerName("scale"));
	if (scale <= 0) scale = 1;
	NSUUID *iconDigest = [icon valueForKey: @"digest"], *descDigest = [desc valueForKey: @"digest"];

	id ids = nil;
	id image = MSG(id, id, SEL, id *)(request, sel_registerName("generateImageReturningRecordIdentifiers:"), &ids);
	NSData *data = image ? [image valueForKey: @"data"] : nil;
	if (!data) { image = FallbackImage(icon, size.width, scale); data = image ? [image valueForKey: @"data"] : nil; Log(@"fallback renderer for %@: %@", icon, data ? @"ok" : @"nothing"); }
	if (!data) return MSG(id, id, SEL, id)([R alloc], sel_registerName("initWithError:"), [NSError errorWithDomain: NSPOSIXErrorDomain code: ENOENT userInfo: nil]);

	/* the unit's name: a name-based UUID of the icon, the descriptor and the size (any stable function works between our components: research U2) */
	uint8_t key[16 + 16 + 16];
	UUIDBytes(iconDigest, key); UUIDBytes(descDigest, key + 16);
	double sz[2] = { size.width, scale }; memcpy(key + 32, sz, 16);
	NSUUID *unit = NameUUID([NSData dataWithBytes: key length: sizeof key]);

	/* validation token: LS database UUID + sequence number of the request, and the RSC UUID of the records the unit came from */
	uint8_t token[40];
	UUIDBytes([request valueForKey: @"lsDatabaseUUID"], token);
	uint64_t seq = MSG(uint64_t, id, SEL)(request, sel_registerName("lsDatabaseSequenceNumber")); memcpy(token + 16, &seq, 8);
	NSMutableData *rsc = [NSMutableData dataWithBytes: key length: 16];
	if (ids) [rsc appendData: [[ids description] dataUsingEncoding: NSUTF8StringEncoding]];
	UUIDBytes(NameUUID(rsc), token + 24);
	NSData *tokenData = [NSData dataWithBytes: token length: sizeof token];

	if (![self storeData: data uuid: unit]) Log(@"unit %@ not stored", unit);
	else {
		is_index_value v; memset(&v, 0, sizeof v);
		UUIDBytes(iconDigest, v.icon_digest); UUIDBytes(descDigest, v.descriptor_digest); UUIDBytes(unit, v.unit_uuid);
		CGSize min = [image respondsToSelector: @selector(minimumSize)] ? MSG(CGSize, id, SEL)(image, sel_registerName("minimumSize")) : size;
		v.size_from = min.width > 0 && min.width <= size.width ? min.width : size.width;
		v.size_to = v.nominal = size.width;
		v.scale = (uint32_t)scale;
		memcpy(v.token, token, sizeof token);
		if (is_index_add(self.indexPath.fileSystemRepresentation, &v) < 0) Log(@"index: %s", strerror(errno));
	}
	Log(@"generated %@ %gpt@%gx -> %@ (%lu bytes)", NSStringFromClass([icon class]), size.width, scale, unit.UUIDString, (unsigned long)data.length);
	return MSG(id, id, SEL, id, id, id)([R alloc], sel_registerName("initWithData:uuid:validationToken:"), data, unit, tokenData);
}

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)c
{
	NSXPCInterface *i = MSG(id, id, SEL)([NSXPCInterface class], sel_registerName("_IS_iconCacheServiceInterface"));    /* the interface of the framework: the class sets of the Mac exactly */
	if (!i) return NO;
	c.exportedInterface = i;
	c.exportedObject = self;
	[c resume];
	return YES;
}
@end

int main(void)
{
	@autoreleasepool {
		_set_user_dir_suffix("com.apple.iconservicesagent");
		if (!dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_NOW)) { fprintf(stderr, "iconservicesagent: IconServices.framework: %s\n", dlerror()); return 1; }
		IconCacheService *service = [IconCacheService new];
		NSXPCListener *listener = [[NSXPCListener alloc] initWithMachServiceName: @"com.apple.iconservices"];
		listener.delegate = service;
		[listener resume];
		[[NSRunLoop currentRunLoop] run];
	}
	return 0;
}
