/* Test on pearOS: encodes the classes the agent sends (ISIconCacheConfiguration) with a secure keyed archiver, to tell an encoding failure from a transport one. */
#import <Foundation/Foundation.h>
#import <dlfcn.h>
@interface NSKeyedArchiver (ISTest)
+ (NSData *)archivedDataWithRootObject:(id)object requiringSecureCoding:(BOOL)secure error:(NSError **)error;
@end
int main(void)
{
	@autoreleasepool {
		fprintf(stderr, "dlopen %p\n", dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_NOW));
		id conf = [NSClassFromString(@"ISIconCacheConfiguration") new];
		fprintf(stderr, "conf %p\n", (__bridge void *)conf);
		[conf setValue: [NSURL fileURLWithPath: @"/tmp/x/"] forKey: @"url"];
		[conf setValue: @"" forKey: @"sandboxExtension"];
		fprintf(stderr, "set\n");
		@try {
			NSError *e = nil;
			NSData *d = [NSKeyedArchiver archivedDataWithRootObject: conf requiringSecureCoding: YES error: &e];
			fprintf(stderr, "archived %lu bytes, error %s\n", (unsigned long)d.length, e.description.UTF8String);
		} @catch (id x) { fprintf(stderr, "exception %s\n", [[x description] UTF8String]); }
	}
	return 0;
}
