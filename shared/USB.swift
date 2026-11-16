import Foundation
import ImageCaptureCore
import Combine

@MainActor
protocol PTPCommandDevice: AnyObject {
    var hasOpenSession: Bool { get }
    func sendReadPacket(_ packet: Data, transaction: UInt32, delegate: USBSource)
}

extension ICCameraDevice: PTPCommandDevice {
    func sendReadPacket(_ packet: Data, transaction: UInt32, delegate: USBSource) {
        requestSendPTPCommand(packet, outData: nil, sendCommandDelegate: delegate,
                              didSendCommand: #selector(USBSource.received(_:inData:response:error:contextInfo:)),
                              contextInfo: UnsafeMutableRawPointer(bitPattern: UInt(transaction)))
    }
}

@MainActor
final class USBSource: NSObject, PTPReading {
    private let camera: PTPCommandDevice
    private let timeoutNanoseconds: UInt64
    private var transaction: UInt32 = 0
    private var requestTail: Task<Void, Never>?
    private var pending: CheckedContinuation<Data, Error>?
    private var operation: ReadCommand?
    private var timeout: Task<Void, Never>?
    private var invalid: Error?
    var onSessionFailure: ((USBSource, Error) -> Void)?

    init(camera: PTPCommandDevice, timeoutNanoseconds: UInt64 = 120_000_000_000) {
        self.camera = camera
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func invalidate(_ error: Error) {
        guard invalid == nil else { return }
        invalid = error
        finish(.failure(error))
    }

    private func failSession(_ error: Error) {
        invalidate(error)
        onSessionFailure?(self, error)
    }

    func request(_ command: ReadCommand, _ parameters: [UInt32]) async throws -> Data {
        try Task.checkCancellation()
        // A cancelled thumbnail can still have a USB transaction in flight.
        // Wait for its callback before issuing the next preview or export read.
        let previous = requestTail
        let next = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await send(command, parameters)
        }
        requestTail = Task { _ = await next.result }
        return try await withTaskCancellationHandler {
            let data = try await next.value
            try Task.checkCancellation()
            return data
        } onCancel: {
            next.cancel()
        }
    }

    func drain() async { await requestTail?.value }

    private func send(_ command: ReadCommand, _ parameters: [UInt32]) async throws -> Data {
        if let invalid { throw invalid }
        guard pending == nil, camera.hasOpenSession else {
            let error = ExportError("相机会话不可用。")
            failSession(error)
            throw error
        }
        transaction &+= 1
        let token = transaction
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            operation = command
            timeout = Task { [weak self, timeoutNanoseconds] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard !Task.isCancelled, let self, self.transaction == token else { return }
                self.failSession(ExportError("等待相机读取超时，请刷新以重新连接。"))
            }
            camera.sendReadPacket(command.packet(transaction: token, parameters: parameters), transaction: token, delegate: self)
        }
    }

    @objc nonisolated func received(_ command: NSData?, inData: NSData?, response: NSData?,
                                            error: NSError?, contextInfo: UnsafeMutableRawPointer?) {
        let token = UInt(bitPattern: contextInfo)
        let payload = inData as Data?
        let receipt = response as Data?
        Task { @MainActor in
            guard token == UInt(transaction), let operation, pending != nil else { return }
            do {
                if let error {
                    // ImageCaptureCore can wrap a camera refusal in a generic
                    // pass-through failure. Only the camera receipt identifies the store error.
                    if error.domain == ICErrorDomain,
                       error.code == ICReturn.Code.failedToCompletePassThroughCommand.rawValue,
                       let receipt, let code = PTPBytes.responseCode(receipt), code != 0x2001 {
                        throw PTPResponseError(command: operation, code: code)
                    }
                    if (error.domain == ICErrorDomain && error.code == ICReturn.Code.communicationTimedOut.rawValue)
                        || (error.domain == NSURLErrorDomain && error.code == NSURLErrorTimedOut)
                        || (error.domain == NSPOSIXErrorDomain && error.code == Int(ETIMEDOUT)) {
                        failSession(ExportError("相机读取超时，请刷新以重新连接。\(error.localizedDescription)"))
                        return
                    }
                    throw error
                }
                try PTPBytes.checkResponse(receipt ?? Data(), to: operation)
                // The reader validates the dataset in the scope of its command and storage.
                finish(.success(payload ?? Data()))
            } catch let refusal as PTPResponseError where ![0x2003, 0x2004].contains(refusal.code) {
                finish(.failure(refusal))
            } catch { failSession(error) }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        timeout?.cancel()
        timeout = nil
        let continuation = pending
        pending = nil
        operation = nil
        continuation?.resume(with: result)
    }
}

