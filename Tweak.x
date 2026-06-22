#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// ================== 系统私有头文件精准声明 ==================
@interface SBIcon : NSObject
- (NSString *)applicationBundleID;
- (BOOL)isApplicationIcon;
@end

@interface SBIconView : UIView
@property (nonatomic, strong) SBIcon *icon;
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

@interface SBVolumeControl : NSObject
+ (instancetype)sharedInstance; // 仅 iOS 14-15
- (void)setVolume:(float)volume forCategory:(NSString *)category;
- (void)setActiveCategoryVolume:(float)volume;
- (float)_effectiveVolume; // 全版本都有的获取当前音量方法
@end

@interface SpringBoard : UIApplication
- (SBApplication *)_accessibilityFrontMostApplication;
@property (readonly, nonatomic) SBVolumeControl *volumeControl; // iOS 16-17
@end

@interface SBMediaController : NSObject
+ (instancetype)sharedInstance;
+ (instancetype)sharedInstanceIfExists; // iOS 17
@property (nonatomic, assign) BOOL suppressHUD; // 隐藏系统音量进度条
@end

// ================== 全局数据与状态管理 ==================
static BOOL g_isMutingHUD = NO; // 控制 HUD 拦截

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
@property (nonatomic, copy) NSString *lastFrontmostBundleID; // 记录上一个前台App
@property (nonatomic, assign) float savedVolume;             // 记录进入前的原音量
@property (nonatomic, assign) BOOL isCurrentlyMuted;         // 当前是否处于代码强制静音状态
+ (instancetype)sharedManager;
- (void)checkAppTransition;
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
        self.savedVolume = -1.0;
        self.isCurrentlyMuted = NO;
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

// 跨版本安全获取 VolumeControl
- (SBVolumeControl *)safeVolumeControl {
    SpringBoard *sb = (SpringBoard *)[UIApplication sharedApplication];
    if ([sb respondsToSelector:@selector(volumeControl)]) {
        return sb.volumeControl; // iOS 16-17 走这里，绝不崩溃
    }
    if ([%c(SBVolumeControl) respondsToSelector:@selector(sharedInstance)]) {
        return [%c(SBVolumeControl) sharedInstance]; // iOS 14-15 走这里
    }
    return nil;
}

// 通用设音量+隐藏弹窗逻辑
- (void)setSystemVolume:(float)targetVolume {
    g_isMutingHUD = YES;
    
    // 1. 开启 HUD 隐藏
    SBMediaController *mediaCtrl = nil;
    if ([%c(SBMediaController) respondsToSelector:@selector(sharedInstance)]) {
        mediaCtrl = [%c(SBMediaController) sharedInstance];
    } else if ([%c(SBMediaController) respondsToSelector:@selector(sharedInstanceIfExists)]) {
        mediaCtrl = [%c(SBMediaController) sharedInstanceIfExists];
    }
    if ([mediaCtrl respondsToSelector:@selector(setSuppressHUD:)]) {
        [mediaCtrl setSuppressHUD:YES];
    }
    
    // 2. 调节音量
    SBVolumeControl *volCtrl = [self safeVolumeControl];
    if ([volCtrl respondsToSelector:@selector(setVolume:forCategory:)]) {
        [volCtrl setVolume:targetVolume forCategory:@"Audio/Video"];
    } else if ([volCtrl respondsToSelector:@selector(setActiveCategoryVolume:)]) {
        [volCtrl setActiveCategoryVolume:targetVolume];
    }
    
    // 3. 延时 0.5s 后恢复 HUD 弹窗能力，防止影响用户手动按物理键
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        g_isMutingHUD = NO;
        if ([mediaCtrl respondsToSelector:@selector(setSuppressHUD:)]) {
            [mediaCtrl setSuppressHUD:NO];
        }
    });
}

