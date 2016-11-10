/// Copyright 2015 Google Inc. All rights reserved.
///
/// Licensed under the Apache License, Version 2.0 (the "License");
/// you may not use this file except in compliance with the License.
/// You may obtain a copy of the License at
///
///    http://www.apache.org/licenses/LICENSE-2.0
///
///    Unless required by applicable law or agreed to in writing, software
///    distributed under the License is distributed on an "AS IS" BASIS,
///    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
///    See the License for the specific language governing permissions and
///    limitations under the License.

#import "MOLFCMClient.h"

#import <MOLAuthenticatingURLSession.h>

#import <SystemConfiguration/SystemConfiguration.h>

/**  The FCM production host URL. */
static NSString *const kFCMHost = @"https://fcm.googleapis.com";

/**  The FCM long poll component for receiving messages. */
static NSString *const kFCMMessagesBindPath = @"/fcm/connect/bind";

/**  The FCM component for posting message acknowledgements. */
static NSString *const kFCMMessagesAckPath = @"/fcm/connect/ack";

/**  HTTP Header Constants */
static NSString *const kFCMApplicationJSON = @"application/json";
static NSString *const kFCMContentType = @"Content-Type";

#pragma mark MOLFCMClient Extension

@interface MOLFCMClient() {
  /**  Is used throughout the class to reconnect to FCM after a connection loss. */
  SCNetworkReachabilityRef _reachability;

  /**  URL components for receiving and acknowledging messages. */
  NSURLComponents *_bindComponents;
  NSURLComponents *_acknowledgeComponents;
}

/**  NSURLSession wrapper used for https communication with the FCM service. */
@property(nonatomic) MOLAuthenticatingURLSession *authSession;

/**  Holds the NSURLSession object generated by the MOLAuthenticatingURLSession object. */
@property(nonatomic) NSURLSession *session;

/**  The block to be called for every message. */
@property(copy, nonatomic) MOLFCMMessageHandler messageHandler;

/**  Property to keep track of FCM's reachability. */
@property(nonatomic) BOOL reachable;

@end

#pragma mark SCNetworkReachabilityCallBack

/**  Called when the network state changes. */
static void reachabilityHandler(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags,
                                void *info) {
  MOLFCMClient *FCMClient = (__bridge MOLFCMClient *)info;
  // Only call the setter when there is a change. This will filter out the redundant calls to this
  // callback whenever the network interface states change.
  if (FCMClient.reachable != (flags & kSCNetworkReachabilityFlagsReachable)) {
    FCMClient.reachable = (flags & kSCNetworkReachabilityFlagsReachable);
  }
}

@implementation MOLFCMClient

#pragma mark init/dealloc methods

- (instancetype)initWithFCMToken:(NSString *)FCMToken
            sessionConfiguration:(NSURLSessionConfiguration *)sessionConfiguration
                  messageHandler:(MOLFCMMessageHandler)messageHandler {
  self = [super init];
  if (self) {
    _FCMToken = FCMToken.copy;
    _bindComponents = [NSURLComponents componentsWithString:kFCMHost];
    _bindComponents.path = kFCMMessagesBindPath;
    NSURLQueryItem *tokenQuery = [NSURLQueryItem queryItemWithName:@"token" value:FCMToken];
    if (tokenQuery) {
      _bindComponents.queryItems = @[ tokenQuery ];
    }

    _acknowledgeComponents = [NSURLComponents componentsWithString:kFCMHost];
    _acknowledgeComponents.path = kFCMMessagesAckPath;
    _messageHandler = messageHandler;

    _authSession =
        [[MOLAuthenticatingURLSession alloc] initWithSessionConfiguration:
            sessionConfiguration ?: [NSURLSessionConfiguration defaultSessionConfiguration]];

    _session = _authSession.session;
  }
  return self;
}

/**  Before this object is released ensure KVO removal from reachable and release reachability. */
- (void)dealloc {
  [self stopReachability];
}

- (NSString *)description {
  return [NSString stringWithFormat:@"<MOLFCMClient: %p>\nbind: %@\nack: %@",
             self, _bindComponents.URL, _acknowledgeComponents.URL];
}

#pragma mark reachability methods

/**  Called when self.reachable changes. */
- (void)setReachable:(BOOL)reachable {
  if (reachable) {
#ifdef DEBUG
    [self log:@"Reachability Restored - Start Reading Messages"];
#endif
    [self stopReachability];
    [self connect];
  }
}

