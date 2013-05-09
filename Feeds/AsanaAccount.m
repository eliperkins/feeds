//
//  AsanaAccount.m
//  Feeds
//
//  Created by Eli Perkins on 5/9/13.
//  Copyright (c) 2013 Spotlight Mobile. All rights reserved.
//

#import "AsanaAccount.h"

#define ASANA_OAUTH_KEY @"5383804526414"
#define ASANA_OAUTH_SECRET @"39965bc5a02d371874e3de43e722efa5"
#define ASANA_REDIRECT @"http%3A%2F%2Ffrozen-forest-2069.herokuapp.com%2Fauth"

@implementation AsanaAccount

+ (void)load { [Account registerClass:self]; }
+ (BOOL)requiresAuth { return YES; }
+ (BOOL)requiresDomain { return NO; }
+ (BOOL)requiresUsername { return NO; }
+ (BOOL)requiresPassword { return NO; }
+ (NSTimeInterval)defaultRefreshInterval { return 5*60; } // 5 minutes

- (void)beginAuth {
    NSURL *URL = [NSURL URLWithString:[NSString stringWithFormat:@"https://app.asana.com/-/oauth_authorize?client_id=%@&redirect_uri=%@&response_type=code", ASANA_OAUTH_KEY, ASANA_REDIRECT]];

    [[NSWorkspace sharedWorkspace] openURL:URL];
}

- (void)authWasFinishedWithURL:(NSURL *)url {
    DDLogInfo(@"GOT URL: %@", url);
    
    NSString *query = [url query]; // code=xyz
    
    if (![query beginsWithString:@"code="]) {
        
        NSString *message = @"There was an error while authenticating with Asana. If this continues to persist, please choose \"Report a Problem\" from the Feeds status bar icon.";
        
        if ([query isEqualToString:@"error=access_denied"])
            message = @"Authorization was denied. Please try again.";
        
        [self.delegate account:self validationDidFailWithMessage:message field:AccountFailingFieldAuth];
        return;
    }
    
    NSArray *parts = [query componentsSeparatedByString:@"="];
    NSString *code = parts[1]; // xyz
    
    NSURL *URL = [NSURL URLWithString:[NSString stringWithFormat:@"https://app.asana.com/-/oauth_token?grant_type=authorization_code&client_id=%@&client_secret=%@&redirect_uri=%@&code=%@",ASANA_OAUTH_KEY,ASANA_OAUTH_SECRET,ASANA_REDIRECT,code]];
    
    NSMutableURLRequest *URLRequest = [NSMutableURLRequest requestWithURL:URL];
    URLRequest.HTTPMethod = @"POST";
    
    self.request = [SMWebRequest requestWithURLRequest:URLRequest delegate:nil context:NULL];
    [self.request addTarget:self action:@selector(tokenRequestComplete:) forRequestEvents:SMWebRequestEventComplete];
    [self.request addTarget:self action:@selector(tokenRequestError:) forRequestEvents:SMWebRequestEventError];
    [self.request start];
}

- (void)tokenRequestComplete:(NSData *)data {
    
    NSString *error = nil;
    OAuth2Token *token = [[OAuth2Token alloc] initWithTokenResponse:data error:&error];
    
    if (token) {
        [self validateWithPassword:token.stringRepresentation];
    }
    else {
        NSString *message = [NSString stringWithFormat:@"There was an error while authenticating with Asana: \"%@\"", error];
        [self.delegate account:self validationDidFailWithMessage:message field:AccountFailingFieldAuth];
    }
}

- (void)tokenRequestError:(NSError *)error {
    [self.delegate account:self validationDidFailWithMessage:@"There was an error while authenticating with Asana. If this continues to persist, please choose \"Report a Problem\" from the Feeds status bar icon." field:AccountFailingFieldAuth];
}

- (void)validateWithPassword:(NSString *)password {
    
    NSString *URL = @"https://app.asana.com/api/1.0/users/me";
    OAuth2Token *token = [OAuth2Token tokenWithStringRepresentation:password];
    
    NSURLRequest *URLRequest = [NSURLRequest requestWithURLString:URL OAuth2Token:token];
    
    self.request = [SMWebRequest requestWithURLRequest:URLRequest delegate:nil context:password];
    [self.request addTarget:self action:@selector(meRequestComplete:context:) forRequestEvents:SMWebRequestEventComplete];
    [self.request addTarget:self action:@selector(handleGenericError:) forRequestEvents:SMWebRequestEventError];
    [self.request start];
}

