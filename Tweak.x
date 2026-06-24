#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// ================== 系统与私有头文件声明 ==================
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
@property (nonatomic, copy) NSString *bundleIdentifierToLaunch; 
@property (nonatomic, assign) NSUInteger activationMode;        
@end

// 负责安全的媒体音量控制
@interface SBVolumeControl : NSObject
+ (instancetype)sharedInstance; // iOS 14-15
- (void)setVolume:(float)volume forCategory:(NSString *)category; // iOS 14-17
- (float)_effectiveVolume;
@end

@interface SBMediaController : NSObject
+ (instancetype)sharedInstance;
+ (instancetype)sharedInstanceIfExists; 
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
@property (nonatomic, assign) float savedMediaVolume;
@property (nonatomic, assign) BOOL isCurrentlyMuted;
+ (instancetype)sharedManager;
- (NSArray *)addShortcutToItems:(NSArray *)orig forIcon:(SBIcon *)icon;
- (void)processAppForeground:(NSString *)bundleID;
- (void)processAppBackground:(NSString *)bundleID;
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
        self.savedMediaVolume = -1.0;
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

// 核心安全获取 VolumeControl (完美兼容 iOS 14-17)
- (SBVolumeControl *)safeVolumeControl {
    if ([%c(SBVolumeControl) respondsToSelector:@selector(sharedInstance)]) {
        return [%c(SBVolumeControl) sharedInstance]; // iOS 14-15
    }
    // iOS 16-17: 剥离了单例，但根据头文件发现它被 SBMediaController 持有
    SBMediaController *mediaCtrl = nil;
    if ([%c(SBMediaController) respondsToSelector:@selector(sharedInstanceIfExists)]) {
        mediaCtrl = [%c(SBMediaController) sharedInstanceIfExists];
    } else if ([%c(SBMediaController) respondsToSelector:@selector(sharedInstance)]) {
        mediaCtrl = [%c(SBMediaController) sharedInstance];
    }
    
    if (mediaCtrl) {
        @try {
            id volCtrl = [mediaCtrl valueForKey:@"_volumeControl"];
            if (volCtrl) return volCtrl;
        } @catch (NSException *e) {}
    }
    return nil;
}

// 精准控制媒体音量，剔除对铃声的影响，拒绝主线程死锁
- (void)setMediaVolume:(float)targetVolume saveCurrent:(BOOL)save {
    g_isMutingHUD = YES;
    
    SBMediaController *mediaCtrl = nil;
    if ([%c(SBMediaController) respondsToSelector:@selector(sharedInstanceIfExists)]) {
        mediaCtrl = [%c(SBMediaController) sharedInstanceIfExists];
    } else if ([%c(SBMediaController) respondsToSelector:@selector(sharedInstance)]) {
        mediaCtrl = [%c(SBMediaController) sharedInstance];
    }
    
    if ([mediaCtrl respondsToSelector:@selector(setSuppressHUD:)]) {
        [mediaCtrl setSuppressHUD:YES];
    }
    
    SBVolumeControl *volCtrl = [self safeVolumeControl];
    if (volCtrl && [volCtrl respondsToSelector:@selector(setVolume:forCategory:)]) {
        
        // 如果是静音操作，先备份当前媒体音量
        if (save && [volCtrl respondsToSelector:@selector(_effectiveVolume)]) {
            float currentVol = [volCtrl _effectiveVolume];
            if (currentVol > 0.01) {
                self.savedMediaVolume = currentVol;
            } else if (self.savedMediaVolume < 0) {
                self.savedMediaVolume = 0.5; // 极小概率兜底
            }
        }
        
        // 仅干涉媒体分类，绝不影响电话和闹钟
        [volCtrl setVolume:targetVolume forCategory:@"Media"];
        [volCtrl setVolume:targetVolume forCategory:@"Audio/Video"];
    }
    
    // 延时恢复 HUD 拦截
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        g_isMutingHUD = NO;
        if ([mediaCtrl respondsToSelector:@selector(setSuppressHUD:)]) {
            [mediaCtrl setSuppressHUD:NO];
        }
    });
}

// 核心：处理 App 进入前台
- (void)processAppForeground:(NSString *)bundleID {
    if (!bundleID || bundleID.length == 0) return;
    self.lastFrontmostBundleID = bundleID;
    
    if ([self isMuted:bundleID]) {
        if (!self.isCurrentlyMuted) {
            self.isCurrentlyMuted = YES;
            // 切换到静音并保存
            [self setMediaVolume:0.0 saveCurrent:YES];
        }
    } else {
        // 从名单内的App滑到名单外的App，立即恢复声音
        if (self.isCurrentlyMuted) {
            self.isCurrentlyMuted = NO;
            float restoreVol = (self.savedMediaVolume >= 0.0) ? self.savedMediaVolume : 0.5;
            [self setMediaVolume:restoreVol saveCurrent:NO];
        }
    }
}

