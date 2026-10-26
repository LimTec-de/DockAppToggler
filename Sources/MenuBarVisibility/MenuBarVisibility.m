#import "MenuBarVisibility.h"
#import <dlfcn.h>
#import <objc/message.h>

@implementation MenuBarVisibility {
    id _assertion;
}

+ (void)activateAllowingBundles:(NSArray<NSString *> *)bundles
                    completion:(void (^)(MenuBarVisibility *, NSError *))completion {
    void (^fail)(NSString *) = ^(NSString *reason) {
        completion(nil, [NSError errorWithDomain:@"DockAppToggler.MenuBarVisibility" code:1
                                       userInfo:@{NSLocalizedDescriptionKey: reason}]);
    };
    // Resolve the private macOS 27 API at runtime; older systems never use this path.
    static void *framework;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        framework = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW | RTLD_LOCAL);
    });
    Class configurationClass = NSClassFromString(@"MBAssessmentModeConfiguration");
    Class assertionClass = NSClassFromString(@"MBAssessmentModeAssertion");
    SEL configure = NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:");
    SEL activate = NSSelectorFromString(@"activateWithConfiguration:completionHandler:");
    SEL invalidate = NSSelectorFromString(@"invalidate");
    if (!framework || ![configurationClass instancesRespondToSelector:configure] ||
        ![assertionClass instancesRespondToSelector:activate] ||
        ![assertionClass instancesRespondToSelector:invalidate]) {
        fail(@"Die Menüleistensteuerung ist auf diesem macOS nicht verfügbar.");
        return;
    }
    @try {
        // System controls are never assigned to a hidden section. macOS 27.0 uses
        // identifiers in this range; unknown entries are ignored by the framework.
        NSMutableArray<NSNumber *> *systemItems = [NSMutableArray array];
        for (NSInteger item = 0; item < 64; item++) [systemItems addObject:@(item)];
        id configuration = ((id (*)(id, SEL, id, id))objc_msgSend)(
            [configurationClass alloc], configure, systemItems, bundles);
        MenuBarVisibility *handle = [MenuBarVisibility new];
        handle->_assertion = [assertionClass new];
        if (!configuration || !handle->_assertion) {
            fail(@"Die Menüleistensteuerung konnte nicht initialisiert werden.");
            return;
        }
        ((void (*)(id, SEL, id, id))objc_msgSend)(handle->_assertion, activate, configuration, ^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) [handle invalidate];
                completion(error ? nil : handle, error);
            });
        });
    } @catch (NSException *exception) {
        fail([NSString stringWithFormat:@"Menüleistensteuerung fehlgeschlagen: %@", exception.reason]);
    }
}

- (void)invalidate {
    id assertion = _assertion;
    _assertion = nil;
    if (assertion) ((void (*)(id, SEL))objc_msgSend)(assertion, NSSelectorFromString(@"invalidate"));
}

- (void)dealloc {
    [self invalidate];
}
@end
