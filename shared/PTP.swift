import Foundation

// PTP USB containers and datasets are little-endian. ImageCaptureCore returns the
// incoming data phase separately from the response container.
enum ReadCommand: UInt16 {
    // MAID opens a Nikon application session. The standard 0x1004 can
    // report placeholders here even with both cards installed (Z8 §6.2.3.1).
    case storageIDs = 0x9209
    case storageInfo = 0x1005
    case objectHandles = 0x1007
    case objectInfo = 0x1008
    case object = 0x1009
    case thumbnail = 0x100a
    case events = 0x941c
    case objectPropList = 0x9805
    var name: String {
        switch self {
        case .storageIDs: return "GetVendorStorageIDs"
        case .storageInfo: return "GetStorageInfo"
        case .objectHandles: return "GetObjectHandles"
        case .objectInfo: return "GetObjectInfo"
        case .object: return "GetObject"
        case .thumbnail: return "GetThumb"
        case .events: return "GetEventEx"
        case .objectPropList: return "GetObjectPropList"
        }
    }

    func packet(transaction: UInt32, parameters: [UInt32]) -> Data {
        var bytes = Data()
        func append<T: FixedWidthInteger>(_ number: T) {
            var value = number.littleEndian
            withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
        }
        append(UInt32(12 + parameters.count * 4))
        append(UInt16(1))
        append(rawValue)
        append(transaction)
        parameters.forEach { append($0) }
        return bytes
    }
}

struct PTPResponseError: LocalizedError {
    let command: ReadCommand
    let code: UInt16

    // These responses concern the addressed store, object or parent association.
    // Unknown errors, device-busy and session errors stop enumeration globally.
    var isStorageSpecific: Bool {
        switch code {
        case 0x2008, 0x2009, 0x200f, 0x2013, 0x2015, 0x201a: return true
        case 0xa021, 0xa022: return [.storageInfo, .objectHandles, .objectInfo].contains(command)
        default: return false
        }
    }

    var errorDescription: String? {
        String(format: "%@（0x%04X）返回 0x%04X", command.name, command.rawValue, code)
    }
}

struct PTPBytes {
    let data: Data
    var offset = 0

    mutating func number<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard data.count - offset >= size else { throw ExportError("相机返回的 PTP 数据不完整。") }
        defer { offset += size }
        return data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: type)) }
    }

    mutating func string() throws -> String {
        let count = Int(try number(UInt8.self))
        if count == 0 { return "" }
        let end = offset + 2 * count
        guard end <= data.count, data[end-2] == 0, data[end-1] == 0,
              let text = String(data: data[offset..<end-2], encoding: .utf16LittleEndian) else {
            throw ExportError("相机返回了无法读取的 PTP 名称。")
        }
        offset = end
        return text
    }

    static func identifiers(_ data: Data) throws -> [UInt32] {
        var reader = Self(data: data)
        let count = Int(try reader.number(UInt32.self))
        guard data.count - 4 == count * 4 else { throw ExportError("PTP 标识列表长度错误。") }
        let ids = try (0..<count).map { _ in try reader.number(UInt32.self) }
        guard Set(ids).count == ids.count else { throw ExportError("PTP 标识重复。") }
        return ids
    }

    static func responseCode(_ data: Data) -> UInt16? {
        var reader = Self(data: data)
        guard data.count >= 12, let length = try? reader.number(UInt32.self), Int(length) == data.count,
              (try? reader.number(UInt16.self)) == 3 else { return nil }
        return try? reader.number(UInt16.self)
    }

    static func checkResponse(_ data: Data, to command: ReadCommand) throws {
        guard let code = responseCode(data) else { throw ExportError("相机未返回有效的 PTP 响应。") }
        guard code == 0x2001 else { throw PTPResponseError(command: command, code: code) }
    }

    static func object(_ data: Data, id: UInt32) throws -> CameraObject {
        var reader = Self(data: data)
        let storage = try reader.number(UInt32.self)
        let format = try reader.number(UInt16.self)
        _ = try reader.number(UInt16.self) // ProtectionStatus
        let size = try reader.number(UInt32.self)
        reader.offset = 38 // ParentObject after the thumbnail and image dimensions
        let parent = try reader.number(UInt32.self)
        reader.offset = 52 // Filename after association fields and SequenceNumber
        let name = try reader.string()
        return CameraObject(id: id, storage: storage, parent: parent, format: format, name: name, size: size)
    }
}

