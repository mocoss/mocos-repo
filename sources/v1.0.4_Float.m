#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <limits.h>

// Experimental private API adapter. No MiYou binary or code is included.
static void WFLog(NSString *s) { NSLog(@"[WeChatFloat] %@",s); }
static id Call(id obj, NSString *name, NSArray *args) {
    if (!obj) return nil;
    SEL sel=NSSelectorFromString(name);
    if (![obj respondsToSelector:sel]) return nil;
    @try {
        NSMethodSignature *sig=[obj methodSignatureForSelector:sel];
        if (!sig || sig.numberOfArguments!=args.count+2) return nil;
        const char *ret=sig.methodReturnType;
        if (*ret!='@' && *ret!='v') return nil;
        NSInvocation *inv=[NSInvocation invocationWithMethodSignature:sig];
        inv.target=obj; inv.selector=sel;
        for (NSUInteger i=0;i<args.count;i++) {
            const char *t=[sig getArgumentTypeAtIndex:i+2];
            while (strchr("rnNoORV",*t) && *t) t++;
            id a=args[i]; if (a==[NSNull null]) a=nil;
            if (*t=='@' || *t=='#') { __unsafe_unretained id v=a; [inv setArgument:&v atIndex:i+2]; }
            else if (*t=='B' || *t=='c') { BOOL v=[a boolValue]; [inv setArgument:&v atIndex:i+2]; }
            else if (*t=='q' || *t=='Q') { long long v=[a longLongValue]; [inv setArgument:&v atIndex:i+2]; }
            else if (*t=='i' || *t=='I') { int v=[a intValue]; [inv setArgument:&v atIndex:i+2]; }
            else return nil;
        }
        [inv invoke];
        if (*ret=='@') { __unsafe_unretained id result=nil; [inv getReturnValue:&result]; return result; }
    } @catch (NSException *e) { WFLog([NSString stringWithFormat:@"API %@ failed: %@",name,e.name]); }
    return nil;
}
static id Service(NSString *name) {
    Class c=NSClassFromString(name); if (!c) return nil;
    id center=Call(NSClassFromString(@"MMServiceCenter"),@"defaultCenter",@[]);
    return Call(center,@"getService:",@[c]);
}
static NSString *StorageDirectory(void) {
    static NSString *dir;static dispatch_once_t once;
    dispatch_once(&once,^{NSURL *library=[NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
        dir=[(library.path?:[NSHomeDirectory() stringByAppendingPathComponent:@"Library"]) stringByAppendingPathComponent:@"Application Support/WeChatFloat"];
    });return dir;
}
static NSString *PrefsPath(void) {return [StorageDirectory() stringByAppendingPathComponent:@"settings.plist"];}
static NSString *BackupPath(void) {return [StorageDirectory() stringByAppendingPathComponent:@"settings.backup.plist"];}
static NSDictionary *Defaults(void) {static NSDictionary *d;static dispatch_once_t once;dispatch_once(&once,^{d=@{@"left":@YES,@"size":@39,@"idleAlpha":@0.5,@"flashForever":@NO,@"flashSeconds":@5,@"listUnread":@NO,@"buttonUnread":@NO};});return d;}
static NSDictionary *EffectivePrefs;
static BOOL StorageAttempted=NO;
static NSDictionary *PrefsCache;
static BOOL StorageReady=NO;
static NSString *StorageStatus=@"not loaded";
static NSString *StatePath(void){return [StorageDirectory() stringByAppendingPathComponent:@"state-v3.plist"];}
static NSString *StateBackup(void){return [StorageDirectory() stringByAppendingPathComponent:@"state-v3.backup.plist"];}
static NSString *PositionPath(void){return [StorageDirectory() stringByAppendingPathComponent:@"position-v3.plist"];}
static NSString *StateKey=@"local.mocos.wechatfloat.state.v3";
static BOOL ProtectedAvailable(void) {return UIApplication.sharedApplication.protectedDataAvailable;}
static void ProtectFile(NSString *path){[NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:path error:nil];}
static NSDictionary *ReadDictionary(NSString *path,NSError **error){NSData *d=[NSData dataWithContentsOfFile:path options:0 error:error];if(!d)return nil;id v=[NSPropertyListSerialization propertyListWithData:d options:NSPropertyListImmutable format:nil error:error];return [v isKindOfClass:NSDictionary.class]?v:nil;}
static BOOL WriteData(NSData *d,NSString *path){if(!d)return NO;NSError *e=nil;BOOL ok=[d writeToFile:path options:NSDataWritingAtomic error:&e];if(ok)ProtectFile(path);else StorageStatus=[NSString stringWithFormat:@"write error %@/%ld",e.domain,(long)e.code];return ok;}
static NSArray *UserKeys(void){return @[@"enabled",@"left",@"size",@"idleAlpha",@"flashForever",@"flashSeconds",@"customIconPNG",@"iconMode",@"listUnread",@"buttonUnread"];}
static NSDictionary *CleanSettings(NSDictionary *source){
    if(![source isKindOfClass:NSDictionary.class])return nil;
    NSMutableDictionary *p=[NSMutableDictionary dictionary];
    for(NSString *k in UserKeys()){
        id v=source[k];if(!v)continue;
        if([k isEqualToString:@"customIconPNG"]){if(![v isKindOfClass:NSData.class] || [v length]>1024*1024 || ![UIImage imageWithData:v])return nil;p[k]=v;}
        else if([k isEqualToString:@"iconMode"]){if(![v isKindOfClass:NSString.class] || ![@[@"custom",@"default"] containsObject:v])return nil;p[k]=v;}
        else if([k isEqualToString:@"listUnread"] || [k isEqualToString:@"buttonUnread"]){
            if(![v isKindOfClass:NSNumber.class])return nil;
            double b=[v doubleValue];
            if(b!=0 && b!=1)return nil;
            p[k]=v;
        }
        else {if(![v isKindOfClass:NSNumber.class])return nil;double n=[v doubleValue];if(!isfinite(n))return nil;
            if(([k isEqualToString:@"size"]&&(n<20||n>80))||([k isEqualToString:@"idleAlpha"]&&(n<.1||n>1))||([k isEqualToString:@"flashSeconds"]&&(n<3||n>60)))return nil;p[k]=v;}
    }
    if([p[@"iconMode"] isEqual:@"custom"] && !p[@"customIconPNG"])return nil;
    if([p[@"iconMode"] isEqual:@"default"]) [p removeObjectForKey:@"customIconPNG"];
    return p;
}
static NSDictionary *Envelope(NSDictionary *obj){
    if(![obj isKindOfClass:NSDictionary.class] || ![obj[@"schema"] isEqual:@3] || ![obj[@"revision"] isKindOfClass:NSNumber.class] || [obj[@"revision"] longLongValue]<1)return nil;
    NSDictionary *p=CleanSettings(obj[@"settings"]);if(!p || !p.count || !p[@"iconMode"])return nil;
    return @{@"schema":@3,@"revision":obj[@"revision"],@"settings":p,@"reason":[obj[@"reason"] isKindOfClass:NSString.class]?obj[@"reason"]:@"unknown"};
}
static NSDictionary *CurrentState;
static BOOL EnsureDirectory(void){return [NSFileManager.defaultManager createDirectoryAtPath:StorageDirectory() withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];}
static BOOL PersistState(NSDictionary *state){
    if(!ProtectedAvailable() || !EnsureDirectory())return NO;
    NSData *d=[NSPropertyListSerialization dataWithPropertyList:state format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    BOOL file=WriteData(d,StatePath());
    if(file)file=[ReadDictionary(StatePath(),nil) isEqual:state];
    NSUserDefaults *u=NSUserDefaults.standardUserDefaults;
    [u setObject:state forKey:StateKey];[u synchronize];
    BOOL prefs=[[u dictionaryForKey:StateKey] isEqual:state];
    if(!file && !prefs)return NO;
    BOOL backup=WriteData(d,StateBackup());
    CurrentState=state;
    StorageStatus=[NSString stringWithFormat:@"v3 revision=%@ reason=%@ file=%@ prefs=%@ mirror=%@",state[@"revision"],state[@"reason"],file?@"yes":@"no",prefs?@"yes":@"no",backup?@"yes":@"no"];
    return YES;
}
static void ReloadStorage(void){
    StorageAttempted=YES;EffectivePrefs=nil;
    NSDictionary *legacyPosition=ReadDictionary(PrefsPath(),nil);
    if(!ProtectedAvailable()){StorageReady=NO;StorageStatus=@"locked; writes blocked";return;}
    NSMutableArray *c=[NSMutableArray array];
    for(id raw in @[ReadDictionary(StatePath(),nil)?:@{},ReadDictionary(StateBackup(),nil)?:@{},[NSUserDefaults.standardUserDefaults dictionaryForKey:StateKey]?:@{}]){NSDictionary *v=Envelope(raw);if(v)[c addObject:v];}
    NSDictionary *best=CurrentState;
    for(NSDictionary *v in c)if(!best || [v[@"revision"] longLongValue]>[best[@"revision"] longLongValue])best=v;
    if(best){CurrentState=best;PrefsCache=best[@"settings"];StorageReady=YES;StorageStatus=[NSString stringWithFormat:@"v3 loaded revision=%@ sources=%lu",best[@"revision"],(unsigned long)c.count];}
    else {
        NSDictionary *old=ReadDictionary(PrefsPath(),nil),*oldBackup=ReadDictionary(BackupPath(),nil);
        NSDictionary *legacy=old?:oldBackup;
        if(![legacy[@"customIconPNG"] isKindOfClass:NSData.class] && [oldBackup[@"customIconPNG"] isKindOfClass:NSData.class])legacy=oldBackup;
        NSDictionary *clean=CleanSettings(legacy);
        if(clean && clean.count){NSMutableDictionary *p=[clean mutableCopy];
            if(!p[@"customIconPNG"]){for(NSString *n in @[@"icon.png",@"icon.png.backup"]){NSData *d=[NSData dataWithContentsOfFile:[StorageDirectory() stringByAppendingPathComponent:n]];if(d.length && d.length<=1024*1024 && [UIImage imageWithData:d]){p[@"customIconPNG"]=d;break;}}}
            p[@"iconMode"]=p[@"customIconPNG"]?@"custom":@"default";
            NSDictionary *state=@{@"schema":@3,@"revision":@1,@"settings":p,@"reason":@"legacy migration"};
            PrefsCache=p;StorageReady=YES;PersistState(state);
        }else {
            BOOL exists=NO;for(NSString *path in @[StatePath(),StateBackup(),PrefsPath(),BackupPath()])exists|=[NSFileManager.defaultManager fileExistsAtPath:path];
            StorageReady=!exists;StorageStatus=exists?@"no valid state; writes blocked":@"new installation; defaults";
        }
    }
    NSDictionary *pos=ReadDictionary(PositionPath(),nil);
    NSMutableDictionary *merged=[PrefsCache?:@{} mutableCopy];
    for(NSString *k in @[@"x",@"y"]){id n=pos[k];if(!n)n=PrefsCache[k]?:legacyPosition[k];if([n isKindOfClass:NSNumber.class] && isfinite([n doubleValue]))merged[k]=n;}
    PrefsCache=merged;
}
static NSDictionary *ReadPrefs(void){if(!StorageAttempted)ReloadStorage();if(!EffectivePrefs){NSMutableDictionary *p=[Defaults() mutableCopy];if(PrefsCache)[p addEntriesFromDictionary:PrefsCache];EffectivePrefs=[p copy];}return EffectivePrefs;}
static NSMutableDictionary *Prefs(void){return [ReadPrefs() mutableCopy];}
static BOOL SavePrefsReason(NSDictionary *input,NSString *reason,BOOL allowReset){
    if(!ProtectedAvailable() || !StorageReady)return NO;
    for(id raw in @[ReadDictionary(StatePath(),nil)?:@{},[NSUserDefaults.standardUserDefaults dictionaryForKey:StateKey]?:@{}]){
        NSDictionary *v=Envelope(raw);
        if(v && [v[@"revision"] longLongValue]>[CurrentState[@"revision"] longLongValue]){ReloadStorage();StorageStatus=@"newer state reloaded; stale write rejected";return NO;}
        if(v && CurrentState && [v[@"revision"] isEqual:CurrentState[@"revision"]] && ![v[@"settings"] isEqual:CurrentState[@"settings"]]){StorageStatus=@"same revision conflict; write blocked";return NO;}
    }
    NSMutableDictionary *p=[CleanSettings(input) mutableCopy];if(!p)return NO;
    for(NSString *k in input){if([k isEqualToString:@"x"] || [k isEqualToString:@"y"])continue;if(!p[k]){WFLog([NSString stringWithFormat:@"SavePrefsReason dropped unknown/invalid key: %@",k]);StorageStatus=[NSString stringWithFormat:@"dropped key %@",k];return NO;}}
    NSDictionary *previous=CurrentState[@"settings"];
    if(!allowReset && previous[@"customIconPNG"] && !p[@"customIconPNG"]){p[@"customIconPNG"]=previous[@"customIconPNG"];p[@"iconMode"]=@"custom";}
    if(p[@"customIconPNG"])p[@"iconMode"]=@"custom";
    else if(allowReset || !p[@"iconMode"])p[@"iconMode"]=@"default";
    BOOL ok=YES;
    if(![p isEqual:previous]){
        long long rev=[CurrentState[@"revision"] longLongValue];
        if(rev>=LLONG_MAX-1)return NO;
        ok=PersistState(@{@"schema":@3,@"revision":@(rev+1),@"settings":p,@"reason":reason});
    }
    if(!ok)return NO;
    NSMutableDictionary *merged=[p mutableCopy];NSMutableDictionary *pos=[NSMutableDictionary dictionary];
    for(NSString *k in @[@"x",@"y"]){id n=input[k];if([n isKindOfClass:NSNumber.class] && isfinite([n doubleValue])){pos[k]=n;merged[k]=n;}}
    if(pos.count){NSDictionary *old=ReadDictionary(PositionPath(),nil);if(![pos isEqual:old] && EnsureDirectory())ok=WriteData([NSPropertyListSerialization dataWithPropertyList:pos format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil],PositionPath());}
    PrefsCache=merged;EffectivePrefs=nil;return ok;
}
static BOOL SavePrefs(NSDictionary *p){return SavePrefsReason(p,@"settings or position",NO);}
static void Settings(void);
static BOOL Enabled(void) {id v=ReadPrefs()[@"enabled"];return v?[v boolValue]:YES;}
static UIImage *CustomIcon;
static BOOL IconLoaded=NO;
static NSString *IconStatus=@"not loaded";
static NSCache *AvatarCache;
static NSMutableDictionary *AvatarTimes;
static void ClearImages(void) {CustomIcon=nil;IconLoaded=NO;[AvatarCache removeAllObjects];[AvatarTimes removeAllObjects];}
static NSString *IconPath(void) {return [[PrefsPath() stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"icon.png"];}
static BOOL LeftHand(void){return [ReadPrefs()[@"left"] boolValue];}
static CGFloat Diameter(void) {id v=ReadPrefs()[@"size"];return v?MAX(20,MIN(80,[v doubleValue])):39;}
static BOOL InstallHook(void);
static BOOL SettingsRegistered=NO;
static void RegisterSettings(void);
static NSString *Text(id o,NSString *key) {
    id v=Call(o,key,@[]);
    if(![v isKindOfClass:NSString.class] && o) { @try {v=[o valueForKey:key];} @catch (NSException *e){v=nil;} }
    return [v isKindOfClass:NSString.class] && [v length]?v:nil;
}
static NSUInteger MessageCallbacks=0,QueuedMessages=0,MissingSender=0,MissingSelf=0,SelfMessages=0;
static BOOL MessageHooked=NO;
static NSString *AvatarStatus=@"not attempted";
static UIViewController *Top(void) {
    UIWindow *w=nil;
    for (UIWindow *x in UIApplication.sharedApplication.windows) if (x.isKeyWindow) {w=x;break;}
    UIViewController *v=w.rootViewController;
    for (int i=0;v && i<20;i++) {
        if (v.presentedViewController) v=v.presentedViewController;
        else if ([v isKindOfClass:UINavigationController.class]) v=((UINavigationController*)v).visibleViewController;
        else if ([v isKindOfClass:UITabBarController.class]) v=((UITabBarController*)v).selectedViewController;
        else break;
    }
    return v;
}
static void Notice(NSString *text) {
    UIViewController *v=Top(); if (!v) return;
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"便捷聊天浮窗" message:text preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [v presentViewController:a animated:YES completion:nil];
}
static id Contact(NSString *user) { return Call(Service(@"CContactMgr"),@"getContactByName:",@[user?:@""]); }
static NSString *Label(id c) { return Text(c,@"m_nsRemark")?:Text(c,@"m_nsNickName")?:Text(c,@"m_nsUsrName")?:@"联系人"; }
static NSUInteger MutedSkipped=0,FoldedSkipped=0,GroupStateUnknown=0;
static NSMutableString *GroupSignatures;
static BOOL ReadFlag(id obj,NSString *name,NSArray *args,BOOL *known) {
    *known=NO; SEL sel=NSSelectorFromString(name);
    NSMethodSignature *sig=[obj methodSignatureForSelector:sel];
    if(!sig || sig.numberOfArguments!=args.count+2 || (*sig.methodReturnType!='B' && *sig.methodReturnType!='c'))return NO;
    if(args.count && *[sig getArgumentTypeAtIndex:2]!='@')return NO;
    @try {
        NSInvocation *inv=[NSInvocation invocationWithMethodSignature:sig];inv.target=obj;inv.selector=sel;
        if(args.count){__unsafe_unretained id a=args[0];[inv setArgument:&a atIndex:2];}
        [inv invoke];BOOL value=NO;[inv getReturnValue:&value];*known=YES;return value;
    }@catch(NSException *e){return NO;}
}
static NSSet *ExcludedUsernames(void) {
    static NSSet *s; static dispatch_once_t once;
    dispatch_once(&once,^{
        s = [NSSet setWithArray:@[
            @"brandsessionholder", @"brandservicesessionholder",
            @"notification_messages", @"notifymessage", @"notify_message",
            @"newsapp", @"weixin", @"filehelper", @"floatbottle",
            @"medianote", @"qqmail", @"qqsafe", @"fmessage",
            @"weibo", @"qqsync", @"facebook", @"twitter",
            @"tmessage", @"qmessage", @"officialaccounts",
            @"mphelper", @"weixinreminder", @"voipmsgs",
            @"helper_entry", @"exmail_tool", @"weixinpay",
            @"wechatpay", @"wxpay", @"tenpay", @"weixinopen",
            @"qqfriend", @"linkedinplugin", @"qqcontactsync",
            @"wechatteam", @"weixinteam", @"weixinhelper",
            @"weixin_team", @"official_website", @"mp",
            @"appbrandcustomerservicemsg"
        ]];
    });
    return s;
}
static BOOL IsExcludedContact(id c) {
    @try {
        if (!c) return YES;
        NSString *u = Text(c,@"m_nsUsrName");
        if (!u.length) return YES;
        if ([u hasPrefix:@"gh_"]) return YES;
        if ([u hasSuffix:@"@opencustom"] || [u hasSuffix:@"@openim"]) return YES;
        if ([ExcludedUsernames() containsObject:u.lowercaseString]) return YES;
        if ([ExcludedUsernames() containsObject:u]) return YES;
        BOOL known = NO;
        if (ReadFlag(c,@"isBrandContact",@[],&known) && known) return YES;
        if (ReadFlag(c,@"isServiceBrandContact",@[],&known) && known) return YES;
        id v = [c valueForKey:@"m_uiBrandSubscribeType"];
        if ([v isKindOfClass:NSNumber.class] && [v integerValue] > 0) return YES;
    } @catch (__unused NSException *e) {}
    return NO;
}
// 识别是否为“折叠的群聊”虚拟会话
static BOOL IsFoldedBoxContact(id c) {
    if (!c) return NO;
    NSString *u = Text(c,@"m_nsUsrName");
    if ([u isEqualToString:@"chatroom_session_box"]) return YES;
    if ([[Text(c,@"m_nsNickName") stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] isEqualToString:@"折叠的群聊"]) return YES;
    return NO;
}
static UIImage *Avatar(id c) {
    NSString *u=Text(c,@"m_nsUsrName");
    if(!AvatarCache){AvatarCache=[NSCache new];AvatarCache.countLimit=64;AvatarCache.totalCostLimit=2*1024*1024;AvatarTimes=[NSMutableDictionary dictionary];}
    UIImage *cached=u?[AvatarCache objectForKey:u]:nil;
    if(cached && CACurrentMediaTime()-[AvatarTimes[u] doubleValue]<60)return cached;
    id img=u?Call(Service(@"CHeadImgMgr"),@"getHeadImage:withCategory:",@[u,@0]):nil;
    if(![img isKindOfClass:UIImage.class])img=Call(c,@"getContactHeadImage",@[]);
    if([img isKindOfClass:UIImage.class]) {
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(88,88),NO,1);
        [img drawInRect:CGRectMake(0,0,88,88)];UIImage *small=UIGraphicsGetImageFromCurrentImageContext();UIGraphicsEndImageContext();
        if(small && u){if(AvatarTimes.count>=64)[AvatarTimes removeAllObjects];[AvatarCache setObject:small forKey:u cost:88*88*4];AvatarTimes[u]=@(CACurrentMediaTime());}
        return small?:img;
    }
    return [UIImage systemImageNamed:@"person.crop.square.fill"];
}
static BOOL UnreadCount(id obj,NSString *name,unsigned long long *out);
// 免打扰、公众号返回未读 0。
static BOOL UnreadForUser(NSString *user,unsigned long long *out) {
    @try {
        if (out) *out = 0;
        if (!user.length) return NO;
        unsigned long long n = 0; BOOL read = NO;
        for (NSString *service in @[@"MMSessionMgr",@"MMNewSessionMgr"]) {
            id mgr=Service(service);if(!mgr)continue;
            id session=Call(mgr,@"GetSessionByUserName:",@[user]);
            if(session && UnreadCount(session,@"m_uUnReadCount",&n)){read=YES;break;}
        }
        if(!read) return NO;
        if(n==0) return YES;
        id c = Contact(user);
        if (!c) return YES;
        if (IsExcludedContact(c)) return YES;
        
        BOOL known=NO;
        BOOL notify=ReadFlag(c,@"isChatStatusNotifyOpen",@[],&known);
        if(known && !notify) return YES;
        
        if(out) *out = n;
        return YES;
    } @catch (__unused NSException *e) {
        if (out) *out = 0;
        return NO;
    }
}
static BOOL UnreadCount(id obj,NSString *name,unsigned long long *out) {
    NSMethodSignature *sig=[obj methodSignatureForSelector:NSSelectorFromString(name)];
    if(!sig || sig.numberOfArguments!=2 || !strchr("cCBiIsSlLqQ",*sig.methodReturnType) || sig.methodReturnLength>8)return NO;
    @try {NSInvocation *inv=[NSInvocation invocationWithMethodSignature:sig];inv.target=obj;inv.selector=NSSelectorFromString(name);[inv invoke];*out=0;[inv getReturnValue:out];return YES;}@catch(NSException *e){return NO;}
}
static BOOL ForeverFlash(void){id v=ReadPrefs()[@"flashForever"];return v?[v boolValue]:NO;}
static double FlashSeconds(void){id v=ReadPrefs()[@"flashSeconds"];return v?MAX(3,MIN(60,[v doubleValue])):5;}
static NSUInteger ReadCleared=0,ReadUnknown=0;

@interface WFRow : UITableViewCell
@property(nonatomic,strong) UIImageView *portrait;
@property(nonatomic,strong) UILabel *badge;
- (void)applyBadge:(unsigned long long)count;
@end
@implementation WFRow
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString*)reuse {
    if((self=[super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse])) {
        _portrait=[[UIImageView alloc] init];_portrait.contentMode=UIViewContentModeScaleAspectFill;
        _portrait.clipsToBounds=YES;_portrait.layer.cornerRadius=7;
        _portrait.tintColor=UIColor.systemGrayColor;[self.contentView addSubview:_portrait];
        _badge=[[UILabel alloc] init];_badge.textAlignment=NSTextAlignmentCenter;_badge.font=[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        _badge.textColor=UIColor.whiteColor;_badge.backgroundColor=[UIColor systemRedColor];
        _badge.layer.cornerRadius=8;_badge.clipsToBounds=YES;_badge.hidden=YES;[self.contentView addSubview:_badge];
        self.textLabel.font=[UIFont systemFontOfSize:17];self.detailTextLabel.font=[UIFont systemFontOfSize:12];self.detailTextLabel.textColor=UIColor.secondaryLabelColor;
    }return self;
}
- (void)applyBadge:(unsigned long long)count {
    self.badge.tag = count;
    if(!count){self.badge.hidden=YES;return;}
    self.badge.hidden=NO;
    self.badge.text=count>99?@"99+":[NSString stringWithFormat:@"%llu",count];
    [self.badge sizeToFit];
    CGFloat w=MAX(16,self.badge.frame.size.width+10);
    self.badge.frame=CGRectMake(16+44-w/2,0,w,16);
}
- (void)layoutSubviews {
    [super layoutSubviews];CGFloat y=(self.contentView.bounds.size.height-44)/2;
    self.portrait.frame=CGRectMake(16,y,44,44);
    CGFloat width=MAX(0,self.contentView.bounds.size.width-88);
    self.textLabel.frame=CGRectMake(74,y+2,width,23);self.detailTextLabel.frame=CGRectMake(74,y+27,width,17);
    [self applyBadge:self.badge.tag];
}
@end
static void OpenChat(NSString *user) {
    id c=Contact(user); UIViewController *v=Top();
    UINavigationController *nav=[v isKindOfClass:UINavigationController.class]?(id)v:v.navigationController;
    id logic=Service(@"MMMsgLogicManager");
    SEL sel=NSSelectorFromString(@"PushOtherBaseMsgControllerByContact:navigationController:animated:");
    if (!c || !nav || ![logic respondsToSelector:sel]) {
        WFLog(@"Chat adapter unavailable"); Notice(@"当前微信未匹配聊天跳转接口。请使用微信原界面打开聊天，并反馈此提示。"); return;
    }
    Call(logic,NSStringFromSelector(sel),@[c,nav,@YES]);
}
static NSMutableString *Diagnostics;
static void MethodDiagnostics(id obj,NSString *filter) {
    for(Class c=[obj class];c && c!=NSObject.class;c=class_getSuperclass(c)) {
        unsigned int n=0;Method *ms=class_copyMethodList(c,&n);
        for(unsigned int i=0;i<n;i++) {NSString *name=NSStringFromSelector(method_getName(ms[i]));if(!filter || [name.lowercaseString containsString:filter]) [Diagnostics appendFormat:@"%@ %s\n",name,method_getTypeEncoding(ms[i])];}
        free(ms);
    }
}
static void SessionRows(id obj,NSMutableArray *rows,NSMutableSet *seen,NSUInteger depth) {
    if(!obj || depth>4)return;
    if([obj isKindOfClass:NSDictionary.class]) {for(id v in [obj allValues])SessionRows(v,rows,seen,depth+1);return;}
    if([obj isKindOfClass:NSArray.class] || [obj isKindOfClass:NSSet.class] || [obj isKindOfClass:NSOrderedSet.class]) {for(id v in obj)SessionRows(v,rows,seen,depth+1);return;}
    NSString *u=[obj isKindOfClass:NSString.class]?obj:(Text(obj,@"m_nsUsrName")?:Text(obj,@"m_nsUserName")?:Text(obj,@"userName"));
    if(!u.length)return;
    if([seen containsObject:u])return;
    @try {
        id c=Contact(u); if(!c)return;
        if (IsExcludedContact(c)) return;
        [seen addObject:u];[rows addObject:c];
    } @catch (__unused NSException *e) {}
}
static NSArray *LoadContactsInternal(BOOL diagnostic) {
    Diagnostics=[NSMutableString stringWithString:@"WeChatFloat 1.0.4\nSource: homepage sessions only\n"];
    NSMutableArray *rows=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];
    for(NSString *service in @[@"MMSessionMgr",@"MMNewSessionMgr"]) {
        id mgr=Service(service);[Diagnostics appendFormat:@"%@ service=%@\n",service,mgr?NSStringFromClass([mgr class]):@"nil"];
        for(NSString *name in @[@"GetUserNamesOnSessionList",@"GetSessionInfoList",@"sessionList",@"m_sessionList",@"normalSessions",@"m_normalSessions",@"topSessions",@"m_topSessions"]) {
            NSMethodSignature *sig=[mgr methodSignatureForSelector:NSSelectorFromString(name)];
            if(!sig || sig.numberOfArguments!=2 || *sig.methodReturnType!='@')continue;
            id result=Call(mgr,name,@[]); NSUInteger before=rows.count;SessionRows(result,rows,seen,0);
            [Diagnostics appendFormat:@"%@ result=%@ added=%lu\n",name,result?NSStringFromClass([result class]):@"nil",(unsigned long)(rows.count-before)];
        }
        if(diagnostic)MethodDiagnostics(mgr,@"session");
        if(rows.count)break;
    }
    [Diagnostics appendFormat:@"Session rows: %lu\n",(unsigned long)rows.count];
    if(diagnostic) {
    id sample=rows.firstObject;
    if(sample){[Diagnostics appendFormat:@"Contact class: %@\n",NSStringFromClass([sample class])];MethodDiagnostics(sample,@"name");MethodDiagnostics(sample,@"remark");}
    MethodDiagnostics(Service(@"CMessageMgr"),@"addmsg");
    id heads=Service(@"CHeadImgMgr");[Diagnostics appendFormat:@"Avatar service: %@\n",heads?NSStringFromClass([heads class]):@"nil"];MethodDiagnostics(heads,@"image");
    }
    if(!diagnostic)Diagnostics=nil;
    return rows;
}
static NSArray *LoadContacts(void) {return LoadContactsInternal(NO);}

static NSString *const WFMessageArrivedNotification = @"WFMessageArrived";

@interface WFContacts : UITableViewController <UISearchResultsUpdating>
@property(nonatomic,strong) NSArray *items;
@property(nonatomic,strong) NSArray *shown;
@property(nonatomic,strong) UISearchController *search;
@property(nonatomic,assign,getter=isUnreadEnabled) BOOL unread;
@property(nonatomic,strong) NSTimer *badgeTimer;
@property(nonatomic,strong) id msgObserver;
@property(nonatomic,strong) NSDictionary<NSString*,NSNumber*> *unreadSnapshot;
@end
@implementation WFContacts
- (void)viewDidLoad {
    [super viewDidLoad]; self.title=@"全部联系人";
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.search=[[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater=self; self.search.obscuresBackgroundDuringPresentation=NO;
    self.search.hidesNavigationBarDuringPresentation=NO;self.definesPresentationContext=YES;
    self.search.searchBar.placeholder=@"搜索备注、昵称或账号";
    self.search.searchBar.searchBarStyle=UISearchBarStyleMinimal;
    self.search.searchBar.frame=CGRectMake(0,0,self.view.bounds.size.width,56);
    self.search.searchBar.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    self.tableView.tableHeaderView=self.search.searchBar;
    self.tableView.rowHeight=68;self.tableView.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentAlways;
    self.unread=[ReadPrefs()[@"listUnread"] boolValue];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"设置" style:UIBarButtonItemStylePlain target:self action:@selector(settings)];
    self.items=LoadContacts();
    self.unreadSnapshot=@{};
    [self reloadAndSort];
    self.title=[NSString stringWithFormat:@"首页会话 (%lu)",(unsigned long)self.items.count];
    if (!self.items.count) { UILabel *l=[[UILabel alloc] init]; l.numberOfLines=0; l.text=@"联系人接口尚未匹配\n请点右上角设置 → 复制接口诊断"; l.textAlignment=NSTextAlignmentCenter; self.tableView.backgroundView=l; WFLog(@"Contacts unavailable"); }
    __weak WFContacts *ws = self;
    self.msgObserver = [NSNotificationCenter.defaultCenter addObserverForName:WFMessageArrivedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){
        [ws refreshVisibleBadges];
    }];
}
- (NSDictionary*)computeUnreadSnapshot {
    NSMutableDictionary *snap = [NSMutableDictionary dictionary];
    for (id c in self.items) {
        NSString *u = Text(c,@"m_nsUsrName");
        if (!u) continue;
        unsigned long long n = 0;
        if (UnreadForUser(u, &n)) snap[u] = @(n);
    }
    return snap;
}
// 核心排序：未读优先(降序)，无未读其次，最后固定“折叠的群聊”
- (NSArray*)sortContactsByUnread:(NSArray*)contacts snapshot:(NSDictionary*)snap {
    NSMutableArray *foldedBox = [NSMutableArray array];
    NSMutableArray *withUnread = [NSMutableArray array];
    NSMutableArray *withoutUnread = [NSMutableArray array];
    NSUInteger i = 0;
    for (id c in contacts) {
        if (IsFoldedBoxContact(c)) {
            [foldedBox addObject:c];
            continue;
        }
        NSString *u = Text(c,@"m_nsUsrName");
        unsigned long long n = [snap[u] unsignedLongLongValue];
        NSDictionary *entry = @{@"c": c, @"n": @(n), @"i": @(i++)};
        if (n > 0) [withUnread addObject:entry];
        else [withoutUnread addObject:entry];
    }
    [withUnread sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b){
        NSComparisonResult r = [b[@"n"] compare:a[@"n"]];
        if (r != NSOrderedSame) return r;
        return [a[@"i"] compare:b[@"i"]];
    }];
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *d in withUnread) [result addObject:d[@"c"]];
    for (NSDictionary *d in withoutUnread) [result addObject:d[@"c"]];
    for (id c in foldedBox) [result addObject:c];
    return result;
}
- (void)reloadAndSort {
    NSDictionary *snap = [self computeUnreadSnapshot];
    self.unreadSnapshot = snap;
    NSArray *oldItems = self.items;
    NSArray *sorted = [self sortContactsByUnread:self.items snapshot:snap];
    self.items = sorted;
    NSString *q = self.search.searchBar.text ?: @"";
    NSArray *oldShown = self.shown;
    if (q.length) {
        self.shown = [self.items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id c,NSDictionary *b){
            return [Label(c) localizedCaseInsensitiveContainsString:q] || [Text(c,@"m_nsUsrName") localizedCaseInsensitiveContainsString:q];
        }]];
    } else {
        self.shown = self.items;
    }
    BOOL changed = ![sorted isEqualToArray:oldItems] || ![self.shown isEqualToArray:oldShown];
    if (changed) [self.tableView reloadData];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadAndSort];
    if(self.badgeTimer) return;
    __weak WFContacts *ws = self;
    self.badgeTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *t){
        [ws refreshVisibleBadges];
    }];
    self.badgeTimer.tolerance = 0.4;
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.badgeTimer invalidate]; self.badgeTimer=nil;
}
- (void)dealloc {
    [self.badgeTimer invalidate];
    if(self.msgObserver) [NSNotificationCenter.defaultCenter removeObserver:self.msgObserver];
}
- (void)refreshVisibleBadges {
    BOOL enabled = [ReadPrefs()[@"listUnread"] boolValue];
    NSArray<NSIndexPath *> *vis = [self.tableView indexPathsForVisibleRows];
    for(NSIndexPath *ip in vis) {
        if(ip.row >= (NSInteger)self.shown.count) continue;
        id c = self.shown[ip.row];
        WFRow *cell = (WFRow *)[self.tableView cellForRowAtIndexPath:ip];
        if(![cell isKindOfClass:WFRow.class]) continue;
        if(!enabled){ [cell applyBadge:0]; continue; }
        unsigned long long n = 0;
        if (UnreadForUser(Text(c,@"m_nsUsrName"), &n)) [cell applyBadge:n];
        else [cell applyBadge:0];
    }
}
- (void)settings { Settings(); }
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)updateSearchResultsForSearchController:(UISearchController*)s {
    NSString *q=s.searchBar.text?:@"";
    self.shown=q.length?[self.items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id c,NSDictionary *b){return [Label(c) localizedCaseInsensitiveContainsString:q] || [Text(c,@"m_nsUsrName") localizedCaseInsensitiveContainsString:q];}]]:self.items;
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s {return self.shown.count;}
- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)p {
    WFRow *cell=(id)[t dequeueReusableCellWithIdentifier:@"contact"]?:[[WFRow alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"contact"];
    id c=self.shown[p.row]; cell.textLabel.text=Label(c); cell.detailTextLabel.text=Text(c,@"m_nsUsrName"); cell.portrait.image=Avatar(c);
    BOOL unreadEnabled = [ReadPrefs()[@"listUnread"] boolValue];
    unsigned long long unread = unreadEnabled ? [self.unreadSnapshot[Text(c,@"m_nsUsrName")] unsignedLongLongValue] : 0;
    [cell applyBadge:unread];
    return cell;
}
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)p {
    NSString *u=Text(self.shown[p.row],@"m_nsUsrName");
    [self dismissViewControllerAnimated:YES completion:^{OpenChat(u);}];
}
@end

