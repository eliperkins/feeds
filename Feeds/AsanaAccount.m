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
#define ASANA_REDIRECT @"feedsapp%3A%2F%2Fbasana%2Fauth"

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
    
    // We could get:
    // feedsapp://basecampnext/auth?code=b1233f3e
    // feedsapp://basecampnext/auth?error=access_denied
    
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
    self.username = me[@"name"];
        
    [self.delegate account:self validationDidCompleteWithNewPassword:token];
}

- (void)meRequestError:(NSError *)error {
    [self.delegate account:self validationDidFailWithMessage:error.localizedDescription field:AccountFailingFieldUnknown];
}

+ (NSArray *)itemsForRequest:(SMWebRequest *)request data:(NSData *)data domain:(NSString *)domain username:(NSString *)username password:(NSString *)token {
    return @[];
}

@end
