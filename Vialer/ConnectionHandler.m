//
//  ConnectionHandler.m
//  Vialer
//
//  Created by Reinier Wieringa on 19/12/14.
//  Copyright (c) 2014 VoIPGRID. All rights reserved.
//

#import "ConnectionHandler.h"
#import "AppDelegate.h"
#import "Gossip+Extra.h"
#import "PJSIP.h"

#import "AFNetworkReachabilityManager.h"
#import <CoreTelephony/CTTelephonyNetworkInfo.h>

NSString * const ConnectionStatusChangedNotification = @"com.vialer.ConnectionStatusChangedNotification";
NSString * const IncomingSIPCallNotification = @"com.vialer.IncomingSIPCallNotification";

NSString * const NotificationAcceptDeclineCategory = @"com.vialer.notification.accept.decline.category";
NSString * const NotificationActionDecline = @"com.vialer.notification.decline";
NSString * const NotificationActionAccept = @"com.vialer.notification.accept";

@interface ConnectionHandler ()
@property (nonatomic, assign) BOOL isOnWiFi;
@property (nonatomic, assign) BOOL isOn4G;
@property (nonatomic, strong) GSAccountConfiguration *account;
@property (nonatomic, strong) GSConfiguration *config;
@property (nonatomic, strong) GSUserAgent *userAgent;
@property (nonatomic, strong) GSCall *lastNotifiedCall;
@end

@implementation ConnectionHandler

static pj_thread_desc a_thread_desc;
static pj_thread_t *a_thread;

+ (ConnectionHandler *)sharedConnectionHandler {
    static dispatch_once_t pred;
    static ConnectionHandler *_sharedConnectionHandler = nil;

    dispatch_once(&pred, ^{
        _sharedConnectionHandler = [[self alloc] init];
    });
    return _sharedConnectionHandler;
}

- (id)init {
    self = [super init];
    if (self != nil) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didBecomeActiveNotification:) name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}

- (void)connectionStatusChanged {
    [self sipUpdateConnectionStatus];
    [[NSNotificationCenter defaultCenter] postNotificationName:ConnectionStatusChangedNotification object:self];
}

- (ConnectionStatus)connectionStatus {
    return (self.isOn4G || self.isOnWiFi) ? ConnectionStatusHigh : ConnectionStatusLow;
}

- (GSAccountStatus)accountStatus {
    GSAccount *account = [GSUserAgent sharedAgent].account;
    GSAccountStatus status = GSAccountStatusInvalid;
    if (account) {
        status = account.status;
    }
    return status;
}

- (void)start {
    // Check if radio access is at least 4G
    __block NSString *highNetworkTechnology = CTRadioAccessTechnologyLTE; // 4G
//    __block NSString *highNetworkTechnology = CTRadioAccessTechnologyWCDMA; // 3G

    CTTelephonyNetworkInfo *telephonyInfo = [[CTTelephonyNetworkInfo alloc] init];
    self.isOn4G = [telephonyInfo.currentRadioAccessTechnology isEqualToString:highNetworkTechnology];
    [[NSNotificationCenter defaultCenter] addObserverForName:CTRadioAccessTechnologyDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *notification) {
        BOOL isOn4G = [notification.object isEqualToString:highNetworkTechnology];
        if (self.isOn4G != isOn4G) {
            self.isOn4G = isOn4G;
            [self connectionStatusChanged];
        }
    }];

    // Check WiFi or no WiFi
    self.isOnWiFi = [AFNetworkReachabilityManager sharedManager].reachableViaWiFi;
    [[AFNetworkReachabilityManager sharedManager] setReachabilityStatusChangeBlock:^(AFNetworkReachabilityStatus status) {
        BOOL isOnWiFi = (status == AFNetworkReachabilityStatusReachableViaWiFi);
        if (self.isOnWiFi != isOnWiFi) {
            self.isOnWiFi = isOnWiFi;
            [self connectionStatusChanged];
        }
    }];
}

