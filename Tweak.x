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
- (float)_effectiveVolume; // 全版本通用获取当前音量
@end

@interface SpringBoard : UIApplication
- (SBApplication *)_accessibilityFrontMostApplication;
- (BOOL)isShowingHomescreen; // 判断是否在桌面
@property (readonly, nonatomic) SBVolumeControl *volumeControl; // iOS 16-17 专属
@end

@interface SBMediaController : NSObject
+ (instancetype)sharedInstance;
+ (instancetype)sharedInstanceIfExists; // iOS 17
@property (nonatomic, assign) BOOL suppressHUD; // 隐藏系统音量进度条
@end

// ================== 全局数据与状态管理 ==================
static BOOL g_isMutingHUD = NO; // 控制音量弹窗拦截的开关

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
@property (nonatomic, assign) BOOL isCurrentlyMuted;         // 标记当前是否处于强制静音状态
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

// 跨版本安全获取 VolumeControl，防崩溃核心
- (SBVolumeControl *)safeVolumeControl {
    SpringBoard *sb = (SpringBoard *)[UIApplication sharedApplication];
    if ([sb respondsToSelector:@selector(volumeControl)]) {
        return sb.volumeControl; 
    }
    if ([%c(SBVolumeControl) respondsToSelector:@selector(sharedInstance)]) {
        return [%c(SBVolumeControl) sharedInstance]; 
    }
    return nil;
}

// 通用设音量 + 隐藏弹窗逻辑
- (void)setSystemVolume:(float)targetVolume {
    g_isMutingHUD = YES; // 开启拦截
    
    SBMediaController *mediaCtrl = nil;
    if ([%c(SBMediaController) respondsToSelector:@selector(sharedInstance)]) {
        mediaCtrl = [%c(SBMediaController) sharedInstance];
    } else if ([%c(SBMediaController) respondsToSelector:@selector(sharedInstanceIfExists)]) {
        mediaCtrl = [%c(SBMediaController) sharedInstanceIfExists];
    }
    
    // 隐藏系统 UI 弹窗
    if ([mediaCtrl respondsToSelector:@selector(setSuppressHUD:)]) {
        [mediaCtrl setSuppressHUD:YES];
    }
    
    // 调节底层音量
    SBVolumeControl *volCtrl = [self safeVolumeControl];
    if ([volCtrl respondsToSelector:@selector(setVolume:forCategory:)]) {
        [volCtrl setVolume:targetVolume forCategory:@"Audio/Video"];
    } else if ([volCtrl respondsToSelector:@selector(setActiveCategoryVolume:)]) {
        [volCtrl setActiveCategoryVolume:targetVolume];
    }
    
    // 延时 0.5s 恢复物理按键弹窗能力（避免误伤后续的正常操作）
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
    NSString *currentBundleID = nil;
    
    // 优先判断是否回到桌面
    if ([sb respondsToSelector:@selector(isShowingHomescreen)] && [sb isShowingHomescreen]) {
        currentBundleID = nil;
    } else {
        // 如果不在桌面，获取最前台 App
        SBApplication *app = [sb respondsToSelector:@selector(_accessibilityFrontMostApplication)] ? [sb _accessibilityFrontMostApplication] : nil;
        if (app && [app respondsToSelector:@selector(bundleIdentifier)]) {
            currentBundleID = [app bundleIdentifier];
        }
    }
    
    // 仅当前台应用发生实质性切换时才执行
    if (currentBundleID != self.lastFrontmostBundleID && ![currentBundleID isEqualToString:self.lastFrontmostBundleID]) {
        
        // 1. 【退出恢复阶段】离开拦截名单的 App 时恢复
        if (self.isCurrentlyMuted && (!currentBundleID || ![self isMuted:currentBundleID])) {
            if (self.savedVolume >= 0.0) {
                [self setSystemVolume:self.savedVolume]; // 严格还原进入前的真实音量
            }
            self.isCurrentlyMuted = NO;
            self.savedVolume = -1.0;
        }
        
        // 2. 【进入静音阶段】进入拦截名单的 App 时触发
        if (currentBundleID && [self isMuted:currentBundleID]) {
            // 防止重复执行导致原音量被 0 覆盖
            if (!self.isCurrentlyMuted) {
                SBVolumeControl *volCtrl = [self safeVolumeControl];
                // 忠实记录当前的系统真实音量
                if ([volCtrl respondsToSelector:@selector(_effectiveVolume)]) {
                    self.savedVolume = [volCtrl _effectiveVolume]; 
                } else {
                    self.savedVolume = 0.5; // 仅做防异常获取不到数据时的安全值
                }
                self.isCurrentlyMuted = YES;
            }
            
            // 绝对静音
            [self setSystemVolume:0.0];
        }
        
        self.lastFrontmostBundleID = currentBundleID;
    }
}
@end


// ================== 状态检测触发器 ==================
static void triggerAppTransitionCheck() {
    // 0.15 秒延迟：避开系统动画带来的前台 App 状态滞后问题
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [[AppMuteManager sharedManager] checkAppTransition];
    });
}


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

// 拦截点击事件并阻断进入 App，解决编译错误
+ (void)activateShortcut:(id)shortcut withBundleIdentifier:(id)identifier forIconView:(id)view {
    SBSApplicationShortcutItem *item = (SBSApplicationShortcutItem *)shortcut;
    if ([item respondsToSelector:@selector(type)] && [item.type isEqualToString:@"com.iosdump.appmute.toggle"]) {
        // 切换状态并微震
        [[AppMuteManager sharedManager] toggleMute:identifier];
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
        // 直接 return，物理斩断唤起 App 的流程
        return; 
    }
    %orig;
}
%end


%hook SpringBoard
// 通知 1：普通应用状态发生改变 (iOS 16-17 主力)
- (void)_handleApplicationProcessStateDidChangeNotification:(NSNotification *)notification {
    %orig;
    triggerAppTransitionCheck();
}

// 通知 2：专门针对显示变更 (iOS 14-15 主力)
- (void)frontDisplayDidChange:(id)arg1 {
    %orig;
    triggerAppTransitionCheck();
}

// 通知 3：桌面状态变更 (最可靠的回桌面监听)
- (void)_updateHomeScreenPresenceNotification:(id)notification {
    %orig;
    triggerAppTransitionCheck();
}
%end


// 通知 4：App 生命周期底层监听 (防止控制中心等特殊退出)
%hook SBApplication
- (void)_noteProcess:(id)process didChangeToState:(id)state {
    %orig;
    triggerAppTransitionCheck();
}
%end


// 拦截底层系统音量 UI 弹窗
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

// ================== 初始化 ==================
%ctor {
    @autoreleasepool {
        [AppMuteManager sharedManager];
    }
}
