/* Test on pearOS: calls the agent the way IconServices.framework does (the framework's interface, synchronous fetchCacheConfigurationWithReply:), then asks for one icon. */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <dlfcn.h>
int main(int argc, char **argv)
{
	@autoreleasepool {
		dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_NOW);
		NSXPCConnection *c = [[NSXPCConnection alloc] initWithMachServiceName: @"com.apple.iconservices" options: 0];
		c.remoteObjectInterface = ((id (*)(id, SEL))objc_msgSend)([NSXPCInterface class], sel_registerName("_IS_iconCacheServiceInterface"));
		[c resume];
		__block id got = nil;
		id p = [c synchronousRemoteObjectProxyWithErrorHandler: ^(NSError *e) { fprintf(stderr, "client: error %s\n", e.description.UTF8String); }];
		((void (*)(id, SEL, id))objc_msgSend)(p, sel_registerName("fetchCacheConfigurationWithReply:"), ^(id conf) { got = conf; });
		fprintf(stderr, "client: configuration %s url %s\n", got ? "received" : "NONE", got ? [[[got valueForKey: @"url"] description] UTF8String] : "-");
		if (argc > 1) {
			id icon = ((id (*)(id, SEL, id))objc_msgSend)([NSClassFromString(@"ISBundleIcon") alloc], sel_registerName("initWithBundleURL:"), [NSURL fileURLWithPath: @(argv[1])]);
			id d = ((id (*)(id, SEL, CGSize, double))objc_msgSend)([NSClassFromString(@"ISImageDescriptor") alloc], sel_registerName("initWithSize:scale:"), CGSizeMake(64, 64), 1.0);
			CGImageRef im = ((CGImageRef (*)(id, SEL, id))objc_msgSend)(icon, sel_registerName("CGImageForImageDescriptor:"), d);
			fprintf(stderr, "client: image %p %zux%zu\n", (void *)im, im ? CGImageGetWidth(im) : 0, im ? CGImageGetHeight(im) : 0);
		}
	}
	return 0;
}
