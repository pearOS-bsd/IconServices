/* Test of an NSXPC round trip on pearOS (darwinator + the Mac's Foundation): `xpcping server NAME` listens, `xpcping client NAME` calls ping:reply: synchronously and asynchronously. */
#import <Foundation/Foundation.h>
@protocol PingProtocol
- (void)ping:(NSString *)s reply:(void (^)(NSString *))reply;
- (void)url:(NSString *)s reply:(void (^)(NSURL *))reply;
@end
@interface Pinger : NSObject <PingProtocol, NSXPCListenerDelegate>
@end
@implementation Pinger
- (void)ping:(NSString *)s reply:(void (^)(NSString *))reply { fprintf(stderr, "server: ping %s\n", s.UTF8String); reply([@"pong " stringByAppendingString: s]); fprintf(stderr, "server: replied\n"); }
- (void)url:(NSString *)s reply:(void (^)(NSURL *))reply { fprintf(stderr, "server: url %s\n", s.UTF8String); reply([NSURL fileURLWithPath: s]); fprintf(stderr, "server: replied url\n"); }
- (BOOL)listener:(NSXPCListener *)l shouldAcceptNewConnection:(NSXPCConnection *)c { fprintf(stderr, "server: connection\n"); c.exportedInterface = [NSXPCInterface interfaceWithProtocol: @protocol(PingProtocol)]; c.exportedObject = self; [c resume]; return YES; }
@end
int main(int argc, char **argv)
{
	@autoreleasepool {
		if (argc < 3) return 2;
		NSString *name = @(argv[2]);
		if (!strcmp(argv[1], "server")) {
			Pinger *p = [Pinger new]; NSXPCListener *l = [[NSXPCListener alloc] initWithMachServiceName: name]; l.delegate = p; [l resume];
			fprintf(stderr, "server: listening on %s\n", argv[2]);
			[[NSRunLoop currentRunLoop] run];
		}
		NSXPCConnection *c = [[NSXPCConnection alloc] initWithMachServiceName: name options: 0];
		c.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol: @protocol(PingProtocol)];
		[c resume];
		dispatch_semaphore_t s = dispatch_semaphore_create(0);
		[[c remoteObjectProxyWithErrorHandler: ^(NSError *e) { fprintf(stderr, "client: error %s\n", e.description.UTF8String); dispatch_semaphore_signal(s); }] ping: @"async" reply: ^(NSString *r) { fprintf(stderr, "client: %s\n", r.UTF8String); dispatch_semaphore_signal(s); }];
		long w = dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
		fprintf(stderr, "client: async %s\n", w ? "TIMEOUT" : "done");
		__block int got = 0;
		[[c synchronousRemoteObjectProxyWithErrorHandler: ^(NSError *e) { fprintf(stderr, "client: sync error %s\n", e.description.UTF8String); }] ping: @"sync" reply: ^(NSString *r) { fprintf(stderr, "client: %s\n", r.UTF8String); got++; }];
		fprintf(stderr, "client: sync ping %s\n", got ? "done" : "NO REPLY");
		[[c synchronousRemoteObjectProxyWithErrorHandler: ^(NSError *e) { fprintf(stderr, "client: sync error %s\n", e.description.UTF8String); }] url: @"/tmp/x/" reply: ^(NSURL *u) { fprintf(stderr, "client: url %s\n", u.description.UTF8String); got++; }];
		fprintf(stderr, "client: sync url %s\n", got == 2 ? "done" : "NO REPLY");
		return w || got != 2 ? 1 : 0;
	}
}