/**  Start listening for network state changes on a background thread. */
- (void)startReachability {
  if (_reachability) return;
  _reachability = SCNetworkReachabilityCreateWithName(kCFAllocatorDefault, kFCMHost.UTF8String);
  SCNetworkReachabilityContext context = {
    .info = (__bridge void *)self
  };
  if (SCNetworkReachabilitySetCallback(_reachability, reachabilityHandler, &context)) {
    SCNetworkReachabilitySetDispatchQueue(
        _reachability, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
  }
}

/**  Stop listening for network state changes. */
- (void)stopReachability {
  if (_reachability) {
    if (SCNetworkReachabilitySetDispatchQueue(_reachability, NULL)) {
#ifdef DEBUG
      [self log:@"Reachability Thread Stopped"];
#endif
    }
    CFRelease(_reachability);
    _reachability = NULL;
  }
}

#pragma mark message methods

- (void)connect {
  [self cancelConnections];
  NSMutableURLRequest *URLRequest = [NSMutableURLRequest requestWithURL:_bindComponents.URL];
  [URLRequest addValue:kFCMApplicationJSON forHTTPHeaderField:kFCMContentType];
  URLRequest.HTTPMethod = @"GET";
  self.authSession.dataTaskDidReceiveDataBlock = [self dataTaskDidReceiveDataBlock];
  self.authSession.taskDidCompleteWithErrorBlock = [self taskDidCompleteWithErrorBlock];
  self.authSession.loggingBlock = self.loggingBlock;
  [[self.session dataTaskWithRequest:URLRequest] resume];
}

- (void)acknowledgeMessage:(NSDictionary *)message {
  if (self.FCMToken && message[@"message_id"]) {
    NSMutableURLRequest *URLRequest =
        [NSMutableURLRequest requestWithURL:_acknowledgeComponents.URL];
    URLRequest.HTTPMethod = @"POST";
    [URLRequest addValue:kFCMApplicationJSON forHTTPHeaderField:kFCMContentType];
    NSDictionary *ack = @{ @"token" : self.FCMToken,
                           @"message_id" : message[@"message_id"] };
    URLRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:ack options:0 error:NULL];
    [[self.session dataTaskWithRequest:URLRequest
                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
      if (((NSHTTPURLResponse *)response).statusCode != 200) {
        if (self.acknowledgeErrorHandler) {
          self.acknowledgeErrorHandler(message, error);
        }
      }
    }] resume];
  }
}

- (void)disconnect {
  [self stopReachability];
  [self.session invalidateAndCancel];
}

- (void)cancelConnections {
  [self.session getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks,
                                                NSArray *downloadTasks) {
    for (NSURLSessionDataTask *dataTask in dataTasks) {
      [dataTask cancel];
    }
  }];
}

/**  Recursively parse FCM data; extract and call self.messageHandler for each message. */
- (void)processMessagesFromData:(NSData *)data {
  if (!data) return;
  // The FCM buffer indexes each message with a length prefixing the message.
  // Use strtol() to find this index then digest the data for that given length.
  // leftOver will then have all the undigested bytes. Recursively call this method until the whole
  // buffer has been digested.
  char *leftOver = NULL;
  long length = strtol(data.bytes, &leftOver, 0);
  if (length >= 1 && data.length >= length) {
    NSData *dataChunk = [[NSData alloc] initWithBytes:++leftOver length:length];
    NSArray *jsonObject = [NSJSONSerialization JSONObjectWithData:dataChunk
                                                          options:NSJSONReadingAllowFragments
                                                            error:NULL];
    NSDictionary *message = [[[jsonObject firstObject] lastObject] firstObject];
    if ([message[@"message_type"] isEqualToString:@"control"] &&
        [message[@"control_type"] isEqualToString:@"CONNECTION_DRAINING"]) {
      return [self cancelConnections];
    } else if (message) {
      self.messageHandler(message);
    }
    NSData *nextChunk = [[NSData alloc] initWithBytes:leftOver + dataChunk.length
                                               length:data.length - dataChunk.length];
    if (nextChunk) {
      return [self processMessagesFromData:nextChunk];
    }
  }
}

#pragma mark NSURLSession block property and methods

/**
 *  MOLAuthenticatingURLSession is the NSURLSessionDelegate. It will call this block every time
 *  the URLSession:task:didCompleteWithError: is called. This allows MOLFCMClient to be notified
 *  when a task ends while using delegate methods.
 */
- (void (^)(NSURLSession *, NSURLSessionDataTask *, NSData *))dataTaskDidReceiveDataBlock {
  __weak __typeof(self) weakSelf = self;
  return ^(NSURLSession *session, NSURLSessionDataTask *dataTask, NSData *data) {
    [weakSelf processMessagesFromData:data];
  };
}

/**
 *  MOLAuthenticatingURLSession is the NSURLSessionDataDelegate. It will call this block every time
 *  the URLSession:dataTask:didReceiveData: is called. This allows for message data chunks to be
 *  processed as they appear in the FCM buffer. For Content-Type: text/html there is a 512 byte
 *  buffer that must be filled before data is returned. Content-Type: application/json does not use
 *  a buffer and data is returned as soon as it is available.
 *
 *  TODO:(bur) Follow up with FCM on Content-Type: application/json. Currently FCM returns data with
 *  Content-Type: text/html. Messages under 512 bytes will not be processed until the connection
 *  drains. This is done every ~3 minutes.
 */
- (void (^)(NSURLSession *, NSURLSessionTask *, NSError *))taskDidCompleteWithErrorBlock {
  __weak __typeof(self) weakSelf = self;
  return ^(NSURLSession *session, NSURLSessionTask *task, NSError *error) {
    __strong __typeof(self) strongSelf = weakSelf;
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)task.response;
    if (httpResponse.statusCode == 200) {
      [strongSelf connect];
    } else if (error.code == NSURLErrorTimedOut ||
               error.code == NSURLErrorNetworkConnectionLost ||
               error.code == NSURLErrorNotConnectedToInternet) {
#ifdef DEBUG
      [strongSelf log:[NSString stringWithFormat:@"%@", error]];
      [strongSelf log:@"Starting Reachability Thread"];
#endif
      [strongSelf startReachability];
    } else {
      if (strongSelf.connectionErrorHandler) strongSelf.connectionErrorHandler(error);
    }
  };
}

#pragma mark log

- (void)log:(NSString *)log {
  if (self.loggingBlock) {
    self.loggingBlock(log);
  }
}

@end
