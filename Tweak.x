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
@property (nonatomic, copy) NSString *bundleIdentifierToLaunch; // 修复 iOS 15 必须绑定目标的特性
@property (nonatomic, assign) NSUInteger activationMode;        // 修复 iOS 15 必须设定后台激活模式
@end

@interface SBApplication : NSObject
- (NSString *)bundleIdentifier;
@end

@interface SBVolumeControl : NSObject
+ (instancetype)sharedInstance; // iOS 14-15
- (void)setVolume:(float)volume forCategory:(NSString *)category;
- (void)setActiveCategoryVolume:(float)volume;
- (float)_effectiveVolume; 
@end

@interface SpringBoard : UIApplication
- (SBApplication *)_accessibilityFrontMostApplication;
@property (readonly, nonatomic) SBVolumeControl *volumeControl; // iOS 16-17
@end

@interface SBMediaController : NSObject
+ (instancetype)sharedInstance;
+ (instancetype)sharedInstanceIfExists; // iOS 17
@property (nonatomic, assign) BOOL suppressHUD;
@end


// ================== 全局数据与状态管理 ==================
static BOOL g_isMutingHUD = NO;

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
@property (nonatomic, copy) NSString *lastFrontmostBundleID;
@property (nonatomic, assign) float savedVolume;
@property (nonatomic, assign) BOOL isCurrentlyMuted;
+ (instancetype)sharedManager;
- (NSArray *)addShortcutToItems:(NSArray *)orig forIcon:(SBIcon *)icon;
- (void)handleDisplayChange:(id)change;
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
        self.lastFrontmostBundleID = @"";
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

- (void)setSystemVolume:(float)targetVolume {
    g_isMutingHUD = YES;
    
    // 隐藏 HUD
    SBMediaController *mediaCtrl = nil;
    if ([%c(SBMediaController) respondsToSelector:@selector(sharedInstanceIfExists)]) {
        mediaCtrl = [%c(SBMediaController) sharedInstanceIfExists];
    } else if ([%c(SBMediaController) respondsToSelector:@selector(sharedInstance)]) {
        mediaCtrl = [%c(SBMediaController) sharedInstance];
    }
    if ([mediaCtrl respondsToSelector:@selector(setSuppressHUD:)]) {
        [mediaCtrl setSuppressHUD:YES];
    }
    
    // 安全设置音量 (双通道保障 iOS 14-17)
    SBVolumeControl *volCtrl = [self safeVolumeControl];
    if ([volCtrl respondsToSelector:@selector(setVolume:forCategory:)]) {
        [volCtrl setVolume:targetVolume forCategory:@"Audio/Video"];
        [volCtrl setVolume:targetVolume forCategory:@"Media"];
    } else if ([volCtrl respondsToSelector:@selector(setActiveCategoryVolume:)]) {
        [volCtrl setActiveCategoryVolume:targetVolume];
    }
    
    // 延时恢复 HUD
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        g_isMutingHUD = NO;
        if ([mediaCtrl respondsToSelector:@selector(setSuppressHUD:)]) {
            [mediaCtrl setSuppressHUD:NO];
        }
    });
}

// 解决自定义菜单复写和注入问题
- (NSArray *)addShortcutToItems:(NSArray *)orig forIcon:(SBIcon *)icon {
    if (!icon || ![icon respondsToSelector:@selector(isApplicationIcon)] || ![icon isApplicationIcon]) return orig;
    NSString *bundleID = [icon applicationBundleID];
    if (!bundleID) return orig;
    
    // 防重复注入
    for (id item in orig) {
        if ([item respondsToSelector:@selector(type)] && [[item type] isEqualToString:@"com.iosdump.appmute.toggle"]) {
            return orig;
        }
    }
    
    BOOL isMuted = [self isMuted:bundleID];
    SBSApplicationShortcutItem *item = [[%c(SBSApplicationShortcutItem) alloc] init];
    item.type = @"com.iosdump.appmute.toggle";
    item.localizedTitle = isMuted ? @"关闭启动静音" : @"开启启动静音";
    
    // iOS 15 关键补丁：必须赋予宿主 ID 和激活模式，否则系统可能抛弃它
    if ([item respondsToSelector:@selector(setBundleIdentifierToLaunch:)]) {
        item.bundleIdentifierToLaunch = bundleID;
    }
    if ([item respondsToSelector:@selector(setActivationMode:)]) {
        item.activationMode = 1; // SBSApplicationShortcutActivationModeBackground
    }
    
    SBSApplicationShortcutSystemIcon *sysIcon = [[%c(SBSApplicationShortcutSystemIcon) alloc] initWithSystemImageName: isMuted ? @"speaker.slash.fill" : @"speaker.wave.2.fill"];
    item.icon = sysIcon;
    
    NSMutableArray *mutOrig = orig ? [orig mutableCopy] : [NSMutableArray array];
    [mutOrig addObject:item];
    return mutOrig;
}

