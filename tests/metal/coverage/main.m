// x86Sim MetalCoverage: the app. The suite runs on a background thread at launch (the main thread stays free for
// FrontBoard's launch watchdog); each result is appended to an on-screen log.
#import <UIKit/UIKit.h>
#import "mtlcov.h"

void mc_run_all(void (^progress)(int i, int n, NSString* name, MCStatus st, NSString* detail));
int mc_test_count(void);

@interface MCScene : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow* window;
@end

@implementation MCScene
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)s options:(UISceneConnectionOptions*)o {
	self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
	UIViewController* vc = [UIViewController new];
	UITextView* tv = [[UITextView alloc] initWithFrame:vc.view.bounds];
	tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	tv.editable = NO;
	tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
	tv.text = [NSString stringWithFormat:@"MetalCoverage: %d tests\n", mc_test_count()];
	[vc.view addSubview:tv];
	self.window.rootViewController = vc;
	[self.window makeKeyAndVisible];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		mc_run_all(^(int i, int n, NSString* name, MCStatus st, NSString* detail) {
			NSString* line = [NSString stringWithFormat:@"%3d/%d %@ %@ %@\n", i + 1, n,
				st == MC_PASS ? @"✓" : st == MC_FAIL ? @"✗" : @"–", name, detail];
			dispatch_async(dispatch_get_main_queue(), ^{
				tv.text = [tv.text stringByAppendingString:line];
				[tv scrollRangeToVisible:NSMakeRange(tv.text.length - 1, 1)];
			});
		});
	});
}
@end

@interface MCApp : UIResponder <UIApplicationDelegate>
@end
@implementation MCApp
- (UISceneConfiguration*)application:(UIApplication*)a configurationForConnectingSceneSession:(UISceneSession*)s
                             options:(UISceneConnectionOptions*)o {
	UISceneConfiguration* c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
	c.delegateClass = [MCScene class];
	return c;
}
@end

int main(int argc, char* argv[]) {
	@autoreleasepool { return UIApplicationMain(argc, argv, nil, @"MCApp"); }
}
