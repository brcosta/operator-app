#import "OperatorNotificationBridge.h"

NSErrorDomain const OperatorNotificationBridgeErrorDomain =
    @"local.operator.notification-bridge";

static NSError *OperatorNotificationErrorFromException(
    NSException *exception) {
  NSString *reason = exception.reason ?: @"Notification infrastructure failed.";
  return [NSError
      errorWithDomain:OperatorNotificationBridgeErrorDomain
               code:1
             userInfo:@{
               NSLocalizedDescriptionKey : reason,
               @"exceptionName" : exception.name
             }];
}

static UNUserNotificationCenter *OperatorCurrentNotificationCenter(void) {
  if ([[NSProcessInfo processInfo]
              .environment[@"OPERATOR_TEST_NOTIFICATION_EXCEPTION"]
          isEqualToString:@"1"]) {
    @throw [NSException
        exceptionWithName:@"OperatorNotificationCenterUnavailable"
                   reason:@"Notification center unavailable for regression test."
                 userInfo:nil];
  }
  return [UNUserNotificationCenter currentNotificationCenter];
}

NSError *OperatorInstallNotificationDelegate(
    id<UNUserNotificationCenterDelegate> delegate) {
  @try {
    OperatorCurrentNotificationCenter().delegate = delegate;
    return nil;
  } @catch (NSException *exception) {
    return OperatorNotificationErrorFromException(exception);
  }
}

NSError *OperatorSetNotificationCategories(
    NSSet<UNNotificationCategory *> *categories) {
  @try {
    [OperatorCurrentNotificationCenter() setNotificationCategories:categories];
    return nil;
  } @catch (NSException *exception) {
    return OperatorNotificationErrorFromException(exception);
  }
}

void OperatorRequestNotificationAuthorization(
    UNAuthorizationOptions options,
    OperatorNotificationAuthorizationCompletion completion) {
  @try {
    [OperatorCurrentNotificationCenter()
        requestAuthorizationWithOptions:options
                      completionHandler:completion];
  } @catch (NSException *exception) {
    completion(NO, OperatorNotificationErrorFromException(exception));
  }
}

void OperatorGetNotificationAuthorizationStatus(
    OperatorNotificationSettingsCompletion completion) {
  @try {
    [OperatorCurrentNotificationCenter()
        getNotificationSettingsWithCompletionHandler:^(
            UNNotificationSettings *settings) {
          completion(settings.authorizationStatus, nil);
        }];
  } @catch (NSException *exception) {
    completion(UNAuthorizationStatusDenied,
               OperatorNotificationErrorFromException(exception));
  }
}

void OperatorSubmitNotificationRequest(
    UNNotificationRequest *request,
    OperatorNotificationSubmissionCompletion completion) {
  @try {
    [OperatorCurrentNotificationCenter()
        addNotificationRequest:request
         withCompletionHandler:completion];
  } @catch (NSException *exception) {
    completion(OperatorNotificationErrorFromException(exception));
  }
}

NSError *OperatorNotificationBridgeExceptionProbe(void) {
  @try {
    @throw [NSException
        exceptionWithName:@"OperatorNotificationBridgeProbe"
                   reason:@"Objective-C exception barrier probe."
                 userInfo:nil];
  } @catch (NSException *exception) {
    return OperatorNotificationErrorFromException(exception);
  }
}