// 核心前后台切换检查逻辑
- (void)checkAppTransition {
    SpringBoard *sb = (SpringBoard *)[UIApplication sharedApplication];
    SBApplication *app = [sb respondsToSelector:@selector(_accessibilityFrontMostApplication)] ? [sb _accessibilityFrontMostApplication] : nil;
    NSString *currentBundleID = app ? [app bundleIdentifier] : nil; // 退到桌面时 currentBundleID 为 nil
    
    // 只要前台 App 发生了变化，就进行对比处理
    if (currentBundleID != self.lastFrontmostBundleID && ![currentBundleID isEqualToString:self.lastFrontmostBundleID]) {
        
        // 1. 判断是否【离开】了静音名单的 App
        if (self.isCurrentlyMuted) {
            // 恢复进入前的音量
            if (self.savedVolume >= 0.0) {
                [self setSystemVolume:self.savedVolume];
            }
            self.isCurrentlyMuted = NO;
            self.savedVolume = -1.0;
        }
        
        // 2. 判断是否【进入】了静音名单的 App
        if (currentBundleID && [self isMuted:currentBundleID]) {
            SBVolumeControl *volCtrl = [self safeVolumeControl];
            if ([volCtrl respondsToSelector:@selector(_effectiveVolume)]) {
                self.savedVolume = [volCtrl _effectiveVolume]; // 保存进入前的真实音量
            } else {
                self.savedVolume = 0.5; // 极小概率兜底
            }
            
            self.isCurrentlyMuted = YES;
            [self setSystemVolume:0.0]; // 强行拉到底
        }
        
        // 更新记录
        self.lastFrontmostBundleID = currentBundleID;
    }
}
@end


// ================== 核心 Hook 区 ==================

%hook SBIconView

// 注入长按菜单按钮
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
    
    SBSApplicationShortcutSystemIcon *sysIcon = [[%c(SBSApplicationShortcutSystemIcon) alloc] initWithSystemImageName: isMuted ? @"speaker.slash.fill" : @"speaker.wave.2.fill"];
    item.icon = sysIcon;
    
    NSMutableArray *mutOrig = orig ? [orig mutableCopy] : [NSMutableArray array];
    [mutOrig addObject:item];
    return mutOrig;
}

// 【修复编译错误】：把参数声明为 id，但在内部强转为 SBSApplicationShortcutItem
+ (void)activateShortcut:(id)shortcut withBundleIdentifier:(id)identifier forIconView:(id)view {
    // 强制转换类型，明确告诉编译器它有一个返回 NSString* 的 type 属性
    SBSApplicationShortcutItem *item = (SBSApplicationShortcutItem *)shortcut;
    
    if ([item respondsToSelector:@selector(type)] && [item.type isEqualToString:@"com.iosdump.appmute.toggle"]) {
        // 1. 切换保存状态
        [[AppMuteManager sharedManager] toggleMute:identifier];
        // 2. 给用户一个轻微的震动反馈，表示点击成功
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
        
        // 3. 直接 return，物理斩断唤起 App 的系统流程
        return; 
    }
    %orig;
}
%end


%hook SpringBoard
// 兼容全系统：无论是返回桌面、拉下控制中心，只要前台状态改变立刻触发校验
- (void)_handleApplicationProcessStateDidChangeNotification:(NSNotification *)notification {
    %orig;
    [[AppMuteManager sharedManager] checkAppTransition];
}

// 双保险：针对 iOS 14-15 提供更敏锐的前台切换监听
- (void)frontDisplayDidChange:(id)arg1 {
    %orig;
    [[AppMuteManager sharedManager] checkAppTransition];
}
%end

// 双保险：如果 SBMediaController.suppressHUD 失效，手动拦截底层 UI 弹窗
%hook SBVolumeControl
- (void)_presentVolumeHUDWithVolume:(float)volume {
    if (g_isMutingHUD) return;
    %orig;
}
- (void)_presentVolumeHUDIfDisplayable:(BOOL)displayable orRefreshIfPresentedWithReason:(id)reason {
    if (g_isMutingHUD) return;
    %orig;
}
%end

// ================== 初始化构造 ==================
%ctor {
    @autoreleasepool {
        [AppMuteManager sharedManager];
    }
}