struct CatalogEvent: Equatable {
    let code: UInt16
    let parameter: UInt32?

    var affectsCatalog: Bool {
        [0x4002, 0x4003, 0x4004, 0x4005, 0x4007, 0x400b, 0x400c, 0x400e].contains(code)
    }

    static func interrupt(_ data: Data) -> Self? {
        var reader = PTPBytes(data: data)
        guard data.count >= 12, let length = try? reader.number(UInt32.self), Int(length) == data.count,
              (try? reader.number(UInt16.self)) == 4, let code = try? reader.number(UInt16.self) else { return nil }
        reader.offset = 12
        return Self(code: code, parameter: try? reader.number(UInt32.self))
    }

    // GetEventEx uses a packed list, unlike the interrupt endpoint's USB container.
    static func firstChange(in data: Data) throws -> Self? {
        var reader = PTPBytes(data: data)
        let count = Int(try reader.number(UInt32.self))
        guard count <= 2048 else { throw ExportError("相机事件数量异常。") }
        var change: Self?
        for _ in 0..<count {
            let code = try reader.number(UInt16.self)
            let parameters = Int(try reader.number(UInt16.self))
            var first: UInt32?
            for index in 0..<parameters {
                let value = try reader.number(UInt32.self)
                if index == 0 { first = value }
            }
            let event = Self(code: code, parameter: first)
            if event.affectsCatalog && (change == nil || code == 0x400b) { change = event }
        }
        guard reader.offset == data.count else { throw ExportError("相机事件列表长度错误。") }
        return change
    }
}

@MainActor
protocol PTPReading: AnyObject {
    func request(_ command: ReadCommand, _ parameters: [UInt32]) async throws -> Data
}

@MainActor
struct CameraReader {
    let source: PTPReading

    func scan(sdkStores: [SDKStorageRecord]? = nil, evidence: (String) -> Void = { _ in }, progress: (String) -> Void) async throws -> Catalog {
        let ids: [UInt32]
        do {
            ids = try PTPBytes.identifiers(await source.request(.storageIDs, []))
        } catch {
            evidence("GetVendorStorageIDs 失败 · \(error.localizedDescription)")
            throw error
        }
        evidence("GetVendorStorageIDs  " + ids.map { String(format: "0x%08X", $0) }.joined(separator: ", "))
        // A zero logical storage number exposes no readable card (e.g. an empty slot).
        let present = ids.filter { $0 & 0xffff != 0 }
        guard present.count <= 2 else { throw ExportError("发现超过两个逻辑存储，无法与 Z8 物理卡槽逐一核对。") }
        var sdkByID = [UInt32: SDKStorageRecord]()
        if let sdkStores {
            for store in sdkStores where store.id & 0xffff != 0 {
                guard sdkByID.updateValue(store, forKey: store.id) == nil else {
                    throw ExportError("尼康 SDK 返回了重复的存储标识，请重新连接。")
                }
            }
            guard Set(sdkByID.keys) == Set(present) else {
                throw ExportError("SDK 与 USB 传输会话的存储列表不同，请刷新并重新核对。")
            }
        }
        var stores = [Storage]()
        var failures = [StorageFailure]()
        for id in present {
            try Task.checkCancellation()
            do {
                let sdk = sdkByID[id]
                if let error = sdk?.error {
                    throw StorageFailure(id: id, slot: nil, operation: "SDK GetStorageInfoDataSet", detail: error)
                }
                let store = try await scanStore(id, evidence: evidence, progress: progress)
                stores.append(store)
            } catch let error as StorageFailure {
                evidence(error.localizedDescription)
                failures.append(error)
            }
        }
        try Task.checkCancellation()
        return Catalog(stores: stores, failedStores: failures)
    }