static unsigned long long TotalUnread(void) {
    @try {
        for(NSString *service in @[@"MMSessionMgr",@"MMNewSessionMgr"]) {
            id mgr=Service(service); if(!mgr) continue;
            id list=Call(mgr,@"GetUserNamesOnSessionList",@[]);
            if(!list) continue;
            unsigned long long total=0;
            for(id one in list) {
                if(![one isKindOfClass:NSString.class]) continue;
                unsigned long long n=0;
                if(UnreadForUser(one,&n)) total+=n;
            }
            return total;
        }
    } @catch (__unused NSException *e) {}
    return 0;
}
@interface WFFloat : NSObject
@property(nonatomic,strong) UIButton *button;
@property(nonatomic,strong) NSMutableArray<NSString*> *pending;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) NSMutableDictionary *arrivals;
@property(nonatomic,assign) CFTimeInterval flashStart;
- (void)reconcile;
@property(nonatomic,assign) CFTimeInterval lastInteraction;
@property(nonatomic,assign) CFTimeInterval hideUntil;
@property(nonatomic,assign) BOOL idleApplied;
@property(nonatomic,strong) UILabel *badge;
- (void)resumeTimer;
- (void)background;
- (void)foreground;
- (void)memoryWarning;
- (void)refresh;
- (void)wake;
- (void)apply;
+ (instancetype)shared;
- (void)attach;
- (void)message:(id)wrap;
@end
@implementation WFFloat
+ (instancetype)shared {static WFFloat *s; static dispatch_once_t once; dispatch_once(&once,^{s=[WFFloat new];s.pending=[NSMutableArray array];s.arrivals=[NSMutableDictionary dictionary];});return s;}
- (void)wake {self.lastInteraction=CACurrentMediaTime();self.idleApplied=NO;self.button.alpha=1;}
- (void)resumeTimer {
    if(self.timer || !Enabled() || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
    __weak WFFloat *weakSelf=self;
    self.timer=[NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t){[weakSelf reconcile];[weakSelf attach];}];
    self.timer.tolerance=.4;
}
- (void)reconcile {
    if(!self.pending.count)return;
    BOOL changed=NO;CFTimeInterval now=CACurrentMediaTime();
    UIViewController *top=Top();NSString *className=NSStringFromClass(top.class);
    NSString *active=nil;
    if([className containsString:@"BaseMsgContent"] || [className containsString:@"Chatting"]) {
        id c=Call(top,@"GetContact",@[])?:Call(top,@"m_contact",@[]);
        active=Text(c,@"m_nsUsrName");
    }
    id sessionMgr=Service(@"MMSessionMgr"),newSessionMgr=Service(@"MMNewSessionMgr");
    for(NSString *u in [self.pending copy]) {
        if(now-[self.arrivals[u] doubleValue]<1.0)continue;
        BOOL read=[active isEqualToString:u];BOOL known=NO;unsigned long long count=0;
        if(!read)for(id mgr in @[sessionMgr?:NSNull.null,newSessionMgr?:NSNull.null]) {
            if(mgr==NSNull.null)continue;id session=Call(mgr,@"GetSessionByUserName:",@[u]);
            if(!session)continue;
            if(UnreadCount(session,@"m_uUnReadCount",&count)){known=YES;read=count==0;break;}
        }
        if(read){[self.pending removeObject:u];[self.arrivals removeObjectForKey:u];ReadCleared++;changed=YES;}
        else if(!known)ReadUnknown++;
    }
    if(changed)[self refresh];
    if(self.pending.count && !ForeverFlash() && now-self.flashStart>=FlashSeconds()) [self.button.layer removeAnimationForKey:@"newMessage"];
}
- (void)background {
    [self.timer invalidate];self.timer=nil;
    [self.button.layer removeAnimationForKey:@"newMessage"];
    self.badge.hidden = YES;
    ClearImages();
}
- (void)foreground {
    ReloadStorage();IconLoaded=NO;
    RegisterSettings();if(!MessageHooked)InstallHook();[self reconcile];[self wake];[self attach];[self refresh];[self resumeTimer];
}
- (void)memoryWarning {ClearImages();Diagnostics=nil;GroupSignatures=nil;}
- (void)apply {
    if(!Enabled()) {
        [self.timer invalidate];self.timer=nil;[self.pending removeAllObjects];[self.arrivals removeAllObjects];
        [self.button.layer removeAnimationForKey:@"newMessage"];
        [self.button removeFromSuperview];
        [self.badge removeFromSuperview];
        return;
    }
    NSDictionary *p=ReadPrefs();CGFloat d=Diameter();
    CGRect frame=self.button.frame;frame.size=CGSizeMake(d,d);
    UIWindow *w=(id)self.button.superview;
    frame.origin.x=p[@"x"]?[p[@"x"] doubleValue]:(LeftHand()?14:(w?w.bounds.size.width:UIScreen.mainScreen.bounds.size.width)-d-14);
    frame.origin.y=p[@"y"]?[p[@"y"] doubleValue]:(w?w.bounds.size.height:UIScreen.mainScreen.bounds.size.height)*.55;
    self.button.frame=frame;self.button.layer.cornerRadius=d/2;
    [self wake];[self attach];[self refresh];[self resumeTimer];
}
- (void)attach {
    if(!ProtectedAvailable())return;
    if(!Enabled()) {
        [self.button removeFromSuperview];
        [self.badge removeFromSuperview];
        [self.pending removeAllObjects];
        return;
    }
    if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
    UIWindow *window=nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) if (w.isKeyWindow && w.windowLevel==UIWindowLevelNormal) {window=w;break;}
    if (!window) return;
    if (!self.button) {
        self.button=[UIButton buttonWithType:UIButtonTypeCustom];
        self.button.backgroundColor=[UIColor colorWithRed:0.05 green:0.68 blue:0.36 alpha:0.94];
        self.button.layer.cornerRadius=Diameter()/2; self.button.clipsToBounds=YES;
        self.button.layer.borderWidth=2; self.button.layer.borderColor=UIColor.whiteColor.CGColor;
        self.button.accessibilityLabel=@"便捷聊天浮窗";
        [self.button setTitle:@"聊" forState:UIControlStateNormal];
        [self.button addTarget:self action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];
        [self.button addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
        [self.button addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(hide:)]];
        NSDictionary *p=ReadPrefs();
        double x=p[@"x"]?[p[@"x"] doubleValue]:(LeftHand()?14:window.bounds.size.width-Diameter()-14);
        double y=p[@"y"]?[p[@"y"] doubleValue]:window.bounds.size.height*0.55;
        self.button.frame=CGRectMake(x,y,Diameter(),Diameter());[self wake];[self refresh];
    }
    if (self.button.superview!=window) [window addSubview:self.button];
    CGFloat left=window.safeAreaInsets.left+Diameter()/2,right=window.bounds.size.width-window.safeAreaInsets.right-Diameter()/2;
    CGFloat top=window.safeAreaInsets.top+Diameter()/2,bottom=window.bounds.size.height-window.safeAreaInsets.bottom-Diameter()/2;
    self.button.center=CGPointMake(MAX(left,MIN(right,self.button.center.x)),MAX(top,MIN(bottom,self.button.center.y)));
    self.button.hidden=CACurrentMediaTime()<self.hideUntil;
    id a=ReadPrefs()[@"idleAlpha"];CGFloat idle=a?MAX(.1,MIN(1,[a doubleValue])):.5;
    BOOL resting=CACurrentMediaTime()-self.lastInteraction>=5;
    CGFloat targetAlpha=self.pending.count || !resting?1:idle;
    if(fabs(self.button.alpha-targetAlpha)>.001)self.button.alpha=targetAlpha;
    if(StorageReady && resting && !self.idleApplied && !self.button.hidden && !self.pending.count) {
        self.idleApplied=YES;
        CGFloat edge=self.button.center.x<window.bounds.size.width/2?left:right;
        if(fabs(self.button.center.x-edge)>.5) {
            CGPoint dest=CGPointMake(edge,self.button.center.y);
            [UIView animateWithDuration:.25 animations:^{self.button.center=dest;}];
            NSMutableDictionary *p=Prefs();p[@"x"]=@(edge-Diameter()/2);p[@"y"]=@(dest.y-Diameter()/2);SavePrefs(p);
        }
    }
    if(window.subviews.lastObject!=self.button && window.subviews.lastObject!=self.badge)[window bringSubviewToFront:self.button];
    [self refresh];
}
- (void)pan:(UIPanGestureRecognizer*)g {
    [self wake];
    CGPoint d=[g translationInView:self.button.superview];
    self.button.center=CGPointMake(self.button.center.x+d.x,self.button.center.y+d.y); [g setTranslation:CGPointZero inView:self.button.superview];
    [self refreshBadge];
    if (g.state==UIGestureRecognizerStateEnded) {
        [self attach]; NSMutableDictionary *p=Prefs();
        p[@"x"]=@(self.button.frame.origin.x); p[@"y"]=@(self.button.frame.origin.y);
        if(!SavePrefs(p))Notice(@"浮窗位置无法保存，请反馈此提示。");
    }
}
- (void)hide:(UILongPressGestureRecognizer*)g {
    if(g.state!=UIGestureRecognizerStateBegan)return;
    [self wake];self.hideUntil=CACurrentMediaTime()+10;self.button.hidden=YES;
    if(self.badge) self.badge.hidden=YES;
}
- (void)tap {
    [self wake];
    if(self.pending.count) {
        NSString *user=self.pending.firstObject; [self.pending removeObjectAtIndex:0];[self.arrivals removeObjectForKey:user]; [self refresh]; OpenChat(user);
    } else {
        UIViewController *v=Top(); if (!v || [v isKindOfClass:WFContacts.class]) return;
        [v presentViewController:[[UINavigationController alloc] initWithRootViewController:[WFContacts new]] animated:YES completion:nil];
    }
}
- (void)refreshBadge {
    if(!self.button) return;
    unsigned long long total=[ReadPrefs()[@"buttonUnread"] boolValue]?TotalUnread():0;
    if(!total || self.button.hidden) {
        if(self.badge) self.badge.hidden=YES;
        return;
    }
    if(!self.badge) {
        self.badge=[[UILabel alloc] init];
        self.badge.textAlignment=NSTextAlignmentCenter;
        self.badge.font=[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        self.badge.textColor=UIColor.whiteColor;
        self.badge.backgroundColor=[UIColor systemRedColor];
        self.badge.layer.masksToBounds=YES;
        self.badge.userInteractionEnabled=NO;
    }
    self.badge.hidden=NO;
    self.badge.text=total>99?@"99+":[NSString stringWithFormat:@"%llu",total];
    [self.badge sizeToFit];
    CGFloat bh=18;
    CGFloat bw=MAX(18,self.badge.frame.size.width+10);
    self.badge.layer.cornerRadius=bh/2;
    UIWindow *w=self.button.window;
    if(w) {
        if(self.badge.superview!=w) [w addSubview:self.badge];
        CGRect bf=self.button.frame;
        self.badge.frame=CGRectMake(CGRectGetMaxX(bf)-bw+4, bf.origin.y-4, bw, bh);
        [w bringSubviewToFront:self.badge];
    } else {
        if(self.badge.superview!=self.button) [self.button addSubview:self.badge];
        CGFloat d=Diameter();
        self.badge.frame=CGRectMake(d-bw,-2,bw,bh);
    }
}
- (void)refresh {
    [self.button.layer removeAnimationForKey:@"newMessage"];[self refreshBadge];
    [self.button setImage:nil forState:UIControlStateNormal];
    [self.button setTitle:self.pending.count?@"新":@"聊" forState:UIControlStateNormal];
    if(!self.pending.count) {
        if(!IconLoaded && ProtectedAvailable()){
            id stored=ReadPrefs()[@"customIconPNG"];
            NSData *embedded=[stored isKindOfClass:NSData.class]?stored:nil;
            UIImage *loaded=embedded?[UIImage imageWithData:embedded]:nil;
            IconStatus=loaded?@"embedded configuration image loaded":@"no embedded image";
            if(!loaded && ![ReadPrefs()[@"iconMode"] isEqual:@"default"]){
                NSError *e=nil;NSData *data=[NSData dataWithContentsOfFile:IconPath() options:0 error:&e];
                loaded=data?[UIImage imageWithData:data]:nil;
                if(!loaded){data=[NSData dataWithContentsOfFile:[IconPath() stringByAppendingString:@".backup"] options:0 error:&e];loaded=data?[UIImage imageWithData:data]:nil;}
                if(loaded){
                    IconStatus=@"legacy image loaded";
                    NSData *png=UIImagePNGRepresentation(loaded);
                    if(png.length && png.length<=1024*1024 && StorageReady){NSMutableDictionary *p=Prefs();p[@"customIconPNG"]=png;if(SavePrefs(p))IconStatus=@"legacy image migrated into configuration";}
                }else IconStatus=[NSString stringWithFormat:@"image unavailable (error domain=%@ code=%ld)",e.domain?:@"decode",(long)e.code];
            }
            if(loaded){CustomIcon=loaded;IconLoaded=YES;}
            else if(!embedded && StorageReady)IconLoaded=YES;
        }
        UIImage *custom=CustomIcon;
        if(custom){[self.button setImage:custom forState:UIControlStateNormal];[self.button setTitle:nil forState:UIControlStateNormal];self.button.imageView.contentMode=UIViewContentModeScaleAspectFill;}
        [self refreshBadge];
        return;
    }
    [self wake];
    NSString *u=self.pending.firstObject;
    id image=Call(Service(@"CHeadImgMgr"),@"getHeadImage:withCategory:",@[u,@0]);
    if (![image isKindOfClass:UIImage.class]) image=Call(Contact(u),@"getContactHeadImage",@[]);
    AvatarStatus=[image isKindOfClass:UIImage.class]?@"image available":@"image unavailable; text flash fallback";
    [self refreshBadge];
    if([image isKindOfClass:UIImage.class]) { [self.button setImage:image forState:UIControlStateNormal]; [self.button setTitle:nil forState:UIControlStateNormal]; self.button.imageView.contentMode=UIViewContentModeScaleAspectFill; }
    else WFLog(@"Avatar adapter unavailable; using text fallback");
    if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive || !Enabled())return;
    self.flashStart=CACurrentMediaTime();
    CABasicAnimation *a=[CABasicAnimation animationWithKeyPath:@"opacity"]; a.fromValue=@1; a.toValue=@0.3; a.duration=0.65; a.autoreverses=YES; a.repeatCount=HUGE_VALF;if(!ForeverFlash()){a.duration=0.65;a.repeatDuration=FlashSeconds();}
    [self.button.layer addAnimation:a forKey:@"newMessage"];
}
- (void)message:(id)wrap {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self message:wrap];});return;}
    if(!Enabled())return;
    @try {
        NSString *from=Text(wrap,@"m_nsFromUsr");
        NSString *me=Text(Call(Service(@"CContactMgr"),@"getSelfContact",@[]),@"m_nsUsrName");
        MessageCallbacks++;
        if(!from.length) {MissingSender++;return;}
        if(!me.length) {MissingSelf++;WFLog(@"Self-contact unavailable; incoming message not queued");return;}
        if([from isEqualToString:me]){SelfMessages++;return;}
        id c=Contact(from);BOOL known=NO;
        if (!c || IsExcludedContact(c)) return;
        BOOL notify=ReadFlag(c,@"isChatStatusNotifyOpen",@[],&known);
        BOOL notifyKnown=known;
        if(known && !notify){MutedSkipped++;return;}
        
        // 折叠群过滤已被移除，所有群消息都会正常响应（包括虚拟“折叠的群聊”会话）
        if([from hasSuffix:@"@chatroom"] && !notifyKnown) {
            GroupStateUnknown++;
        }
        
        QueuedMessages++;
        if(![self.pending containsObject:from]) {if(self.pending.count>=50){[self.arrivals removeObjectForKey:self.pending.firstObject];[self.pending removeObjectAtIndex:0];}[self.pending addObject:from];}
        self.arrivals[from]=@(CACurrentMediaTime());
        if(UIApplication.sharedApplication.applicationState==UIApplicationStateActive){[self attach];[self refresh];}
        [NSNotificationCenter.defaultCenter postNotificationName:WFMessageArrivedNotification object:nil];
    } @catch (NSException *e) { WFLog(@"message: exception"); }
}
@end

