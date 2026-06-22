#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// ================== 系统私有头文件声明 ==================
@interface SBIcon : NSObject
- (NSString *)applicationBundleID;
- (BOOL)isApplicationIcon;
@end

@interface SBIconView : UIView
@property (nonatomic, strong) SBIcon *icon;
- (NSArray *)applicationShortcutItems;
@end

@interface SBSApplicationShortcutSystemIcon : NSObject
- (instancetype)initWithSystemImageName:(NSString *)name;
@end

@interface SBSApplicationShortcutItem : NSObject
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSString *localizedTitle;
@property (nonatomic, strong) id icon;
@end

@interface SBApplication : NSObject
- (NSString *)bundleIdentifier;
@end

@interface SpringBoard : UIApplication
- (SBApplication *)_accessibilityFrontMostApplication; // 极其稳妥的获取前台App的方式
@end

@interface SBVolumeControl : NSObject
+ (instancetype)sharedInstance;
- (void)setVolume:(float)volume forCategory:(NSString *)category;
- (void)setActiveCategoryVolume:(float)volume;
@end


// ================== 全局变量与数据管理 ==================
static BOOL g_isMuting = NO; // 全局拦截HUD状态标志位

static NSString * GetPrefPath() {
    NSString *base = @"/var/mobile/Library/Preferences/com.iosdump.appmute.plist";
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

@interface AppMuteManager : NSObject
@property (nonatomic, strong) NSMutableArray *mutedBundleIDs;
+ (instancetype)sharedManager;
- (BOOL)isMuted:(NSString *)bundleID;
- (void)toggleMute:(NSString *)bundleID;
- (void)performMute;
@end

@implementation AppMuteManager
+ (instancetype)sharedManager {
    static AppMuteManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[AppMuteManager alloc] init];
    });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSArray *saved = [NSArray arrayWithContentsOfFile:GetPrefPath()];
        self.mutedBundleIDs = saved ? [saved mutableCopy] : [NSMutableArray array];
    }
    return self;
}

- (void)save {
    [self.mutedBundleIDs writeToFile:GetPrefPath() atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0777, NSFileProtectionKey: NSFileProtectionNone} ofItemAtPath:GetPrefPath() error:nil];
}

- (BOOL)isMuted:(NSString *)bundleID {
    if (!bundleID) return NO;
    return [self.mutedBundleIDs containsObject:bundleID];
}

- (void)toggleMute:(NSString *)bundleID {
    if (!bundleID) return;
    if ([self isMuted:bundleID]) {
        [self.mutedBundleIDs removeObject:bundleID];
    } else {
        [self.mutedBundleIDs addObject:bundleID];
    }
    [self save];
}

- (void)performMute {
    g_isMuting = YES; // 打开拦截 HUD 标志
    
    // 静音逻辑：强制将媒体音量(Audio/Video)拉到 0
    SBVolumeControl *volCtrl = [%c(SBVolumeControl) sharedInstance];
    if ([volCtrl respondsToSelector:@selector(setVolume:forCategory:)]) {
        [volCtrl setVolume:0.0 forCategory:@"Audio/Video"];
    } else if ([volCtrl respondsToSelector:@selector(setActiveCategoryVolume:)]) {
        [volCtrl setActiveCategoryVolume:0.0];
    }
    
    // 0.5秒后恢复，因为设置音量到底层通信需要短暂时间，等执行完毕后关闭拦截，恢复物理按键弹窗
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        g_isMuting = NO;
    });
}
@end


// ================== 核心 Hook 区 ==================

// 1. 拦截长按图标的菜单项，注入我们的按钮
%hook SBIconView
- (NSArray *)applicationShortcutItems {
    NSArray *orig = %orig;
    SBIcon *icon = self.icon;
    
    if (!icon || ![icon respondsToSelector:@selector(isApplicationIcon)] || ![icon isApplicationIcon]) {
        return orig;
    }
    
    NSString *bundleID = [icon applicationBundleID];
    if (!bundleID) return orig;

    BOOL isMuted = [[AppMuteManager sharedManager] isMuted:bundleID];
    
    SBSApplicationShortcutItem *item = [[%c(SBSApplicationShortcutItem) alloc] init];
    item.type = @"com.iosdump.appmute.toggle";
    item.localizedTitle = isMuted ? @"关闭启动静音" : @"开启启动静音";
    
    // 调用系统图标
    SBSApplicationShortcutSystemIcon *sysIcon = [[%c(SBSApplicationShortcutSystemIcon) alloc] initWithSystemImageName: isMuted ? @"speaker.slash.fill" : @"speaker.wave.2.fill"];
    item.icon = sysIcon;
    
    NSMutableArray *mutOrig = orig ? [orig mutableCopy] : [NSMutableArray array];
    [mutOrig addObject:item];
    return mutOrig;
}
%end

// 2. 处理我们注入按钮的点击事件 (iOS 13-17 标准处理点)
%hook SBIconController
- (void)appIconForceTouchController:(id)arg1 processApplicationShortcutItem:(SBSApplicationShortcutItem *)item forIconView:(SBIconView *)iconView {
    if ([item.type isEqualToString:@"com.iosdump.appmute.toggle"]) {
        NSString *bundleID = [iconView.icon applicationBundleID];
        if (bundleID) {
            [[AppMuteManager sharedManager] toggleMute:bundleID];
            
            // 为了更好的用户体验，触发个轻微的震动反馈
            UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [feedback impactOccurred];
        }
        return; // 拦截掉，不让系统继续处理
    }
    %orig;
}
%end

// 为了兼容部分其他 iOS 14 版本处理路径的容错 Hook
%hook SBUIAppIconForceTouchController
- (void)appIconForceTouchController:(id)arg1 processApplicationShortcutItem:(SBSApplicationShortcutItem *)item forIconView:(SBIconView *)iconView {
    if ([item.type isEqualToString:@"com.iosdump.appmute.toggle"]) {
        NSString *bundleID = [iconView.icon applicationBundleID];
        if (bundleID) {
            [[AppMuteManager sharedManager] toggleMute:bundleID];
        }
        return;
    }
    %orig;
}
%end

// 3. 监听 App 切到前台的时机
%hook SpringBoard
- (void)frontDisplayDidChange:(id)arg1 {
    %orig;
    
    // 获取当前来到最前台的 App
    SBApplication *app = [self _accessibilityFrontMostApplication];
    if (app && [app respondsToSelector:@selector(bundleIdentifier)]) {
        NSString *bundleID = [app bundleIdentifier];
        if ([[AppMuteManager sharedManager] isMuted:bundleID]) {
            [[AppMuteManager sharedManager] performMute];
        }
    }
}
%end

// 4. 彻底隐藏由于调低音量引发的系统自带音量 HUD (只拦截代码静音期间)
%hook SBVolumeControl
- (void)_presentVolumeHUDWithVolume:(float)volume {
    if (g_isMuting) {
        return; // 处于自动静音期间，直接吃掉弹窗逻辑
    }
    %orig;
}

// 补充拦截: iOS 14-15 的部分老方法
- (void)_presentVolumeHUDIfDisplayable:(BOOL)displayable orRefreshIfPresentedWithReason:(id)reason {
    if (g_isMuting) {
        return;
    }
    %orig;
}
%end

// ================== 初始化构造 ==================
%ctor {
    @autoreleasepool {
        // 预加载配置
        [AppMuteManager sharedManager];
    }
}