    private func scanStore(_ id: UInt32, evidence: (String) -> Void, progress: (String) -> Void) async throws -> Storage {
        var slot: Slot?
        func failure(_ operation: String, _ error: Error) -> StorageFailure {
            StorageFailure(id: id, slot: slot, operation: operation, detail: error.localizedDescription)
        }

        // Keep session/USB failures outside the dataset parser's card-local catch.
        func dataset<T>(_ command: ReadCommand, _ parameters: [UInt32], decode: (Data) throws -> T) async throws -> T {
            let data: Data
            do {
                data = try await source.request(command, parameters)
            } catch let error as PTPResponseError where error.isStorageSpecific {
                throw StorageFailure(id: id, slot: slot, operation: command.name,
                                     detail: String(format: "PTP 响应 0x%04X", error.code))
            } catch {
                evidence(String(format: "存储 0x%08X · %@", id, command.name) + " · \(error.localizedDescription)")
                throw error
            }
            try Task.checkCancellation()
            do { return try decode(data) } catch { throw failure(command.name, error) }
        }

        let (capacity, description, label) = try await dataset(.storageInfo, [id]) { data in
            var info = PTPBytes(data: data, offset: 6)
            let capacity = try info.number(UInt64.self)
            info.offset = 26
            let description = try info.string()
            return (capacity, description, try info.string())
        }
        slot = Storage.reportedSlot(id: id, label: label)
        evidence(String(format: "存储 0x%08X", id) + "  描述「\(description)」 卷标「\(label)」 容量 \(capacity) 字节")
        let handles = try await dataset(.objectHandles, [id, 0, 0], decode: PTPBytes.identifiers)
        let roots = try await dataset(.objectHandles, [id, 0, .max], decode: PTPBytes.identifiers)
        evidence("对象 \(handles.count) 个，根级对象 \(roots.count) 个")
        let start = ProcessInfo.processInfo.systemUptime
        func makeStore(_ objects: [CameraObject]) throws -> Storage {
            try Storage(id: id, description: description, label: label, capacity: capacity,
                        objects: objects, roots: Set(roots))
        }
        let store: Storage
        if !roots.isEmpty, handles.count > max(16, roots.count * 5),
           let batch = try await batchObjects(handles: handles, roots: roots, storage: id),
           let validated = try? makeStore(batch) {
            store = validated
            evidence("批量元数据 · \(roots.count * 5) 次 GetObjectPropList")
        } else {
            var objects = [CameraObject]()
            objects.reserveCapacity(handles.count)
            for (offset, handle) in handles.enumerated() {
                if offset.isMultiple(of: 25) { progress("正在读取目录 · \(offset + 1) / \(handles.count)") }
                let object = try await dataset(.objectInfo, [handle]) { try PTPBytes.object($0, id: handle) }
                objects.append(object)
            }
            do { store = try makeStore(objects) } catch { throw failure("校验目录", error) }
            evidence("逐对象元数据 · \(handles.count) 次 GetObjectInfo")
        }
        evidence(String(format: "元数据与目录校验 %.3f 秒", ProcessInfo.processInfo.systemUptime - start))
        let photos = store.entries.filter { $0.object.isPhoto }
        evidence("目录 \(store.entries.count - photos.count) 个，照片 \(photos.count) 张")
        for photo in photos.prefix(2) { evidence("样本 " + photo.path.joined(separator: "/")) }
        return store
    }

    private enum BatchError: Error { case incomplete }

    // Ask for one typed column at a time, limited to a root on this card. Only
    // accept the result when all five columns cover exactly the enumerated handles.
    private func batchObjects(handles: [UInt32], roots: [UInt32], storage: UInt32) async throws -> [CameraObject]? {
        func column<T>(_ property: UInt16, type: UInt16, root: UInt32,
                       decode: (inout PTPBytes) throws -> T) async throws -> [UInt32: T] {
            try Task.checkCancellation()
            let data = try await source.request(.objectPropList, [root, 0, UInt32(property), 0, .max])
            var reader = PTPBytes(data: data)
            do {
                let count = Int(try reader.number(UInt32.self))
                guard count <= handles.count else { throw BatchError.incomplete }
                var values = [UInt32: T]()
                for _ in 0..<count {
                    let id = try reader.number(UInt32.self)
                    guard try reader.number(UInt16.self) == property, try reader.number(UInt16.self) == type,
                          values.updateValue(try decode(&reader), forKey: id) == nil else { throw BatchError.incomplete }
                }
                guard reader.offset == data.count else { throw BatchError.incomplete }
                return values
            } catch { throw BatchError.incomplete }
        }
        var objects = [UInt32: CameraObject]()
        do {
            for root in roots {
                let stores = try await column(0xdc01, type: 6, root: root) { try $0.number(UInt32.self) }
                let formats = try await column(0xdc02, type: 4, root: root) { try $0.number(UInt16.self) }
                let sizes = try await column(0xdc04, type: 8, root: root) { try $0.number(UInt64.self) }
                let names = try await column(0xdc07, type: 0xffff, root: root) { try $0.string() }
                let parents = try await column(0xdc0b, type: 6, root: root) { try $0.number(UInt32.self) }
                guard [formats.count, sizes.count, names.count, parents.count].allSatisfy({ $0 == stores.count })
                else { return nil }
                for (id, store) in stores {
                    guard store == storage, objects[id] == nil, let format = formats[id], let size = sizes[id],
                          let name = names[id], let parent = parents[id] else { return nil }
                    objects[id] = CameraObject(id: id, storage: store, parent: parent, format: format, name: name,
                                               size: UInt32(clamping: size))
                }
            }
        } catch is BatchError { return nil }
        catch let error as PTPResponseError where error.isStorageSpecific ||
            [0x2005, 0x2006, 0x2014, 0x201d, 0xa801, 0xa802, 0xa805, 0xa807, 0xa808, 0xa80a].contains(error.code) { return nil }
        guard objects.count == handles.count, handles.allSatisfy({ objects[$0] != nil }) else { return nil }
        return handles.compactMap { objects[$0] }
    }

