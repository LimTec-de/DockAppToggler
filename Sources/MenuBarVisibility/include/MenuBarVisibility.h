#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Process-scoped visibility on macOS 27. Releasing the handle restores the menu bar.
@interface MenuBarVisibility : NSObject
+ (void)activateAllowingBundles:(NSArray<NSString *> *)bundles
                    completion:(void (^)(MenuBarVisibility * _Nullable, NSError * _Nullable))completion;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
