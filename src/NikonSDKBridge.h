#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NikonSDKStorage : NSObject
@property(nonatomic, readonly) uint32_t storageID;
@property(nonatomic, readonly, copy, nullable) NSString *readError;
@end

@interface NikonSDKCamera : NSObject
@property(nonatomic, readonly, copy) NSString *name;
/// Identifier assigned by MAID for this enumeration, not a body serial number.
@property(nonatomic, readonly) uint32_t deviceID;
@property(nonatomic, readonly, copy) NSString *interfaceName;
@property(nonatomic, readonly, copy) NSArray<NikonSDKStorage *> *stores;
@end

@interface NikonSDKBridge : NSObject
/// Enumerate without opening a camera. An empty array is a successful discovery.
+ (nullable NSArray<NSString *> *)deviceNamesWithError:(NSError **)error NS_SWIFT_NAME(deviceNames());
/// Synchronous. The SDK relinquishes the camera before a successful return.
/// Failure domain NikonRemoteSDK, code 1 indicates no matching device.
+ (nullable NikonSDKCamera *)probeWithError:(NSError **)error NS_SWIFT_NAME(probe());
@end

NS_ASSUME_NONNULL_END