@interface WFSettingsController : UITableViewController <UIImagePickerControllerDelegate,UINavigationControllerDelegate,UIDocumentPickerDelegate>
@end
@implementation WFSettingsController
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"便捷聊天浮窗";
    self.tableView.backgroundColor=UIColor.systemGroupedBackgroundColor;
    self.tableView.sectionHeaderTopPadding=12;
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
}
- (void)done {
    if(self.navigationController.presentingViewController)[self.navigationController dismissViewControllerAnimated:YES completion:nil];
    else [self.navigationController popViewControllerAnimated:YES];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView*)t {return 5;}
- (NSArray*)rowsForSection:(NSInteger)section {
    return @[@[@0],@[@9,@10],@[@1,@2,@3,@4,@5],@[@13,@14,@11,@12,@6,@7],@[@8]][section];
}
- (NSInteger)identifier:(NSIndexPath*)p {return [[self rowsForSection:p.section][p.row] integerValue];}
- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)section {return [self rowsForSection:section].count;}
- (NSString*)tableView:(UITableView*)t titleForHeaderInSection:(NSInteger)section {
    return @[@"启用",@"消息提醒",@"外观与布局",@"工具",@"关于"][section];
}
- (NSString*)tableView:(UITableView*)t titleForFooterInSection:(NSInteger)section {
    return @[@"仅在微信内显示。关闭后仍可从插件收纳页重新开启。",@"免打扰和折叠会话不提醒。限时到期只停止动画，不修改微信未读数。",@"空闲约5秒后自动贴边并淡化；有待提醒消息时保持正常亮度。长按浮窗可隐藏10秒。",@"接口诊断仅在手动复制时收集，不包含消息正文或联系人名单。",@"作者 Mocos · 不联网收集数据，不修改桌面角标。使用第三方插件仍有账号与兼容性风险。"][section];
}
- (CGFloat)tableView:(UITableView*)t heightForRowAtIndexPath:(NSIndexPath*)p {NSInteger row=[self identifier:p];return row==2 || row==3 || row==10?116:(row==8?70:60);}
- (void)save:(NSString*)key value:(id)value {
    NSMutableDictionary *p=Prefs();p[key]=value;
    if(!SavePrefs(p)){Notice(@"设置保存失败");return;}
    [[WFFloat shared] apply];
}
- (void)enabled:(UISwitch*)control {[self save:@"enabled" value:@(control.on)];}
- (void)left:(UISwitch*)control {
    NSMutableDictionary *p=Prefs();p[@"left"]=@(control.on);
    [p removeObjectForKey:@"x"];SavePrefs(p);[[WFFloat shared] apply];
}
- (void)unread:(UISwitch*)v {
    NSString *key=v.tag==13?@"listUnread":@"buttonUnread";
    if(!key)return;
    NSMutableDictionary *p=Prefs();p[key]=@(v.on);
    if(!SavePrefs(p)){Notice(@"设置保存失败");return;}
    [[WFFloat shared] apply];if(!v.on)[[WFFloat shared] refreshBadge];
}
- (void)forever:(UISwitch*)v {[self save:@"flashForever" value:@(v.on)];[self.tableView reloadData];}
- (void)slide:(UISlider*)control {
    if(control.tag==10){[self save:@"flashSeconds" value:@(round(control.value))];[self.tableView reloadData];return;}
    [self save:control.tag==2?@"size":@"idleAlpha" value:@(control.tag==2?round(control.value):control.value)];
    [self.tableView reloadData];
}
- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)p {
    NSInteger row=[self identifier:p];
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSArray *titles=@[@"启用浮窗",@"左手模式（关闭为右手）",@"浮窗直径",@"闲置5秒后的不透明度",@"从相册选择默认图片",@"恢复默认“聊”图标",@"重置浮窗位置",@"复制接口诊断",@"版本 1.0.4",@"持续闪烁直到已读",@"限时闪烁时长",@"手动备份配置",@"从文件恢复配置",@"联系人列表未读角标",@"浮窗未读总数角标"];
    cell.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;
    cell.textLabel.font=[UIFont systemFontOfSize:16];cell.textLabel.textColor=UIColor.labelColor;
    cell.detailTextLabel.font=[UIFont systemFontOfSize:12];cell.detailTextLabel.textColor=UIColor.secondaryLabelColor;
    cell.detailTextLabel.numberOfLines=2;
    cell.textLabel.text=titles[row];cell.selectionStyle=UITableViewCellSelectionStyleNone;
    if(row==13 || row==14){UISwitch *v=[UISwitch new];v.tag=row;v.on=[ReadPrefs()[row==13?@"listUnread":@"buttonUnread"] boolValue];[v addTarget:self action:@selector(unread:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=v;cell.detailTextLabel.text=row==13?@"仅在微信首页列表内显示当前会话未读数":@"显示全部会话未读总数；不含插件闪烁队列";}
    if(row<2){UISwitch *v=[UISwitch new];v.on=row==0?Enabled():LeftHand();[v addTarget:self action:row==0?@selector(enabled:):@selector(left:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=v;}
    if(row==9){UISwitch *v=[UISwitch new];v.on=ForeverFlash();[v addTarget:self action:@selector(forever:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=v;cell.detailTextLabel.text=@"关闭后使用3–60秒限时闪烁";}
    if(row==2 || row==3 || row==10){
        cell.textLabel.text=nil;cell.detailTextLabel.text=nil;
        UILabel *title=[UILabel new];title.font=[UIFont systemFontOfSize:16];title.text=titles[row];
        UILabel *value=[UILabel new];value.font=[UIFont systemFontOfSize:12];value.textColor=UIColor.secondaryLabelColor;value.numberOfLines=2;
        UISlider *slider=[UISlider new];slider.tag=row;
        slider.minimumValue=row==10?3:(row==2?20:.1);slider.maximumValue=row==10?60:(row==2?80:1);
        slider.value=row==10?FlashSeconds():(row==2?Diameter():(ReadPrefs()[@"idleAlpha"]?[ReadPrefs()[@"idleAlpha"] floatValue]:.5));
        value.text=row==2?[NSString stringWithFormat:@"%.0f pt（20–80）",slider.value]:[NSString stringWithFormat:@"%.0f%% · 新消息提醒保持正常亮度",slider.value*100];
        if(row==10){value.text=[NSString stringWithFormat:@"%.0f秒 · 到期仅停止动画，保留头像入口",slider.value];slider.enabled=!ForeverFlash();}
        for(UIView *view in @[title,value,slider]){view.translatesAutoresizingMaskIntoConstraints=NO;[cell.contentView addSubview:view];}
        [NSLayoutConstraint activateConstraints:@[
            [title.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [title.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
            [title.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
            [value.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
            [value.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
            [value.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:5],
            [value.bottomAnchor constraintLessThanOrEqualToAnchor:slider.topAnchor constant:-4],
            [slider.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
            [slider.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
            [slider.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-12],
            [slider.heightAnchor constraintEqualToConstant:30]
        ]];
        [slider addTarget:self action:@selector(slide:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside];
    }
    if(row==4 || row==5 || row==6 || row==7 || row==11 || row==12 || row==13 || row==14){cell.textLabel.textColor=UIColor.systemBlueColor;cell.selectionStyle=UITableViewCellSelectionStyleDefault;}
    if(row==11)cell.detailTextLabel.text=@"包含图标，可保存到文件或由Filza/Fila管理";
    if(row==12)cell.detailTextLabel.text=@"校验文件后确认恢复；兼容旧settings.plist";
    if(row==4)cell.detailTextLabel.text=@"仅替换空闲图标；消息仍显示发信人头像";
    if(row==8){cell.detailTextLabel.text=@"Mocos · 微信 8.0.54";cell.detailTextLabel.numberOfLines=2;}
    return cell;
}
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)p {
    NSInteger row=[self identifier:p];[t deselectRowAtIndexPath:p animated:YES];
    if(row==11){[self exportConfiguration];return;}
    if(row==12){[self importConfiguration];return;}
    if(row==4){
        if(![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]){Notice(@"相册暂不可用");return;}
        UIImagePickerController *picker=[UIImagePickerController new];picker.sourceType=UIImagePickerControllerSourceTypePhotoLibrary;picker.delegate=self;
        [self presentViewController:picker animated:YES completion:nil];
    }else if(row==5){
        NSMutableDictionary *p=Prefs();[p removeObjectForKey:@"customIconPNG"];p[@"iconMode"]=@"default";
        if(!SavePrefsReason(p,@"reset icon",YES)){Notice(@"存储不可用，未恢复默认图标，请解锁后重试。");return;}
        [NSFileManager.defaultManager removeItemAtPath:IconPath() error:nil];
        [NSFileManager.defaultManager removeItemAtPath:[IconPath() stringByAppendingString:@".backup"] error:nil];
        IconStatus=@"reset by user";ClearImages();[[WFFloat shared] apply];
    }
    else if(row==6){NSMutableDictionary *v=Prefs();[v removeObjectForKey:@"x"];[v removeObjectForKey:@"y"];SavePrefs(v);[[WFFloat shared] apply];}
    else if(row==7){
        LoadContactsInternal(YES);UIPasteboard.generalPasteboard.string=[NSString stringWithFormat:@"%@\nMessage hook=%@ callbacks=%lu queued=%lu missingSender=%lu missingSelf=%lu selfMessages=%lu avatar=%@\nmutedSkipped=%lu foldedSkipped=%lu stateUnknown=%lu\n%@",Diagnostics,MessageHooked?@"installed":@"missing",(unsigned long)MessageCallbacks,(unsigned long)QueuedMessages,(unsigned long)MissingSender,(unsigned long)MissingSelf,(unsigned long)SelfMessages,AvatarStatus,(unsigned long)MutedSkipped,(unsigned long)FoldedSkipped,(unsigned long)GroupStateUnknown,GroupSignatures?:@"Group flags checked via typed accessors"];
        UIPasteboard.generalPasteboard.string=[UIPasteboard.generalPasteboard.string stringByAppendingFormat:@"\nRead cleared=%lu unknownChecks=%lu\nApp badge API is not modified by this tweak",(unsigned long)ReadCleared,(unsigned long)ReadUnknown];
        UIPasteboard.generalPasteboard.string=[UIPasteboard.generalPasteboard.string stringByAppendingFormat:@"\nStorage: %@; protectedAvailable=%@; primary=%@; backup=%@; icon=%@; pid=%d",StorageStatus,ProtectedAvailable()?@"yes":@"no",[NSFileManager.defaultManager fileExistsAtPath:PrefsPath()]?@"yes":@"no",[NSFileManager.defaultManager fileExistsAtPath:BackupPath()]?@"yes":@"no",[NSFileManager.defaultManager fileExistsAtPath:IconPath()]?@"yes":@"no",getpid()];
        id embedded=ReadPrefs()[@"customIconPNG"];
        UIPasteboard.generalPasteboard.string=[UIPasteboard.generalPasteboard.string stringByAppendingFormat:@"\nImage: %@; embeddedBytes=%lu; fileBackup=%@",IconStatus,(unsigned long)([embedded isKindOfClass:NSData.class]?[embedded length]:0),[NSFileManager.defaultManager fileExistsAtPath:[IconPath() stringByAppendingString:@".backup"]]?@"yes":@"no"];
        UIPasteboard.generalPasteboard.string=[UIPasteboard.generalPasteboard.string stringByAppendingFormat:@"\nSchema=3 revision=%@ reason=%@ v3Primary=%@ v3Mirror=%@ prefs=%@",CurrentState[@"revision"]?:@0,CurrentState[@"reason"]?:@"none",[NSFileManager.defaultManager fileExistsAtPath:StatePath()]?@"yes":@"no",[NSFileManager.defaultManager fileExistsAtPath:StateBackup()]?@"yes":@"no",[NSUserDefaults.standardUserDefaults dictionaryForKey:StateKey]?@"yes":@"no"];
        Notice(@"诊断已复制，不含消息正文或联系人名单。");
    }
}
- (void)exportConfiguration {
    if(!ProtectedAvailable() || !StorageReady){Notice(@"配置尚未安全加载，不能导出。请解锁后重试。");return;}
    NSDictionary *p=ReadPrefs();
    NSMutableDictionary *values=[CleanSettings(p) mutableCopy];
    for(NSString *k in @[@"x",@"y"])if(p[k])values[k]=p[k];
    NSDictionary *document=@{@"format":@"Mocos.WeChatFloat.Backup",@"version":@1,@"settings":values,@"createdAt":[NSDate date]};
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:document format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    NSString *name=[NSString stringWithFormat:@"WeChatFloat-backup-%lld.plist",(long long)NSDate.date.timeIntervalSince1970];
    NSURL *url=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    if(![data writeToURL:url options:NSDataWritingAtomic error:nil]){Notice(@"备份文件生成失败。");return;}
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForExportingURLs:@[url] asCopy:YES];
    picker.delegate=self;[self presentViewController:picker animated:YES completion:nil];
}
- (void)importConfiguration {
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"com.apple.property-list",@"public.data"] inMode:UIDocumentPickerModeImport];
    picker.delegate=self;[self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    if(controller.documentPickerMode!=UIDocumentPickerModeImport)return;
    NSURL *url=urls.firstObject;if(!url)return;
    BOOL scoped=[url startAccessingSecurityScopedResource];
    NSNumber *bytes=nil;[url getResourceValue:&bytes forKey:NSURLFileSizeKey error:nil];
    NSData *data=bytes && bytes.unsignedLongLongValue<=2*1024*1024?[NSData dataWithContentsOfURL:url options:0 error:nil]:nil;
    if(scoped)[url stopAccessingSecurityScopedResource];
    id doc=data?[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil]:nil;
    NSDictionary *source=nil;
    if([doc isKindOfClass:NSDictionary.class] && [doc[@"format"] isEqual:@"Mocos.WeChatFloat.Backup"] && [doc[@"version"] isEqual:@1])source=doc[@"settings"];
    else if([doc isKindOfClass:NSDictionary.class] && !doc[@"format"])source=doc;
    NSMutableDictionary *clean=[CleanSettings(source) mutableCopy];
    if(!clean.count){Notice(@"无效或不兼容的配置文件（最大2MiB，图片最大1MiB）。未修改当前设置。");return;}
    for(NSString *k in @[@"x",@"y"]){id n=source[k];if([n isKindOfClass:NSNumber.class] && isfinite([n doubleValue]))clean[k]=n;}
    if(!clean[@"customIconPNG"])clean[@"iconMode"]=@"default";
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"恢复配置？" message:@"将覆盖当前设置和自定义图标。恢复前会尝试在本地保留一份当前配置；建议先手动导出备份。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"恢复" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){
        NSDictionary *before=@{@"format":@"Mocos.WeChatFloat.Backup",@"version":@1,@"settings":ReadPrefs()};
        NSData *old=[NSPropertyListSerialization dataWithPropertyList:before format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        if(EnsureDirectory())WriteData(old,[StorageDirectory() stringByAppendingPathComponent:@"before-manual-restore.plist"]);
        StorageReady=ProtectedAvailable();
        NSMutableDictionary *merged=[Defaults() mutableCopy];[merged addEntriesFromDictionary:clean];
        if(!SavePrefsReason(merged,@"manual restore",YES)){Notice(@"恢复未能完整保存，请解锁后重试，并保留原备份文件。");return;}
        ClearImages();[[WFFloat shared] apply];[self.tableView reloadData];Notice(@"配置已恢复。未改动微信消息或未读状态。");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)controller {}

- (void)imagePickerControllerDidCancel:(UIImagePickerController*)picker {[picker dismissViewControllerAnimated:YES completion:nil];}
- (void)imagePickerController:(UIImagePickerController*)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id>*)info {
    UIImage *img=info[UIImagePickerControllerOriginalImage];
    BOOL ok=NO;
    if(img){
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(256,256),NO,1);
        CGFloat scale=MAX(256/img.size.width,256/img.size.height);CGSize sz=CGSizeMake(img.size.width*scale,img.size.height*scale);
        [img drawInRect:CGRectMake((256-sz.width)/2,(256-sz.height)/2,sz.width,sz.height)];
        UIImage *small=UIGraphicsGetImageFromCurrentImageContext();UIGraphicsEndImageContext();
        NSData *data=UIImagePNGRepresentation(small);
        if(data.length && data.length<=1024*1024){
            NSMutableDictionary *p=Prefs();p[@"customIconPNG"]=data;p[@"iconMode"]=@"custom";
            ok=SavePrefsReason(p,@"select icon",NO);
            if(ok){
                NSData *snapshot=[NSPropertyListSerialization dataWithPropertyList:p format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
                BOOL backed=YES;
                BOOL fileSaved=WriteData(data,IconPath());
                BOOL fileBacked=WriteData(data,[IconPath() stringByAppendingString:@".backup"]);
                IconStatus=[NSString stringWithFormat:@"embedded saved; configBackup=%@ file=%@ fileBackup=%@",backed?@"yes":@"no",fileSaved?@"yes":@"no",fileBacked?@"yes":@"no"];
            }
        }
    }
    [picker dismissViewControllerAnimated:YES completion:^{if(ok){ClearImages();[[WFFloat shared] apply];}else Notice(@"图片保存失败，请重新选择。");}];
}
@end
static void Settings(void) {
    UIViewController *v=Top();if(!v)return;
    [v presentViewController:[[UINavigationController alloc] initWithRootViewController:[WFSettingsController new]] animated:YES completion:nil];
}
static void RegisterSettings(void) {
    if(SettingsRegistered)return;
    id mgr=Call(NSClassFromString(@"WCPluginsMgr"),@"sharedInstance",@[]);
    NSString *name=@"registerControllerWithTitle:version:controller:";
    NSMethodSignature *sig=[mgr methodSignatureForSelector:NSSelectorFromString(name)];
    if(!sig || sig.numberOfArguments!=5 || *sig.methodReturnType!='v')return;
    for(NSUInteger i=2;i<5;i++)if(*[sig getArgumentTypeAtIndex:i]!='@')return;
    Call(mgr,name,@[@"便捷聊天浮窗",@"1.0.4",@"WFSettingsController"]);SettingsRegistered=YES;
}

static IMP originalAddMessage=NULL;
static void HookAddMessage(id self,SEL sel,id user,id wrap) {
    if(originalAddMessage)((void(*)(id,SEL,id,id))originalAddMessage)(self,sel,user,wrap);
    @try { [[WFFloat shared] message:wrap]; } @catch (NSException *e){ WFLog(@"Message observer exception"); }
}
static BOOL InstallHook(void) {
    if(MessageHooked)return YES;
    Class c=NSClassFromString(@"CMessageMgr"); SEL s=NSSelectorFromString(@"AsyncOnAddMsg:MsgWrap:");
    Method m=class_getInstanceMethod(c,s); if(!m)return NO;
    NSMethodSignature *sig=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)];
    if(sig.numberOfArguments!=4 || strcmp(sig.methodReturnType,"v") || *[sig getArgumentTypeAtIndex:2]!='@' || *[sig getArgumentTypeAtIndex:3]!='@') {WFLog(@"Message hook signature mismatch");return NO;}
    IMP previous=method_getImplementation(m);
    if(class_addMethod(c,s,(IMP)HookAddMessage,method_getTypeEncoding(m))) originalAddMessage=previous;
    else originalAddMessage=method_setImplementation(m,(IMP)HookAddMessage);
    MessageHooked=YES; WFLog(@"Message observer installed");return YES;
}
__attribute__((constructor)) static void WFStart(void) {
    @autoreleasepool {
        if(![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.tencent.xin"])return;
        dispatch_async(dispatch_get_main_queue(),^{
            WFLog(@"WeChatFloat 1.0.4 loaded");
            WFFloat *f=[WFFloat shared];NSNotificationCenter *nc=NSNotificationCenter.defaultCenter;
            [nc addObserver:f selector:@selector(background) name:UIApplicationDidEnterBackgroundNotification object:nil];
            [nc addObserver:f selector:@selector(foreground) name:UIApplicationDidBecomeActiveNotification object:nil];
            [nc addObserver:f selector:@selector(foreground) name:UIApplicationProtectedDataDidBecomeAvailable object:nil];
            [nc addObserver:f selector:@selector(background) name:UIApplicationProtectedDataWillBecomeUnavailable object:nil];
            [nc addObserver:f selector:@selector(memoryWarning) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
            [f foreground];
            __block NSUInteger tries=0;__block BOOL hooked=InstallHook();
            NSTimer *setup=[NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t){
                if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive){[t invalidate];return;}
                RegisterSettings();if(!hooked)hooked=InstallHook();
                if((hooked && SettingsRegistered) || ++tries>=60)[t invalidate];
            }];setup.tolerance=.5;
        });
    }
}
