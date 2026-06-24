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

// 真正的底层全通道音频控制器 (必须放进后台线程调用，否则引发安全模式)
@interface AVSystemController : NSObject
+ (id)sharedAVSystemController;
- (_Bool)getVolume:(float *)volume forCategory:(id)category;
- (_Bool)setVolumeTo:(float)to forCategory:(id)category;
@end

@interface SBMediaController : NSObject
+ (instancetype)sharedInstance;
+ (instancetype)sharedInstanceIfExists; 
@property (nonatomic, assign) BOOL suppressHUD;
@end

@interface SpringBoard : UIApplication
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
@property (nonatomic, strong) NSMutableDictionary *savedVolumes; 
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
        self.savedVolumes = [NSMutableDictionary dictionary];
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

- (void)suppressMediaHUD:(BOOL)suppress {
    id mediaCtrl = nil;
    if ([%c(SBMediaController) respondsToSelector:@selector(sharedInstanceIfExists)]) {
        mediaCtrl = [%c(SBMediaController) sharedInstanceIfExists];
    } else if ([%c(SBMediaController) respondsToSelector:@selector(sharedInstance)]) {
        mediaCtrl = [%c(SBMediaController) sharedInstance];
    }
    if ([mediaCtrl respondsToSelector:@selector(setSuppressHUD:)]) {
        [mediaCtrl setSuppressHUD:suppress];
    }
}

// 核心安全静音 (完全避免主线程死锁，且仅限媒体音量)
- (void)performVolumeChangeToMute {
    g_isMutingHUD = YES;
    [self suppressMediaHUD:YES];
    
    // 必须放在 Global Queue 执行，防止与 SpringBoard 动画抢占主线程导致看门狗崩溃 (Safe Mode)
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        AVSystemController *avCtrl = [%c(AVSystemController) sharedAVSystemController];
        if (avCtrl) {
            // 【关键修改】仅对媒体通道静音，绝对不影响铃声 (Ringtone) 和闹钟系统音
            NSArray *categories = @[@"Audio/Video", @"Media"];
            
            for (NSString *cat in categories) {
                float vol = 0.0;
                if ([avCtrl respondsToSelector:@selector(getVolume:forCategory:)]) {
                    [avCtrl getVolume:&vol forCategory:cat];
                    if (vol > 0.01) {
                        // 必须切回主线程操作 Dictionary，防止多线程崩溃
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (!self.savedVolumes) self.savedVolumes = [NSMutableDictionary dictionary];
                            self.savedVolumes[cat] = @(vol);
                        });
                    }
                }
                // 暴力拦截媒体音量
                if ([avCtrl respondsToSelector:@selector(setVolumeTo:forCategory:)]) {
                    [avCtrl setVolumeTo:0.0 forCategory:cat];
                }
            }
        }
        
        // 延时解除 HUD 拦截
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            g_isMutingHUD = NO;
            [self suppressMediaHUD:NO];
        });
    });
}

// 核心安全恢复 (完全避免主线程死锁)
- (void)performVolumeRestore {
    g_isMutingHUD = YES;
    [self suppressMediaHUD:YES];
    
    // 提前在主线程读取数值，防止跨线程读取字典报错
    float avVol = self.savedVolumes[@"Audio/Video"] ? [self.savedVolumes[@"Audio/Video"] floatValue] : 0.5;
    float mediaVol = self.savedVolumes[@"Media"] ? [self.savedVolumes[@"Media"] floatValue] : 0.5;
    [self.savedVolumes removeAllObjects];
    
    // 必须放在 Global Queue 执行
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        AVSystemController *avCtrl = [%c(AVSystemController) sharedAVSystemController];
        if (avCtrl) {
            if ([avCtrl respondsToSelector:@selector(setVolumeTo:forCategory:)]) {
                [avCtrl setVolumeTo:avVol forCategory:@"Audio/Video"];
                [avCtrl setVolumeTo:mediaVol forCategory:@"Media"];
            }
        }
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            g_isMutingHUD = NO;
            [self suppressMediaHUD:NO];
        });
    });
}

// 核心：处理 App 进入前台
- (void)processAppForeground:(NSString *)bundleID {
    if (!bundleID || bundleID.length == 0) return;
    self.lastFrontmostBundleID = bundleID;
    
    if ([self isMuted:bundleID]) {
        if (!self.isCurrentlyMuted) {
            self.isCurrentlyMuted = YES;
            [self performVolumeChangeToMute];
        }
    } else {
        if (self.isCurrentlyMuted) {
            self.isCurrentlyMuted = NO;
            [self performVolumeRestore];
        }
    }
}

// 核心：处理 App 退居后台 / 被销毁
- (void)processAppBackground:(NSString *)bundleID {
    if (!bundleID || bundleID.length == 0) return;
    
    if ([self.lastFrontmostBundleID isEqualToString:bundleID] && self.isCurrentlyMuted) {
        self.isCurrentlyMuted = NO;
        self.lastFrontmostBundleID = @""; // 重置桌面状态
        [self performVolumeRestore];
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
//  [超强引擎] iOS 14-17 SpringBoard 稳定切换拦截
// ───────────────────────────────────────────
%hook SpringBoard

- (void)frontDisplayDidChange:(id)change {
    %orig;
    
    // 延迟 0.15 秒，确保切屏动画和内部状态机已彻底更新完毕，并且完全避开主线程阻塞
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            NSString *bundleID = nil;
            // 通过 SpringBoard 的绝对权威方法获取当前前台应用（含相机等系统应用）
            if ([self respondsToSelector:@selector(_accessibilityFrontMostApplication)]) {
                id app = [self performSelector:@selector(_accessibilityFrontMostApplication)];
                if (app && [app respondsToSelector:@selector(bundleIdentifier)]) {
                    bundleID = [app performSelector:@selector(bundleIdentifier)];
                }
            }
            
            if (bundleID && bundleID.length > 0) {
                // 成功捕获应用进入前台
                [[AppMuteManager sharedManager] processAppForeground:bundleID];
            } else {
                // bundleID 为 nil，证明用户退回了桌面
                [[AppMuteManager sharedManager] processAppBackground:[AppMuteManager sharedManager].lastFrontmostBundleID];
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
