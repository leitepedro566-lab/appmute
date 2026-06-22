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
- (void)_didSuspend; // 全版本自带的退出挂起瞬时方法
@end

@interface SBVolumeControl : NSObject
+ (instancetype)sharedInstance; // 仅 iOS 14-15
- (void)setVolume:(float)volume forCategory:(NSString *)category;
- (void)setActiveCategoryVolume:(float)volume;
- (float)_effectiveVolume; // 获取当前真实音量
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
- (void)forceRestoreVolume;
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
        return sb.volumeControl; // iOS 16-17
    }
    if ([%c(SBVolumeControl) respondsToSelector:@selector(sharedInstance)]) {
        return [%c(SBVolumeControl) sharedInstance]; // iOS 14-15
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
    
    // 3. 延时 0.5s 后恢复 HUD 弹窗能力
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        g_isMutingHUD = NO;
        if ([mediaCtrl respondsToSelector:@selector(setSuppressHUD:)]) {
            [mediaCtrl setSuppressHUD:NO];
        }
    });
}

// 核心原汁原味恢复逻辑（去除了任何兜底值和修改值）
- (void)forceRestoreVolume {
    if (self.isCurrentlyMuted) {
        if (self.savedVolume >= 0.0) {
            [self setSystemVolume:self.savedVolume]; // 100% 精准原值恢复
        }
        self.isCurrentlyMuted = NO;
        self.savedVolume = -1.0;
        self.lastFrontmostBundleID = nil; // 及时重置状态旗帜
    }
}

// 核心前后台切换检查逻辑
- (void)checkAppTransition {
    SpringBoard *sb = (SpringBoard *)[UIApplication sharedApplication];
    SBApplication *app = [sb respondsToSelector:@selector(_accessibilityFrontMostApplication)] ? [sb _accessibilityFrontMostApplication] : nil;
    NSString *currentBundleID = app ? [app bundleIdentifier] : nil;
    
    if (currentBundleID != self.lastFrontmostBundleID && ![currentBundleID isEqualToString:self.lastFrontmostBundleID]) {
        
        // 1. 判断是否【离开】了静音名单的 App（针对现代系统或应用间直接切换）
        if (self.isCurrentlyMuted) {
            [self forceRestoreVolume];
        }
        
        // 2. 判断是否【进入】了静音名单的 App
        if (currentBundleID && [self isMuted:currentBundleID]) {
            SBVolumeControl *volCtrl = [self safeVolumeControl];
            if ([volCtrl respondsToSelector:@selector(_effectiveVolume)]) {
                self.savedVolume = [volCtrl _effectiveVolume]; // 精确保存最原本的音量
            }
            
            self.isCurrentlyMuted = YES;
            [self setSystemVolume:0.0]; // 强行静音
        }
        
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

+ (void)activateShortcut:(id)shortcut withBundleIdentifier:(id)identifier forIconView:(id)view {
    SBSApplicationShortcutItem *item = (SBSApplicationShortcutItem *)shortcut;
    
    if ([item respondsToSelector:@selector(type)] && [item.type isEqualToString:@"com.iosdump.appmute.toggle"]) {
        [[AppMuteManager sharedManager] toggleMute:identifier];
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
        return; 
    }
    %orig;
}
%end


%hook SpringBoard
// 保持原有即时生效逻辑，不引入任何延时
- (void)_handleApplicationProcessStateDidChangeNotification:(NSNotification *)notification {
    %orig;
    [[AppMuteManager sharedManager] checkAppTransition];
}

- (void)frontDisplayDidChange:(id)arg1 {
    %orig;
    [[AppMuteManager sharedManager] checkAppTransition];
}
%end


// 【新增核心 Hook 点】：完美狙击 iOS 14 退出挂起不恢复的系统级缺陷
%hook SBApplication
- (void)_didSuspend {
    %orig;
    // 如果当前处于静音压制状态，并且正是被静音的 App 触发了退出挂起，立刻无延迟恢复
    if ([[AppMuteManager sharedManager] isCurrentlyMuted]) {
        NSString *bundleID = [self bundleIdentifier];
        if (bundleID && [[AppMuteManager sharedManager] isMuted:bundleID]) {
            [[AppMuteManager sharedManager] forceRestoreVolume]; // 瞬时恢复原值
        }
    }
}
%end


// 底层 UI 弹窗拦截
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
