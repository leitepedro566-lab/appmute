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

// iOS 14-17 音频控制器
@interface AVSystemController : NSObject
+ (id)sharedAVSystemController;
- (_Bool)getVolume:(float *)volume forCategory:(id)category;
- (_Bool)setVolumeTo:(float)to forCategory:(id)category;
@end

@interface SBMediaController : NSObject
+ (instancetype)sharedInstance;
+ (instancetype)sharedInstanceIfExists; 
@property (nonatomic, assign) BOOL suppressHUD;
- (void)setSuppressHUD:(BOOL)hud;
@end

@interface SpringBoard : UIApplication
@end

// 【修复编译错误的核心】显式声明 SceneManager 及其私有方法
@interface SBMainDisplaySceneManager : NSObject
- (BOOL)_isExternalForegroundScene:(id)scene;
@end


// ================== 全局数据与状态管理 ==================
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

// 安全隐藏音量 HUD
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

// 开启媒体静音 (仅限控制中心媒体音量)
- (void)performVolumeChangeToMute {
    [self suppressMediaHUD:YES];
    
    AVSystemController *avCtrl = [%c(AVSystemController) sharedAVSystemController];
    if (avCtrl) {
        // 仅接管 Audio/Video（媒体音量），绝对不会影响 Ringtone（铃声/闹钟）
        NSString *cat = @"Audio/Video";
        
        if (!self.savedVolumes) self.savedVolumes = [NSMutableDictionary dictionary];
        
        float vol = 0.0;
        if ([avCtrl respondsToSelector:@selector(getVolume:forCategory:)]) {
            [avCtrl getVolume:&vol forCategory:cat];
            if (vol > 0.01) {
                self.savedVolumes[cat] = @(vol);
            }
        }
        
        if ([avCtrl respondsToSelector:@selector(setVolumeTo:forCategory:)]) {
            [avCtrl setVolumeTo:0.0 forCategory:cat];
        }
    }
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self suppressMediaHUD:NO];
    });
}

// 恢复媒体音量
- (void)performVolumeRestore {
    [self suppressMediaHUD:YES];
    
    AVSystemController *avCtrl = [%c(AVSystemController) sharedAVSystemController];
    if (avCtrl) {
        NSString *cat = @"Audio/Video";
        float vol = 0.5; // 兜底音量
        
        if (self.savedVolumes[cat]) {
            vol = [self.savedVolumes[cat] floatValue];
        }
        
        if ([avCtrl respondsToSelector:@selector(setVolumeTo:forCategory:)]) {
            [avCtrl setVolumeTo:vol forCategory:cat];
        }
        [self.savedVolumes removeAllObjects];
    }
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self suppressMediaHUD:NO];
    });
}

// 处理 App 进入前台
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

// 处理 App 退居后台
- (void)processAppBackground:(NSString *)bundleID {
    if (!bundleID || bundleID.length == 0) return;
    
    if ([self.lastFrontmostBundleID isEqualToString:bundleID] && self.isCurrentlyMuted) {
        self.isCurrentlyMuted = NO;
        self.lastFrontmostBundleID = @""; 
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
    return [mutOrig copy];
}
@end


// ================== 核心 Hook 区 ==================

%hook SBIconView

- (NSArray *)applicationShortcutItems {
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
//  [超强安全引擎] 拦截生命周期
// ───────────────────────────────────────────
%hook SBMainDisplaySceneManager

- (void)_noteDidChangeToVisibility:(unsigned long long)visibility previouslyExisted:(_Bool)existed forScene:(id)scene {
    %orig;
    
    // 必须包裹在主线程执行，防止底层 AVSystemController 在后台线程访问引发崩溃
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 精确过滤掉键盘、小组件等系统干扰 Scene，大幅降低运算负担
            if ([self respondsToSelector:@selector(_isExternalForegroundScene:)]) {
                if (![self _isExternalForegroundScene:scene]) {
                    return; // 不是前台独立 App 则忽略
                }
            }
            
            id process = nil;
            if ([scene respondsToSelector:@selector(clientProcess)]) {
                process = [scene performSelector:@selector(clientProcess)];
            }
            
            NSString *bundleID = nil;
            if (process && [process respondsToSelector:@selector(bundleIdentifier)]) {
                bundleID = [process performSelector:@selector(bundleIdentifier)];
            }
            
            if (bundleID && [bundleID isKindOfClass:[NSString class]]) {
                // FBSSceneVisibility: 2=前台可见, 0=销毁/未追踪, 1=后台
                if (visibility == 2) {
                    [[AppMuteManager sharedManager] processAppForeground:bundleID];
                } else if (visibility == 0 || visibility == 1) {
                    [[AppMuteManager sharedManager] processAppBackground:bundleID];
                }
            }
        } @catch (NSException *e) {
            // 彻底隔离异常，绝不拖累 SpringBoard
        }
    });
}
%end


// ───────────────────────────────────────────
//  [安全底线] 兜底回退机制
// ───────────────────────────────────────────
%hook SpringBoard

- (void)frontDisplayDidChange:(id)change {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            NSString *newBundleID = nil;
            if (change) {
                if ([change respondsToSelector:@selector(applicationBundleID)]) {
                    newBundleID = [change performSelector:@selector(applicationBundleID)];
                } else if ([change respondsToSelector:@selector(bundleIdentifier)]) {
                    newBundleID = [change performSelector:@selector(bundleIdentifier)];
                }
            }
            
            if (newBundleID) {
                [[AppMuteManager sharedManager] processAppForeground:newBundleID];
            } else {
                [[AppMuteManager sharedManager] processAppBackground:[AppMuteManager sharedManager].lastFrontmostBundleID];
            }
        } @catch (NSException *e) {}
    });
}
%end

// ================== 初始化构造 ==================
%ctor {
    @autoreleasepool {
        // 在启动时预加载配置，确保不会阻塞主队列
        [AppMuteManager sharedManager];
    }
}