// 核心：处理 App 退居后台 / 被销毁
- (void)processAppBackground:(NSString *)bundleID {
    if (!bundleID || bundleID.length == 0) return;
    
    if ([self.lastFrontmostBundleID isEqualToString:bundleID] && self.isCurrentlyMuted) {
        self.isCurrentlyMuted = NO;
        self.lastFrontmostBundleID = @""; // 重置桌面状态
        float restoreVol = (self.savedMediaVolume >= 0.0) ? self.savedMediaVolume : 0.5;
        [self setMediaVolume:restoreVol saveCurrent:NO];
    }
}

// 注入快捷菜单
- (NSArray *)addShortcutToItems:(NSArray *)orig forIcon:(SBIcon *)icon {
    if (!icon || ![icon respondsToSelector:@selector(isApplicationIcon)] || ![icon isApplicationIcon]) return orig;
    NSString *bundleID = [icon applicationBundleID];
    if (!bundleID) return orig;
    
    for (id item in orig) {
        if ([item respondsToSelector:@selector(type)]) {
            NSString *itemType = [(SBSApplicationShortcutItem *)item type];
            if ([itemType isKindOfClass:[NSString class]] && [itemType isEqualToString:@"com.iosdump.appmute.toggle"]) return orig;
        }
    }
    
    BOOL isMuted = [self isMuted:bundleID];
    SBSApplicationShortcutItem *item = [[%c(SBSApplicationShortcutItem) alloc] init];
    item.type = @"com.iosdump.appmute.toggle";
    item.localizedTitle = isMuted ? @"关闭启动静音" : @"开启启动静音";
    
    if ([item respondsToSelector:@selector(setBundleIdentifierToLaunch:)]) {
        item.bundleIdentifierToLaunch = bundleID;
    }
    if ([item respondsToSelector:@selector(setActivationMode:)]) {
        item.activationMode = 1;
    }
    
    SBSApplicationShortcutSystemIcon *sysIcon = [[%c(SBSApplicationShortcutSystemIcon) alloc] initWithSystemImageName: isMuted ? @"speaker.slash.fill" : @"speaker.wave.2.fill"];
    item.icon = sysIcon;
    
    NSMutableArray *mutOrig = orig ? [orig mutableCopy] : [NSMutableArray array];
    [mutOrig addObject:item];
    return mutOrig;
}
@end


// ================== 核心 Hook 区 ==================

%hook SBIconView

- (NSArray *)applicationShortcutItems {
    return [[AppMuteManager sharedManager] addShortcutToItems:%orig forIcon:self.icon];
}
- (NSArray *)effectiveApplicationShortcutItems {
    return [[AppMuteManager sharedManager] addShortcutToItems:%orig forIcon:self.icon];
}

- (BOOL)shouldActivateApplicationShortcutItem:(id)item atIndex:(NSUInteger)index {
    if ([item respondsToSelector:@selector(type)]) {
        NSString *itemType = [(SBSApplicationShortcutItem *)item type];
        if ([itemType isKindOfClass:[NSString class]] && [itemType isEqualToString:@"com.iosdump.appmute.toggle"]) {
            SBIcon *icon = self.icon;
            if ([icon respondsToSelector:@selector(applicationBundleID)]) {
                NSString *bundleID = [icon applicationBundleID];
                if (bundleID) {
                    [[AppMuteManager sharedManager] toggleMute:bundleID];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                        [feedback impactOccurred];
                    });
                }
            }
            return NO;
        }
    }
    return %orig;
}
%end


// ───────────────────────────────────────────
//  [超强引擎] 防崩溃安全拦截 (解决系统App无效问题)
// ───────────────────────────────────────────
%hook SBMainDisplaySceneManager

- (void)_noteDidChangeToVisibility:(unsigned long long)visibility previouslyExisted:(_Bool)existed forScene:(id)scene {
    %orig;
    // 异步执行，不阻碍 SpringBoard 核心渲染进程，彻底杜绝死锁引发的安全模式
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            NSString *bundleID = nil;
            // 严谨校验类型，防止强解引发 Crash
            if ([scene respondsToSelector:@selector(clientProcess)]) {
                id process = [scene performSelector:@selector(clientProcess)];
                if (process && [process respondsToSelector:@selector(bundleIdentifier)]) {
                    bundleID = [process performSelector:@selector(bundleIdentifier)];
                }
            }
            
            if (bundleID && [bundleID isKindOfClass:[NSString class]] && bundleID.length > 0) {
                // FBSSceneVisibility: 2=前台可见, 0=销毁/未追踪, 1=后台
                if (visibility == 2) {
                    [[AppMuteManager sharedManager] processAppForeground:bundleID];
                } else if (visibility == 0 || visibility == 1) {
                    [[AppMuteManager sharedManager] processAppBackground:bundleID];
                }
            }
        } @catch (NSException *e) {}
    });
}
%end


// ───────────────────────────────────────────
//  阻止 HUD 弹出的双保险 (仅针对媒体进度条)
// ───────────────────────────────────────────
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