- (void)meRequestComplete:(NSData *)data context:(NSString *)token {
    
    NSDictionary *me = [data objectFromJSONData][@"data"];
    
    NSString *author = [me[@"id"] stringValue];

    self.username = me[@"name"];
    
    NSArray *workspaces = me[@"workspaces"];
    
    NSMutableArray *foundFeeds = [NSMutableArray array];

    for (NSDictionary *workspace in workspaces) {
        NSString *workspaceName = workspace[@"name"];
        NSString *workspaceIdentifier = [workspace[@"id"] stringValue];
        NSString *workspaceFeedString = [NSString stringWithFormat:@"https://app.asana.com/api/1.0/workspaces/%@", workspaceIdentifier];
        
        Feed *feed = [Feed feedWithURLString:workspaceFeedString title:workspaceName author:author account:self];
        feed.incremental = YES;
        feed.requiresOAuth2Token = YES;
        [foundFeeds addObject:feed];
    }
    
    self.feeds = foundFeeds;
    
    [self.delegate account:self validationDidCompleteWithNewPassword:token];
}

- (void)meRequestError:(NSError *)error {
    [self.delegate account:self validationDidFailWithMessage:error.localizedDescription field:AccountFailingFieldUnknown];
}

- (void)handleGenericError:(NSError *)error {
    [self.delegate account:self validationDidFailWithMessage:@"Could not retrieve information about the given Basecamp account. If this continues to persist, please choose \"Report a Problem\" from the Feeds status bar icon." field:0];
}

#pragma mark Refreshing Feeds and Tokens

- (void)actualRefreshFeeds {
    for (Feed *feed in self.enabledFeeds) {
        
        NSURL *URL = feed.URL;
        
        // if the feed has items already, append since= to the URL so we only get new ones.
        FeedItem *latestItem = feed.items.firstObject;
        
        if (latestItem) {
            NSDateFormatter *formatter = [NSDateFormatter new];
            [formatter setDateFormat:@"yyyy'-'MM'-'dd'T'HH':'mm':'ssZ"];
            [formatter setTimeZone:[NSTimeZone timeZoneWithName:@"America/Chicago"]];
            NSString *chicagoDate = [formatter stringFromDate:latestItem.published];
            
            URL = [NSURL URLWithString:[NSString stringWithFormat:@"%@?since=%@",URL.absoluteString,chicagoDate]];
        }
        
        [feed refreshWithURL:URL];
    }
}

- (void)refreshFeeds:(NSArray *)feedsToRefresh {
    
    if (([NSDate timeIntervalSinceReferenceDate] - self.lastTokenRefresh.timeIntervalSinceReferenceDate) > 60*60*24) { // refresh token at least every 24 hours
        
        // refresh our access_token first.
        DDLogInfo(@"Refresh token for %@", self);
        
        NSString *password = self.findPassword;
        OAuth2Token *token = [OAuth2Token tokenWithStringRepresentation:password];
        
        NSURL *URL = [NSURL URLWithString:[NSString stringWithFormat:@"https://app.asana.com/-/oauth_token?type=refresh&client_id=%@&client_secret=%@&grant_type=refresh_token&refresh_token=%@", ASANA_OAUTH_KEY,ASANA_OAUTH_SECRET,token.refresh_token.stringByEscapingForURLArgument]];
        
        NSMutableURLRequest *URLRequest = [NSMutableURLRequest requestWithURL:URL];
        URLRequest.HTTPMethod = @"POST";
        
        self.tokenRequest = [SMWebRequest requestWithURLRequest:URLRequest delegate:nil context:feedsToRefresh];
        [self.tokenRequest addTarget:self action:@selector(refreshTokenRequestComplete:feeds:) forRequestEvents:SMWebRequestEventComplete];
        [self.tokenRequest addTarget:self action:@selector(refreshTokenRequestError:) forRequestEvents:SMWebRequestEventError];
        [self.tokenRequest start];
    }
    else [self actualRefreshFeeds];
}

- (void)refreshTokenRequestComplete:(NSData *)data feeds:(NSArray *)feedsToRefresh {
    
    self.lastTokenRefresh = [NSDate date];
    
    NSString *password = self.findPassword;
    OAuth2Token *token = [OAuth2Token tokenWithStringRepresentation:password];
    NSString *error = nil;
    OAuth2Token *newToken = [[OAuth2Token alloc] initWithTokenResponse:data error:&error];
    
    if (newToken) {
        
        // absorb new token if necessary
        if (![newToken.access_token isEqualToString:token.access_token]) {
            token.access_token = newToken.access_token;
            [self savePassword:token.stringRepresentation];
            [Account saveAccountsAndNotify:NO]; // not a notification-worthy change
        }
        
        // NOW refresh feeds
        [self actualRefreshFeeds];
    }
    else DDLogError(@"NO TOKEN: %@", [data objectFromJSONData]);
}

- (void)refreshTokenRequestError:(NSError *)error {
    DDLogError(@"ERROR WHILE REFRESHING: %@", error);
}



+ (NSArray *)itemsForRequest:(SMWebRequest *)request data:(NSData *)data domain:(NSString *)domain username:(NSString *)username password:(NSString *)token {
    return @[];
}

@end
