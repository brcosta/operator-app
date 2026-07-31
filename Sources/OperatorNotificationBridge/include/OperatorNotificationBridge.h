#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const OperatorNotificationBridgeErrorDomain;

typedef void (^OperatorNotificationAuthorizationCompletion)(
    BOOL granted, NSError * _Nullable error);
typedef void (^OperatorNotificationSettingsCompletion)(
    UNAuthorizationStatus status, NSError * _Nullable error);
typedef void (^OperatorNotificationSubmissionCompletion)(
    NSError * _Nullable error);

/// Installs the notification delegate while converting Objective-C exceptions
/// from notification infrastructure into a recoverable NSError.
FOUNDATION_EXPORT NSError * _Nullable OperatorInstallNotificationDelegate(
   id<UNUserNotificationCenterDelegate> delegate);

/// Registers Operator's notification action categories behind the same
/// exception boundary as delegate installation. This keeps a damaged or
/// unavailable notification center from preventing the app from launching.
FOUNDATION_EXPORT NSError * _Nullable OperatorSetNotificationCategories(
    NSSet<UNNotificationCategory *> *categories);

/// Requests notification authorization without allowing an Objective-C
/// exception to unwind into Swift.
FOUNDATION_EXPORT void OperatorRequestNotificationAuthorization(
    UNAuthorizationOptions options,
    OperatorNotificationAuthorizationCompletion completion);

/// Reads notification authorization state behind the same exception boundary.
FOUNDATION_EXPORT void OperatorGetNotificationAuthorizationStatus(
    OperatorNotificationSettingsCompletion completion);

/// Submits a local notification without allowing an Objective-C exception to
/// unwind into Swift.
FOUNDATION_EXPORT void OperatorSubmitNotificationRequest(
    UNNotificationRequest *request,
    OperatorNotificationSubmissionCompletion completion);

/// Regression-test probe for the Objective-C exception barrier.
FOUNDATION_EXPORT NSError *OperatorNotificationBridgeExceptionProbe(void);

NS_ASSUME_NONNULL_END