- (void)sipConnect {
    [self sipDisconnect:^{
        if (![[NSUserDefaults standardUserDefaults] objectForKey:@"SIPAccount"] || ![[NSUserDefaults standardUserDefaults] objectForKey:@"SIPPassword"]) {
            return;
        }

        if (!self.account) {
            self.account = [GSAccountConfiguration defaultConfiguration];
            self.account.domain = self.sipDomain;
            self.account.username = [[NSUserDefaults standardUserDefaults] objectForKey:@"SIPAccount"];
            self.account.password = [[NSUserDefaults standardUserDefaults] objectForKey:@"SIPPassword"];    // TODO: In key chain
            self.account.address = [self.account.username stringByAppendingFormat:@"@%@", self.account.domain];
        }

        if (!self.config) {
            self.config = [GSConfiguration defaultConfiguration];
            self.config.account = self.account;
            self.config.logLevel = 3;
            self.config.consoleLogLevel = 3;
        }

        if (!self.userAgent) {
            self.userAgent = [GSUserAgent sharedAgent];

            [self.userAgent configure:self.config];
            [self.userAgent start];

            [self.userAgent.account addObserver:self
                                     forKeyPath:@"status"
                                        options:NSKeyValueObservingOptionInitial
                                        context:nil];
        }

        self.userAgent.account.delegate = self;

        if (self.userAgent.account.status == GSAccountStatusOffline) {
            [self.userAgent.account connect];
        }
    }];
}

- (void)sipDisconnect:(void (^)())finished {
    BOOL shouldFinish = YES;
    if (self.userAgent.account.status == GSAccountStatusConnected) {
        [self.userAgent.account disconnect:finished];
        shouldFinish = NO;
    }

    self.userAgent.account.delegate = nil;
    [self.userAgent.account removeObserver:self forKeyPath:@"status"];
    [self.userAgent reset];

    self.userAgent = nil;
    self.account = nil;
    self.config = nil;

    if (shouldFinish && finished) {
        finished();
    }
}

- (void)sipUpdateConnectionStatus {
    if (self.connectionStatus == ConnectionStatusHigh) {
        // Only connect if we're not already connect(ed/ing)
        if (self.accountStatus != GSAccountStatusConnected && self.accountStatus != GSAccountStatusConnecting) {
            [self sipConnect];
        }
    } else if ([[GSCall activeCalls] count] == 0) {
        // Only disconnect if no active calls are being made
        [self sipDisconnect:nil];
    }
}

- (void)handleKeepAlive {
    if (!pj_thread_is_registered()) {
        pj_thread_register("ipjsua", a_thread_desc, &a_thread);
    }

    for (int i = 0; i < (int)pjsua_acc_get_count(); ++i) {
        NSLog(@"Keep account %d alive", i);
        if (pjsua_acc_is_valid(i)) {
            pjsua_acc_set_registration(i, PJ_TRUE);
        }
    }
}

- (NSString *)sipDomain {
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"Config" ofType:@"plist"]];
    NSAssert(config != nil, @"Config.plist not found!");

    NSString *sipDomain = [[config objectForKey:@"URLS"] objectForKey:@"SIP domain"];
    NSAssert(sipDomain != nil, @"URLS - SIP domain not found in Config.plist!");

    return sipDomain;
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if ([keyPath isEqualToString:@"status"]) {
        if ([object isKindOfClass:[GSAccount class]]) {
            [self accountStatusDidChange:object];
        } else {
            [self callStatusDidChange];
        }
    }
}

- (void)accountStatusDidChange:(GSAccount *)account {
    switch (account.status) {
        case GSAccountStatusOffline: {
        } break;

        case GSAccountStatusInvalid: {
        } break;

        case GSAccountStatusConnecting: {
        } break;

        case GSAccountStatusConnected: {
            [self setCodecs];
            [self connectionStatusChanged];
        } break;

        case GSAccountStatusDisconnecting: {
        } break;
    }
}

- (void)callStatusDidChange {
    if (self.lastNotifiedCall.status == GSCallStatusDisconnected) {
        [self clearLastNotifiedCall];
    }
}

- (void)setCodecs {
    if (self.userAgent.status >= GSUserAgentStateConfigured) {
        NSArray *codecs = [self.userAgent arrayOfAvailableCodecs];
        for (GSCodecInfo *codec in codecs) {
            if ([codec.codecId isEqual:@"PCMA/8000/1"]) {
                [codec setPriority:254];
            }
        }
    }
}

#pragma mark - Notifications

