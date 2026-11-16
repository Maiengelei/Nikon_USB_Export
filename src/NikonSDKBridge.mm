#import "NikonSDKBridge.h"
#import <Carbon/Carbon.h>
#import <Security/Security.h>
#include <atomic>
#include <dlfcn.h>

// The SDK headers include legacy inline formatting helpers.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wcomment"
#include "Maid3.h"
#include "Maid3d1.h"
#pragma clang diagnostic pop
#undef interface

@interface NikonSDKStorage ()
@property(nonatomic, readwrite) uint32_t storageID;
@property(nonatomic, readwrite, copy) NSString *readError;
@end
@implementation NikonSDKStorage
@end

@interface NikonSDKCamera ()
@property(nonatomic, readwrite, copy) NSString *name;
@property(nonatomic, readwrite) uint32_t deviceID;
@property(nonatomic, readwrite, copy) NSString *interfaceName;
@property(nonatomic, readwrite, copy) NSArray<NikonSDKStorage *> *stores;
@end
@implementation NikonSDKCamera
@end

namespace {
NSError *failure(NSString *message, NSInteger code = 2) {
    return [NSError errorWithDomain:@"NikonRemoteSDK" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

NSError *operationError(NSString *operation, int32_t code) {
    return failure([NSString stringWithFormat:@"尼康 SDK %@ 失败（%d）。", operation, code]);
}

// The host and these three embedded libraries have different signing teams.
NSError *verifyRuntime(NSURL *frameworks) {
    SecRequirementRef nikon = nullptr;
    OSStatus rc = SecRequirementCreateWithString(
        CFSTR("anchor apple generic and certificate leaf[subject.OU] = \"BS34UKQZ5V\""), kSecCSDefaultFlags, &nikon);
    if (rc != errSecSuccess) return operationError(@"创建签名要求", rc);
    for (NSString *name in @[@"Royalmile.framework", @"libNkPTPDriver2.dylib", @"TypeCommon Module.bundle"]) {
        NSURL *url = [frameworks URLByAppendingPathComponent:name];
        SecStaticCodeRef code = nullptr;
        rc = SecStaticCodeCreateWithPath((__bridge CFURLRef)url, kSecCSDefaultFlags, &code);
        if (rc == errSecSuccess) {
            rc = SecStaticCodeCheckValidity(code, kSecCSDefaultFlags, nikon);
            CFRelease(code);
        }
        if (rc != errSecSuccess) break;
    }
    CFRelease(nikon);
    return rc == errSecSuccess ? nil : operationError(@"核对尼康运行库签名", rc);
}

// MAID is process-wide. All entry points are called on the same serial path, outside its callbacks.
struct Module {
    LPMAIDInitializeSDKProc initialize;
    LPMAIDFreeSDKProc finish;
    LPMAIDConnectDeviceProc connect;
    LPMAIDDisconnectDeviceProc disconnect;
    LPMAIDEnumDevices enumerate;
    LPMAIDGetCapability get;

    NSError *load() {
        if (get) return nil;
        NSURL *frameworks = NSBundle.mainBundle.privateFrameworksURL;
        if (NSError *problem = verifyRuntime(frameworks)) return problem;
        NSURL *url = [frameworks URLByAppendingPathComponent:@"TypeCommon Module.bundle"];
        NSString *path = [NSBundle bundleWithURL:url].executablePath;
        if (!path) return failure(@"未找到尼康 SDK 模块，请重新构建应用。");
        void *library = dlopen(path.fileSystemRepresentation, RTLD_LOCAL | RTLD_NOW);
        if (!library) return failure([NSString stringWithFormat:@"无法载入尼康 SDK：%s", dlerror()]);
        initialize = (LPMAIDInitializeSDKProc)dlsym(library, "InitializeSDK");
        finish = (LPMAIDFreeSDKProc)dlsym(library, "FreeSDK");
        connect = (LPMAIDConnectDeviceProc)dlsym(library, "ConnectDevice");
        disconnect = (LPMAIDDisconnectDeviceProc)dlsym(library, "DisconnectDevice");
        enumerate = (LPMAIDEnumDevices)dlsym(library, "EnumDevices");
        get = (LPMAIDGetCapability)dlsym(library, "GetCapability");
        if (initialize && finish && connect && disconnect && enumerate && get) return nil;
        get = nullptr;
        dlclose(library);
        return failure(@"尼康 SDK 缺少所需的公开接口，请检查安装版本。");
    }
};

std::atomic_uint mediaChanges(0);

void event(NKREF, ULONG kind, NKPARAM data) {
    if (kind == kNkMAIDEvent_RemoveChild || kind == kNkMAIDEvent_OrphanedChildren ||
        kind == kNkMAIDEvent_StoreAdded || kind == kNkMAIDEvent_StoreRemoved ||
        (kind == kNkMAIDEvent_CapChangeValueOnly &&
         (data == kNkMAIDCapability_GetStorageIDS || data == kNkMAIDCapability_GetStorageInfoDataSet))) {
        ++mediaChanges;
    }
    if (kind == kNkMAIDEvent_CapChange || kind == kNkMAIDEvent_CapChangeOperationOnly || kind == kNkMAIDEvent_ImageSaved)
        free(reinterpret_cast<void *>(data));
}

ULONG uiRequest(NKREF, LPNkMAIDUIRequestInfo request) {
    if (!request || !request->fSync) return kNkMAIDUIRequestResult_None;
    if (request->ulType == kNkMAIDUIRequestType_Ok) return kNkMAIDUIRequestResult_Ok;
    if (request->ulType == kNkMAIDUIRequestType_YesNo) return kNkMAIDUIRequestResult_No;
    return kNkMAIDUIRequestResult_Cancel;
}

void progress(ULONG, ULONG, NKREF, ULONG, ULONG) {}
NKERROR rejectAcquisition(NKREF, LPVOID, LPVOID) { return kNkMAIDResult_Aborted; }
void discardLiveView(NKREF, LPNkMAIDLiveViewData view) {
    if (view) { free(view->pImageData); free(view); }
}

struct Session {
    Module &module;
    NkMAIDCSCallback callbacks = {};
    LPNkMAIDEnumDevices devices = nullptr;
    LPNkMAIDEnumCapInfo capabilities = nullptr;
    bool connected = false;

    explicit Session(Module &module) : module(module) {}
    ~Session() {
        if (devices) { free(devices->pDeviceData); free(devices); }
        if (capabilities) { free(capabilities->pCapArray); free(capabilities); }
    }

    NKERROR start() {
        callbacks.pfnEventProc = (LPNKFUNC)event;
        callbacks.pUIReqProc = (LPNKFUNC)uiRequest;
        callbacks.pProgressProc = (LPNKFUNC)progress;
        callbacks.pDataProc = (LPNKFUNC)rejectAcquisition;
        callbacks.pLiveViewDataProc = (LPNKFUNC)discardLiveView;
        return module.initialize(malloc, free, &callbacks, &devices, nullptr);
    }

    bool canRead(ULONG id, ULONG type) const {
        if (!capabilities || !capabilities->pCapArray) return false;
        for (ULONG i = 0; i < capabilities->ulCapCount; ++i) {
            const auto &cap = capabilities->pCapArray[i];
            if (cap.ulID == id && cap.ulType == type && (cap.ulOperations & kNkMAIDCapOperation_Get)) return true;
        }
        return false;
    }

    // The generic storage capabilities take a caller-supplied structure. Other capability
    // types (e.g. the interface string) instead return memory via our allocator.
    template<typename T>
    NKERROR storageValue(ULONG id, T &value) const {
        if (!canRead(id, kNkMAIDCapType_Generic)) return kNkMAIDAPIResult_CapabilityNotSupported;
        LPVOID pointer = &value;
        auto type = kNkMAIDDataType_GenericPtr;
        NKERROR result = module.get(id, kNkSDKGetSettingValue, pointer, type);
        if (pointer != &value) {
            if (result == 0 && pointer && type == kNkMAIDDataType_GenericPtr)
                memcpy(&value, pointer, sizeof(value));
            free(pointer);
            if (!pointer && result == 0) return kNkMAIDResult_UnexpectedDataType;
        }
        return (result == 0 && type != kNkMAIDDataType_GenericPtr) ? kNkMAIDResult_UnexpectedDataType : result;
    }

    NSError *finish() const {
        const HRESULT disconnected = connected ? module.disconnect() : 0;
        const HRESULT closed = module.finish();
        if (closed) return operationError(@"FreeSDK", (int32_t)closed);
        if (disconnected) return operationError(@"DisconnectDevice", (int32_t)disconnected);
        return nil;
    }
};

NSString *boundedString(const void *bytes, size_t size) {
    return [[NSString alloc] initWithBytes:bytes length:strnlen((const char *)bytes, size)
                                  encoding:NSUTF8StringEncoding] ?: @"";
}

NSError *readCamera(Session &session, NikonSDKCamera *camera) {
    const NkMAIDDeviceInfo *selected = nullptr;
    for (ULONG i = 0; session.devices && i < session.devices->ulElements; ++i) {
        const auto &device = session.devices->pDeviceData[i];
        NSString *name = boundedString(device.Name, sizeof(device.Name));
        NSLog(@"Z8E · SDK 设备 %@ · available=%d", name, device.Availability);
        NSString *model = [name.uppercaseString stringByReplacingOccurrencesOfString:@" " withString:@""];
        if (![@[@"Z8", @"NIKONZ8", @"NIKONDSCZ8"] containsObject:model]) continue;
        if (selected) return failure(@"尼康 SDK 找到多台 Z8，请只连接一台后刷新。");
        selected = &device;
        camera.name = name;
    }
    if (!selected) return failure(@"尼康 SDK 未发现 Nikon Z8，请检查 USB 连接后刷新。", 1);
    if (!selected->Availability) return failure(@"尼康 SDK 报告 Z8 已被占用，请关闭其他相机应用后刷新。");

    camera.deviceID = selected->ID;
    NKERROR result = session.module.connect(selected->ID, &session.capabilities);
    if (result) return operationError(@"ConnectDevice", result);
    session.connected = true;
    const unsigned revision = mediaChanges.load();
    if (!session.canRead(kNkMAIDCapability_Interface, kNkMAIDCapType_String))
        return failure(@"尼康 SDK 未提供可核对的物理连接接口。");
    LPVOID value = nullptr;
    auto type = kNkMAIDDataType_StringPtr;
    result = session.module.get(kNkMAIDCapability_Interface, kNkSDKGetSettingValue, value, type);
    if (!result && type == kNkMAIDDataType_StringPtr && value) {
        auto *name = static_cast<NkMAIDString *>(value);
        camera.interfaceName = boundedString(name->str, sizeof(name->str));
    }
    free(value);
    if (result) return operationError(@"GetCapability(Interface)", result);
    if (![camera.interfaceName.uppercaseString containsString:@"USB"])
        return failure([NSString stringWithFormat:@"尼康 SDK 无法确认 USB 连接（%@）。", camera.interfaceName ?: @"接口未知"]);

    NkMAIDStorageIDSList ids = {};
    result = session.storageValue(kNkMAIDCapability_GetStorageIDS, ids);
    if (result) return operationError(@"GetStorageIDS", result);
    if (ids.ulArrayCount > sizeof(ids.ulStorageIdArrays) / sizeof(ids.ulStorageIdArrays[0]))
        return failure(@"尼康 SDK 返回的存储数量超出接口范围。");
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    NSMutableArray<NikonSDKStorage *> *stores = [NSMutableArray array];
    for (ULONG i = 0; i < ids.ulArrayCount; ++i) {
        const ULONG id = ids.ulStorageIdArrays[i];
        if (!id || id == UINT32_MAX || [seen containsObject:@(id)])
            return failure(@"尼康 SDK 返回的存储标识无效或重复。");
        [seen addObject:@(id)];
        // A zero logical storage number exposes no readable logical store.
        if ((id & 0xffff) == 0) continue;
        auto *store = [NikonSDKStorage new];
        store.storageID = id;
        NkMAIDStorageInfoDataSet info = {};
        info.ulStorageId = id;
        result = session.storageValue(kNkMAIDCapability_GetStorageInfoDataSet, info);
        if (result) {
            // Preserve the other card for an explicitly store-local failure only.
            if (result != kNkMAIDResult_MediaAccessError && result != kNkMAIDResult_MediaNotFormatted &&
                result != kNkMAIDResult_NoMedia) return operationError(@"GetStorageInfoDataSet", result);
            store.readError = operationError(@"GetStorageInfoDataSet", result).localizedDescription;
        } else {
            if (info.ulStorageId != id) return failure(@"尼康 SDK 的存储详情与查询标识不一致。");
            // Z8 firmware can repeat another store's metadata here. Read the
            // capacity and volume label from the addressed Z8 command dataset.
        }
        [stores addObject:store];
    }
    if (revision != mediaChanges.load()) return failure(@"读取期间相机存储已变化，请刷新目录。");
    camera.stores = stores;
    return nil;
}
// Serialize initialization, enumeration and release for both discovery and reads.
NSError *withDevices(bool waitForUSB, NSError *(^read)(Session &)) {
    @synchronized (NikonSDKBridge.class) {
        static Module module = {};
        if (NSError *problem = module.load()) return problem;
        Session session(module);
        NKERROR result = session.start();
        if (result) return operationError(@"InitializeSDK", result);

        NSError *problem = nil;
        // Discovery is asynchronous. A USB endpoint can arrive before MAID
        // publishes its device list. Keep the initialized session for a bounded wait.
        const auto deadline = NSProcessInfo.processInfo.systemUptime + (waitForUSB ? 8.0 : 0.0);
        do {
            if (session.devices) {
                free(session.devices->pDeviceData);
                free(session.devices);
                session.devices = nullptr;
            }
            result = module.enumerate(session.devices, nullptr, nullptr);
            if (result || (session.devices && session.devices->ulElements)) break;
            if (NSProcessInfo.processInfo.systemUptime >= deadline) break;
            // The macOS driver delivers discovery on a run loop. A plain sleep
            // on the SDK caller's thread can leave a connected Z8 unreported.
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
            [NSThread sleepForTimeInterval:0.05];
        } while (true);
        NSLog(@"Z8E · SDK EnumDevices %u", session.devices ? (unsigned)session.devices->ulElements : 0);
        if (result) problem = operationError(@"EnumDevices", result);
        else if (session.devices && session.devices->ulElements && !session.devices->pDeviceData)
            problem = failure(@"尼康 SDK 返回了不完整的相机清单。");
        else problem = read(session);
        NSError *closeError = session.finish();
        return closeError ?: problem;
    }
}
} // namespace

@implementation NikonSDKBridge
+ (NSArray<NSString *> *)deviceNamesWithError:(NSError **)error {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSError *problem = withDevices(false, ^NSError *(Session &session) {
        for (ULONG i = 0; session.devices && i < session.devices->ulElements; ++i) {
            const auto &device = session.devices->pDeviceData[i];
            [names addObject:boundedString(device.Name, sizeof(device.Name))];
        }
        return nil;
    });
    if (problem && error) *error = problem;
    return problem ? nil : names;
}

+ (NikonSDKCamera *)probeWithError:(NSError **)error {
    NikonSDKCamera *camera = [NikonSDKCamera new];
    NSError *problem = withDevices(true, ^NSError *(Session &session) { return readCamera(session, camera); });
    if (problem && error) *error = problem;
    return problem ? nil : camera;
}
@end
