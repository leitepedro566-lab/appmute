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

// iOS 14-17 全通道音频终极控制器
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
@property (nonatomic, strong) NSMutableDictionary *savedVolumes; // 音量记忆缓存
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

// 开启静音（仅限媒体通道）
- (void)performVolumeChangeToMute {
    g_isMutingHUD = YES;
    [self suppressMediaHUD:YES];
    
    AVSystemController *avCtrl = [%c(AVSystemController) sharedAVSystemController];
    if (avCtrl) {
        // 仅处理媒体音量，剔除铃声(Ringtone)和系统音(System/Alarm)
        NSArray *categories = @[@"Audio/Video", @"Media"];
        
        if (!self.savedVolumes) self.savedVolumes = [NSMutableDictionary dictionary];
        
        for (NSString *cat in categories) {
            float vol = 0.0;
            if ([avCtrl respondsToSelector:@selector(getVolume:forCategory:)]) {
                [avCtrl getVolume:&vol forCategory:cat];
                // 仅当当前音量大于0时才保存，防止上一次的静音结果被误存
                if (vol > 0.01) {
                    self.savedVolumes[cat] = @(vol);
                }
            }
            // 强制绝对静音
            if ([avCtrl respondsToSelector:@selector(setVolumeTo:forCategory:)]) {
                [avCtrl setVolumeTo:0.0 forCategory:cat];
            }
        }
    }
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        g_isMutingHUD = NO;
        [self suppressMediaHUD:NO];
    });
}

// 恢复音量（仅限媒体通道）
- (void)performVolumeRestore {
    g_isMutingHUD = YES;
    [self suppressMediaHUD:YES];
    
    AVSystemController *avCtrl = [%c(AVSystemController) sharedAVSystemController];
    if (avCtrl) {
        NSArray *categories = @[@"Audio/Video", @"Media"];
        for (NSString *cat in categories) {
            float vol = 0.5; // 兜底安全音量
            if (self.savedVolumes[cat]) {
                vol = [self.savedVolumes[cat] floatValue];
            }
            if ([avCtrl respondsToSelector:@selector(setVolumeTo:forCategory:)]) {
                [avCtrl setVolumeTo:vol forCategory:cat];
            }
        }
        [self.savedVolumes removeAllObjects];
    }
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        g_isMutingHUD = NO;
        [self suppressMediaHUD:NO];
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
        // 如果用户从【静音App】直接滑到了【非静音App】，也应立刻恢复
        if (self.isCurrentlyMuted) {
            self.isCurrentlyMuted = NO;
            [self performVolumeRestore];
        }
    }
}

// 核心：处理 App 退居后台 / 被销毁
- (void)processAppBackground:(NSString *)bundleID {
    if (!bundleID || bundleID.length == 0) return;
    
    // 如果退到后台的正是我们当前正在静音的 App，立刻解除静音
    if ([self.lastFrontmostBundleID isEqualToString:bundleID] && self.isCurrentlyMuted) {
        self.isCurrentlyMuted = NO;
        self.lastFrontmostBundleID = @""; // 重置
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
                    // 主线程震动反馈，防止异常
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
//  [超强引擎] iOS 14-17 FrontBoard Scene 生命周期拦截
// ───────────────────────────────────────────
%hook SBMainDisplaySceneManager

- (void)_noteDidChangeToVisibility:(unsigned long long)visibility previouslyExisted:(_Bool)existed forScene:(id)scene {
    %orig;
    @try {
        if ([scene respondsToSelector:@selector(clientProcess)]) {
            // 使用 KVC 绕过编译期类型验证，绝对安全
            id process = [scene valueForKey:@"clientProcess"];
            if (process) {
                NSString *bundleID = [process valueForKey:@"bundleIdentifier"];
                if (bundleID && [bundleID isKindOfClass:[NSString class]]) {
                    // FBSSceneVisibility: 2=前台可见, 0=销毁/未追踪, 1=后台
                    if (visibility == 2) {
                        [[AppMuteManager sharedManager] processAppForeground:bundleID];
                    } else if (visibility == 0 || visibility == 1) {
                        [[AppMuteManager sharedManager] processAppBackground:bundleID];
                    }
                }
            }
        }
    } @catch (NSException *e) {
        // 捕获可能因系统版本差异导致的 KVC 异常，防止安全模式
    }
}
%end


// ───────────────────────────────────────────
//  [安全底线] 经典 SpringBoard 通知（应对老旧普通进程）
// ───────────────────────────────────────────
%hook SpringBoard

- (void)frontDisplayDidChange:(id)change {
    %orig;
    @try {
        NSString *newBundleID = nil;
        if (change) {
            if ([change respondsToSelector:@selector(applicationBundleID)]) {
                newBundleID = [change performSelector:@selector(applicationBundleID)];
            } else if ([change respondsToSelector:@selector(bundleIdentifier)]) {
                newBundleID = [change performSelector:@selector(bundleIdentifier)];
            } else {
                id app = [change valueForKey:@"application"];
                if ([app respondsToSelector:@selector(bundleIdentifier)]) {
                    newBundleID = [app performSelector:@selector(bundleIdentifier)];
                }
            }
        }
        
        if (!newBundleID) {
            if ([self respondsToSelector:@selector(_accessibilityFrontMostApplication)]) {
                id app = [self performSelector:@selector(_accessibilityFrontMostApplication)];
                newBundleID = [app performSelector:@selector(bundleIdentifier)];
            }
        }
        
        if (newBundleID) {
            [[AppMuteManager sharedManager] processAppForeground:newBundleID];
        } else {
            // newBundleID 为 nil 代表回到了桌面，触发后台恢复机制
            [[AppMuteManager sharedManager] processAppBackground:[AppMuteManager sharedManager].lastFrontmostBundleID];
        }
    } @catch (NSException *e) {}
}

// 极旧版本的兼容保护
- (void)_handleApplicationProcessStateDidChangeNotification:(NSNotification *)notification {
    %orig;
    @try {
        if ([self respondsToSelector:@selector(_accessibilityFrontMostApplication)]) {
            id app = [self performSelector:@selector(_accessibilityFrontMostApplication)];
            if (app) {
                NSString *bundleID = [app performSelector:@selector(bundleIdentifier)];
                if (bundleID) {
                    [[AppMuteManager sharedManager] processAppForeground:bundleID];
                }
            }
        }
    } @catch (NSException *e) {}
}
%end


// ───────────────────────────────────────────
//  阻止 HUD 弹出的双保险
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