- (void)didBecomeActiveNotification:(NSNotification *)notification {
    if (self.lastNotifiedCall) {
        AppDelegate *appDelegate = ((AppDelegate *)[UIApplication sharedApplication].delegate);
        [appDelegate handleSipCall:self.lastNotifiedCall];
    }
    [self clearLastNotifiedCall];
}

- (void)handleLocalNotification:(UILocalNotification *)notification withActionIdentifier:(NSString *)identifier {
    if (self.lastNotifiedCall) {
        NSDictionary *userInfo = notification.userInfo;
        NSNumber *callId = [userInfo objectForKey:@"callId"];
        if ([callId isKindOfClass:[NSNumber class]] && self.lastNotifiedCall.callId == [callId intValue] && self.lastNotifiedCall.status != GSCallStatusDisconnected) {
            if ([identifier isEqualToString:NotificationActionDecline]) {
                [self.lastNotifiedCall end];
            } else {
                AppDelegate *appDelegate = ((AppDelegate *)[UIApplication sharedApplication].delegate);
                [appDelegate handleSipCall:self.lastNotifiedCall];
            }
        }

        [self clearLastNotifiedCall];
    }
}

- (void)registerForLocalNotifications {
    UIApplication *application = [UIApplication sharedApplication];

    if ([application respondsToSelector:@selector(registerUserNotificationSettings:)]) {
        UIMutableUserNotificationAction *declineAction = [[UIMutableUserNotificationAction alloc] init];
        [declineAction setActivationMode:UIUserNotificationActivationModeBackground];
        [declineAction setTitle:NSLocalizedString(@"Decline", nil)];
        [declineAction setIdentifier:NotificationActionDecline];

        UIMutableUserNotificationAction *acceptAction = [[UIMutableUserNotificationAction alloc] init];
        [acceptAction setActivationMode:UIUserNotificationActivationModeForeground];
        [acceptAction setTitle:NSLocalizedString(@"Accept", nil)];
        [acceptAction setIdentifier:NotificationActionAccept];

        UIMutableUserNotificationCategory *actionCategory = [[UIMutableUserNotificationCategory alloc] init];
        [actionCategory setIdentifier:NotificationAcceptDeclineCategory];
        [actionCategory setActions:@[acceptAction, declineAction]
                        forContext:UIUserNotificationActionContextDefault];

        UIUserNotificationSettings *settings = [UIUserNotificationSettings settingsForTypes:(UIUserNotificationTypeAlert | UIUserNotificationTypeSound | UIUserNotificationTypeBadge)
                                                                                 categories:[NSSet setWithObject:actionCategory]];
        [application registerUserNotificationSettings:settings];
    } else {
        [application registerForRemoteNotificationTypes:(UIRemoteNotificationTypeBadge | UIRemoteNotificationTypeAlert | UIRemoteNotificationTypeSound)];
    }
}

- (void)clearLastNotifiedCall {
    [self.lastNotifiedCall removeObserver:self forKeyPath:@"status"];
    self.lastNotifiedCall = nil;
    [[UIApplication sharedApplication] cancelAllLocalNotifications];
}

#pragma mark - GSAccount delegate

- (void)account:(GSAccount *)account didReceiveIncomingCall:(GSCall *)call {
    NSLog(@"Received incoming call");
    UIApplicationState state = [[UIApplication sharedApplication] applicationState];
    if (state == UIApplicationStateActive) {
        [[NSNotificationCenter defaultCenter] postNotificationName:IncomingSIPCallNotification object:call];
    } else {
        UILocalNotification *notification = [[UILocalNotification alloc] init];
        notification.alertBody = [NSString stringWithFormat:NSLocalizedString(@"Incoming call from %@", nil), call.remoteInfo];
        notification.soundName = @"incoming.caf";
        notification.userInfo = @{@"callId":@(call.callId)};

        if ([notification respondsToSelector:@selector(setCategory:)]) {
            notification.category = NotificationAcceptDeclineCategory;
        }

        self.lastNotifiedCall = call;

        [self.lastNotifiedCall addObserver:self
                                forKeyPath:@"status"
                                   options:NSKeyValueObservingOptionInitial
                                   context:nil];

        [[UIApplication sharedApplication] presentLocalNotificationNow:notification];
    }
}

@end