@MainActor
final class CameraModel: NSObject, ObservableObject, ICDeviceBrowserDelegate {
    @Published private(set) var catalog = Catalog()
    @Published private(set) var status = "等待 USB 连接" {
        didSet { if status != oldValue { NSLog("Z8E · %@", status) } }
    }
    @Published private(set) var connected = false
    @Published private(set) var scanning = false
    @Published private(set) var exporting = false
    @Published private(set) var report: ExportProgress?
    @Published private(set) var scanNotes = [String]()
    @Published var destination: URL?
    private let browser: ICDeviceBrowser
    private let inspectSDK: (@MainActor (Bool) async throws -> NikonDiscovery)?

    init(browser: ICDeviceBrowser = ICDeviceBrowser(),
         inspectSDK: (@MainActor (Bool) async throws -> NikonDiscovery)? = nil) {
        self.browser = browser
        self.inspectSDK = inspectSDK
        super.init()
    }

    private var camera: ICCameraDevice?
    private var source: USBSource?
    private var transferDevice: ICCameraDevice?
    private var enumeratedLocalDevices = false
    private var needsInitialDiscovery = true
    private var sessionWasReset = false
    private var thumbnails: CatalogThumbnails?
    private var scanTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var generation = UUID()

    func start() {
        guard !browser.isBrowsing else { return }
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        #if os(iOS)
        enumeratedLocalDevices = true // iOS announces devices through didAdd, without a final enumeration callback.
        #endif
        status = "等待 USB 连接"
        browser.start()
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor in
            // Preserve the topology event even if another callback has already
            // removed this second body from the browser's live device array.
            if let added = device as? ICCameraDevice, isZ8Endpoint(added),
               let camera, added !== camera { detach() }
            updateDevices()
        }
    }

    #if os(macOS)
    nonisolated func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        Task { @MainActor in
            enumeratedLocalDevices = true
            updateDevices()
        }
    }

    #endif

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            if device === camera { detach() }
            updateDevices()
        }
    }

    // ImageCaptureCore announces local USB endpoints. The SDK has to identify
    // and open the Z8 itself before this app opens an object-transfer session.
    private var usbCandidates: [ICCameraDevice] {
        (browser.devices ?? []).compactMap { $0 as? ICCameraDevice }.filter(isZ8Endpoint)
    }

    private func isZ8Endpoint(_ device: ICCameraDevice) -> Bool {
        device.transportType == ICDeviceTransport.transportTypeUSB.rawValue &&
        device.usbVendorID == 0x04b0 && device.usbProductID == 0x0451
    }

    private func updateDevices() {
        guard browser.isBrowsing, enumeratedLocalDevices else { return }
        let candidates = usbCandidates
        guard candidates.count == 1, let device = candidates.first else {
            if camera != nil { detach() }
            if candidates.count > 1 {
                clearCatalog("检测到多台 Z8，请只连接需要导出的机身。")
                needsInitialDiscovery = true
            }
            else if needsInitialDiscovery && inspectSDK != nil {
                needsInitialDiscovery = false
                // The USB object can be posted just after local enumeration.
                // Give it a chance to start the full scan before a discovery-only call.
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if self.camera == nil && self.usbCandidates.isEmpty && self.canRefresh { self.refresh() }
                }
            }
            return
        }
        guard device !== camera else { return }
        if camera != nil { detach() }
        needsInitialDiscovery = false
        camera = device
        sessionWasReset = false
        clearCatalog("已发现 USB 设备，正在识别机身…")
        if exporting { needsInitialDiscovery = true } else { refresh() }
    }

    func stop() {
        guard browser.isBrowsing else { return }
        browser.delegate = nil
        browser.stop()
        enumeratedLocalDevices = false
        needsInitialDiscovery = true
        detach()
    }

    private func observeChanges(on device: ICCameraDevice, generation snapshot: UUID) {
        device.ptpEventHandler = { [weak self] packet in
            guard let event = CatalogEvent.interrupt(packet), event.affectsCatalog else { return }
            Task { @MainActor in
                guard let self, self.generation == snapshot else { return }
                self.apply(event)
            }
        }
    }

    private func apply(_ event: CatalogEvent) {
        let detail = String(format: "PTP 事件 0x%04X", event.code)
            + (event.parameter.map { String(format: " 参数 0x%08X", $0) } ?? "")
        scanNotes.append(detail)
        if event.code == 0x400b {
            sessionWasReset = true
            connected = false
            let message = "相机会话已重置，请重新连接。"
            source?.invalidate(ExportError(message))
            clearCatalog(message)
        } else {
            clearCatalog("相机内容或存储信息已变化，请刷新并重新核对卡槽。")
        }
    }

    private func checkEvents(_ reader: USBSource, generation snapshot: UUID) async throws {
        guard generation == snapshot else { throw CancellationError() }
        do {
            let data = try await reader.request(.events, [])
            guard generation == snapshot else { throw CancellationError() }
            if let change = try CatalogEvent.firstChange(in: data) {
                apply(change)
                throw ExportError(status)
            }
        } catch {
            if generation == snapshot && !Task.isCancelled {
                let message = "无法核对相机变化，请刷新。 " + error.localizedDescription
                scanNotes.append(message)
                clearCatalog(message)
            }
            throw error
        }
    }

    private func monitorEvents(_ reader: USBSource, generation snapshot: UUID) {
        // In Nikon application mode media changes may only reach the command queue.
        eventTask = Task {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    try await checkEvents(reader, generation: snapshot)
                }
            } catch { return }
        }
    }

    private func detach() {
        camera?.ptpEventHandler = { _ in }
        camera = nil
        source?.invalidate(ExportError("USB 已断开，等待重新连接。"))
        connected = false
        scanNotes.append("USB 已断开。")
        clearCatalog("USB 已断开，等待重新连接。")
        let pending = scanTask
        scanTask = Task {
            await pending?.value
            try? await closeTransferSession()
        }
    }

    private func clearCatalog(_ message: String) {
        generation = UUID()
        eventTask?.cancel()
        eventTask = nil
        scanTask?.cancel()
        exportTask?.cancel()
        thumbnails?.cancel()
        thumbnails = nil
        catalog = Catalog()
        scanning = false
        status = message
    }

    private func closeTransferSession() async throws {
        if let source {
            await source.drain()
            source.invalidate(ExportError("USB 传输会话已关闭。"))
            self.source = nil
        }
        if let device = transferDevice {
            device.ptpEventHandler = { _ in }
            if device.hasOpenSession { try await device.requestCloseSession(options: nil) }
            transferDevice = nil
        }
    }

    private func checkEndpoint(_ device: ICCameraDevice, generation expected: UUID) throws {
        try Task.checkCancellation()
        guard generation == expected, camera === device, !sessionWasReset,
              usbCandidates.count == 1, usbCandidates.first === device else {
            throw ExportError("USB 机身或会话已变化，请重新连接后刷新。")
        }
    }

    var canRefresh: Bool {
        usbCandidates.count <= 1 && !scanning && !exporting &&
            (camera == nil || !sessionWasReset)
    }

    func refresh() {
        guard canRefresh else { return }
        needsInitialDiscovery = false
        let candidate = camera
        clearCatalog(inspectSDK == nil ? "正在通过 USB 识别 Z8…" : "正在通过尼康 SDK 识别 Z8…")
        connected = false
        scanNotes = [(inspectSDK == nil ? "ImageCaptureCore · " : "Nikon Remote SDK 2.1.0 · ") + Date().formatted()]
        let previous = scanTask
        let current = generation
        scanning = true
        scanTask = Task {
            // Await the native SDK call, open attempt, or pending read from the
            // preceding scan before either library can claim the endpoint again.
            await previous?.value
            do {
                try Task.checkCancellation()
                try await closeTransferSession()
                guard let device = candidate else {
                    if let inspectSDK {
                        let names = try await inspectSDK(false).names
                        guard generation == current else { return }
                        status = names.isEmpty ? "尼康 SDK 已就绪，等待通过 USB 连接 Z8。" : "尼康 SDK 已发现设备，等待 Z8 的 USB 数据连接。"
                        scanNotes.append("SDK EnumDevices · " + (names.isEmpty ? "未发现设备" : names.joined(separator: "、")))
                    } else {
                        status = "等待通过 USB 连接 Nikon Z8。"
                    }
                    scanning = false
                    return
                }
                try checkEndpoint(device, generation: current)
                var stores: [SDKStorageRecord]?
                if let inspectSDK {
                    let sdk = try await inspectSDK(true)
                    try checkEndpoint(device, generation: current)
                    guard sdk.names.count == 1, let interface = sdk.interfaceName else {
                        throw ExportError("尼康 SDK 未确认当前 USB 机身。")
                    }
                    stores = sdk.stores
                    scanNotes.append("SDK 已连接 " + sdk.names[0] + " · " + interface)
                    for store in sdk.stores {
                        let detail = store.error ?? "可访问"
                        scanNotes.append(String(format: "SDK 存储 0x%08X · ", store.id) + detail)
                    }
                }
                status = "正在按 Z8 命令规范读取目录…"
                transferDevice = device
                try await device.requestOpenSession(options: nil)
                try checkEndpoint(device, generation: current)
                guard device.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue) else {
                    throw ExportError("相机未开放 PTP 读取，请检查 USB 数据连接模式。")
                }
                observeChanges(on: device, generation: current)
                try await readCatalog(with: USBSource(camera: device), sdkStores: stores)
            } catch {
                guard generation == current else { return }
                status = error.localizedDescription
                scanNotes.append("读取中断 · \(status)")
            }
            scanning = false
        }
    }

    func readCatalog(with source: USBSource, sdkStores: [SDKStorageRecord]?) async throws {
        let current = generation
        connected = true
        self.source = source
        source.onSessionFailure = { [weak self] failed, error in
            guard let self, self.source === failed, generation == current else { return }
            connected = false
            let message = "USB 会话已失效，请刷新。 " + error.localizedDescription
            scanNotes.append(message)
            clearCatalog(message)
        }
        // Consume pre-scan history. Check again before publishing this snapshot.
        _ = try CatalogEvent.firstChange(in: await source.request(.events, []))
        let result = try await CameraReader(source: source).scan(sdkStores: sdkStores, evidence: {
            if generation == current { scanNotes.append($0) }
        }, progress: {
            if generation == current { status = $0 }
        })
        guard generation == current else { return }
        try await checkEvents(source, generation: current)
        guard generation == current else { return }
        thumbnails = CatalogThumbnails(catalog: result, source: source)
        catalog = result
        monitorEvents(source, generation: current)
        if result.failedStores.isEmpty {
            status = result.stores.isEmpty ? "未发现可读取的存储卡。" : "已读取 \(result.stores.count) 个存储"
        } else {
            status = "可读取 \(result.stores.count) 个存储，\(result.failedStores.count) 个读取失败。"
        }
    }

    func confirm(_ slot: Slot?, id: UInt32) {
        guard !exporting, !scanning else { return }
        do { try catalog.confirm(slot, for: id) } catch { status = error.localizedDescription }
    }

    var thumbnailReadNote: String? { thumbnails?.lastReadNote }

    func thumbnail(for entry: Entry) async throws -> Data {
        guard !exporting, !scanning, let previews = thumbnails else { throw CancellationError() }
        let data = try await previews.thumbnail(for: entry)
        guard previews === thumbnails, !exporting else { throw CancellationError() }
        return data
    }

    func export(_ scope: ExportScope) {
        guard connected, !exporting, !scanning, let source, let destination else { return }
        do {
            let items = try catalog.plan(scope)
            thumbnails?.cancel()
            exporting = true
            report = ExportProgress(total: items.count)
            let snapshot = generation
            exportTask = Task {
                defer {
                    exporting = false
                    if needsInitialDiscovery, camera != nil, canRefresh { refresh() }
                }
                let hasAccess = destination.startAccessingSecurityScopedResource()
                defer { if hasAccess { destination.stopAccessingSecurityScopedResource() } }
                let reader = CameraReader(source: source)
                do {
                    try await checkEvents(source, generation: snapshot)
                    report = await exportPhotos(items, destination: Destination(root: destination), read: { item in
                        let bytes = try await reader.read(item)
                        try await checkEvents(source, generation: snapshot)
                        return bytes
                    }, progress: { report = $0 })
                } catch {
                    var stopped = ExportProgress(total: items.count)
                    stopped.failure = error is CancellationError ? status : error.localizedDescription
                    report = stopped
                }
            }
        } catch { status = error.localizedDescription }
    }
}