    private func infoFor(_ handle: UInt32) async throws -> CameraObject {
        try PTPBytes.object(await source.request(.objectInfo, [handle]), id: handle)
    }

    func read(_ item: ExportItem) async throws -> Data {
        let original = item.entry.object
        guard try await infoFor(original.id) == original else {
            throw ExportError("相机文件已变化。请刷新目录后重试。")
        }
        guard original.size > 0, original.size != .max else { throw ExportError("无法核对原片大小。") }
        let data = try await source.request(.object, [original.id])
        guard data.count == Int(original.size) else { throw ExportError("读取的字节数与原片大小不一致。") }
        return data
    }
}

// One instance per completed catalog scan. Object handles are only meaningful
// within that session and GetThumb takes a handle without a storage ID.
@MainActor
final class CatalogThumbnails {
    private let source: PTPReading
    private let entries: [UInt32: Entry]
    private let cache = NSCache<NSNumber, NSData>()
    private var active: Task<Data, Error>?
    private(set) var lastReadNote: String?

    init(catalog: Catalog, source: PTPReading) {
        self.source = source
        var entries = [UInt32: Entry]()
        var ambiguous = Set<UInt32>()
        for store in catalog.stores {
            for entry in store.entries {
                if entries.updateValue(entry, forKey: entry.id) != nil {
                    ambiguous.insert(entry.id)
                }
            }
        }
        for id in ambiguous { entries.removeValue(forKey: id) }
        self.entries = entries
        cache.countLimit = 128
        cache.totalCostLimit = 8 * 1024 * 1024
    }

    func cancel() { active?.cancel() }

    func thumbnail(for entry: Entry) async throws -> Data {
        try Task.checkCancellation()
        let started = ProcessInfo.processInfo.systemUptime
        guard entry.object.isPhoto, entries[entry.id] == entry else {
            throw ExportError("相机文件已变化或标识重复，请刷新目录。")
        }
        let previous = active
        previous?.cancel()
        let key = NSNumber(value: entry.id)
        func ready(_ data: Data, from method: String) -> Data {
            let ms = (ProcessInfo.processInfo.systemUptime - started) * 1_000
            lastReadNote = String(format: "最近缩略图 · %@ · %.1f ms（含排队，不含解码）", method, ms)
            return data
        }
        if let hit = cache.object(forKey: key) { return ready(hit as Data, from: "内存缓存") }

        let request = Task { [cache, source] in
            // A command already on USB must finish. Skip superseded selections
            // before sending anything, and reuse a result that just arrived.
            _ = await previous?.result
            try Task.checkCancellation()
            if let hit = cache.object(forKey: key) { return ready(hit as Data, from: "内存缓存") }

            let bytes = try await source.request(.thumbnail, [entry.id])
            guard !bytes.isEmpty else { throw ExportError("相机未提供缩略图。") }
            cache.setObject(bytes as NSData, forKey: key, cost: bytes.count)
            try Task.checkCancellation()
            return ready(bytes, from: "USB GetThumb")
        }
        active = request
        return try await withTaskCancellationHandler {
            try await request.value
        } onCancel: {
            request.cancel()
        }
    }
}