// iOS 14 状态竞争的终极解决方案：即时推测 + 延时双重确认
- (void)handleDisplayChange:(id)change {
    NSString *newBundleID = nil;
    
    // 1. 尝试直接从系统转场事件(change)中硬解出目标 ID，速度最快
    if (change) {
        if ([change respondsToSelector:@selector(applicationBundleID)]) {
            newBundleID = [change applicationBundleID];
        } else if ([change respondsToSelector:@selector(bundleIdentifier)]) {
            newBundleID = [change bundleIdentifier];
        } else if ([change respondsToSelector:@selector(application)]) {
            id app = [change application];
            if ([app respondsToSelector:@selector(bundleIdentifier)]) {
                newBundleID = [app bundleIdentifier];
            }
        }
    }
    
    // 2. 如果硬解失败，尝试传统方法
    if (!newBundleID) {
        SpringBoard *sb = (SpringBoard *)[UIApplication sharedApplication];
        if ([sb respondsToSelector:@selector(_accessibilityFrontMostApplication)]) {
            SBApplication *app = [sb _accessibilityFrontMostApplication];
            newBundleID = app ? [app bundleIdentifier] : nil;
        }
    }
    
    // 3. 立即执行一次
    [self processTransitionToBundleID:newBundleID];
    
    // 4. 发起 0.6 秒的延时校验，专门对付 iOS 14 退回桌面时“获取前台仍是上一个 App”的假象
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SpringBoard *sb = (SpringBoard *)[UIApplication sharedApplication];
        NSString *delayedBundleID = nil;
        if ([sb respondsToSelector:@selector(_accessibilityFrontMostApplication)]) {
            SBApplication *app = [sb _accessibilityFrontMostApplication];
            delayedBundleID = app ? [app bundleIdentifier] : nil;
        }
        [self processTransitionToBundleID:delayedBundleID];
    });
}

// 核心前后台切换处理，加了严格的重复过滤
- (void)processTransitionToBundleID:(NSString *)currentBundleID {
    if (!currentBundleID) currentBundleID = @""; // 用空字符串代表桌面，防止 nil 对比出错
    if (!self.lastFrontmostBundleID) self.lastFrontmostBundleID = @"";
    
    if (![currentBundleID isEqualToString:self.lastFrontmostBundleID]) {
        
        // 1. 【离开】了静音名单
        if (self.isCurrentlyMuted) {
            if (self.savedVolume >= 0.0) {
                [self setSystemVolume:self.savedVolume];
            }
            self.isCurrentlyMuted = NO;
            self.savedVolume = -1.0;
        }
        
        // 2. 【进入】了静音名单
        if (currentBundleID.length > 0 && [self isMuted:currentBundleID]) {
            if (!self.isCurrentlyMuted) {
                SBVolumeControl *volCtrl = [self safeVolumeControl];
                float currentVol = [volCtrl respondsToSelector:@selector(_effectiveVolume)] ? [volCtrl _effectiveVolume] : 0.5;
                // 仅当当前音量不是0时才保存，防止上一次的静音结果被误存
                if (currentVol > 0.01) {
                    self.savedVolume = currentVol;
                } else if (self.savedVolume < 0) {
                    self.savedVolume = 0.5; // 极小概率兜底
                }
                
                self.isCurrentlyMuted = YES;
                [self setSystemVolume:0.0];
            }
        }
        
        self.lastFrontmostBundleID = currentBundleID;
    }
}
@end


// ================== 核心 Hook 区 ==================

%hook SBIconView

// Hook 原有菜单列表
- (NSArray *)applicationShortcutItems {
    return [[AppMuteManager sharedManager] addShortcutToItems:%orig forIcon:self.icon];
}

// 修复 iOS 15：SBIconView 会去调用 effectiveApplicationShortcutItems
- (NSArray *)effectiveApplicationShortcutItems {
    return [[AppMuteManager sharedManager] addShortcutToItems:%orig forIcon:self.icon];
}

// 修复 iOS 15 核心拦截点：抛弃之前的 activateShortcut...，直接拦截触发实例方法
- (BOOL)shouldActivateApplicationShortcutItem:(id)item atIndex:(NSUInteger)index {
    if ([item respondsToSelector:@selector(type)] && [[item type] isEqualToString:@"com.iosdump.appmute.toggle"]) {
        SBIcon *icon = self.icon;
        if ([icon respondsToSelector:@selector(applicationBundleID)]) {
            NSString *bundleID = [icon applicationBundleID];
            if (bundleID) {
                // 1. 切换并保存状态
                [[AppMuteManager sharedManager] toggleMute:bundleID];
                // 2. 给予震动反馈
                UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                [feedback impactOccurred];
            }
        }
        // 返回 NO 明确阻断系统将其交给 App 处理
        return NO;
    }
    return %orig;
}
%end


%hook SpringBoard

// iOS 14-17 前后台切换的绝对权威通知
- (void)frontDisplayDidChange:(id)change {
    %orig;
    [[AppMuteManager sharedManager] handleDisplayChange:change];
}

// 兼容老版本的普通进程改变通知
- (void)_handleApplicationProcessStateDidChangeNotification:(NSNotification *)notification {
    %orig;
    [[AppMuteManager sharedManager] handleDisplayChange:nil];
}
%end

// 双保险：针对某些设备手动拦截底层 UI 弹窗
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
