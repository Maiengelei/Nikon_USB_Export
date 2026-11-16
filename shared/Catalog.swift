import Foundation

struct ExportError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Slot: Int, CaseIterable, Identifiable {
    case one = 1, two
    var id: Self { self }
    var title: String { "卡 \(rawValue)" }
    var medium: String { self == .one ? "CFexpress / XQD" : "SD" }
}

struct CameraObject: Identifiable, Hashable {
    let id: UInt32
    let storage: UInt32
    let parent: UInt32
    let format: UInt16
    let name: String
    let size: UInt32

    var isFolder: Bool { format == 0x3001 }
    var isPhoto: Bool {
        guard !isFolder else { return false }
        let suffix = (name as NSString).pathExtension.lowercased()
        return ["nef", "jpg", "jpeg", "hif", "heif", "heic", "tif", "tiff"].contains(suffix)
    }

    static func validName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.utf8.contains(0)
    }
}

struct Entry: Identifiable, Hashable {
    let snapshot: UUID
    let object: CameraObject
    let path: [String]
    var id: UInt32 { object.id }
}

struct Storage: Identifiable {
    let id: UInt32
    let description: String
    let label: String
    let capacity: UInt64
    let entries: [Entry]
    let children: [UInt32: [Entry]]
    var initialFolder: Entry? {
        children[0]?.first { $0.object.isFolder && $0.object.name.caseInsensitiveCompare("DCIM") == .orderedSame }
    }

    var hexID: String { String(format: "0x%08X", id) }
    // The Z8 supplies a model-qualified slot tag in VolumeLabel. Require both the
    // literal tag and its matching storage ID so an arbitrary volume name or ID
    // in isolation can never assign a physical slot.
    var reportedSlot: Slot? { Self.reportedSlot(id: id, label: label) }

    static func reportedSlot(id: UInt32, label: String) -> Slot? {
        let label = label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return Slot.allCases.first { slot in
            label == "NIKON Z 8 [Slot \(slot.rawValue)]" && id == ((UInt32(slot.rawValue) << 16) | 1)
        }
    }

    init(id: UInt32, description: String, label: String, capacity: UInt64,
         objects: [CameraObject], roots: Set<UInt32>) throws {
        self.id = id
        self.description = description
        self.label = label
        self.capacity = capacity
        var index = [UInt32: CameraObject]()
        for object in objects {
            guard object.storage == id, object.id != 0, object.id != .max,
                  index.updateValue(object, forKey: object.id) == nil else {
                throw ExportError("存储或对象标识不一致。请刷新目录。")
            }
        }
        let expectedRoots = Set(objects.filter { $0.parent == 0 || $0.parent == .max }.map(\.id))
        guard expectedRoots == roots else { throw ExportError("相机报告的根目录与父目录记录不一致。") }

        let snapshot = UUID()
        var entries = [Entry]()
        var children = [UInt32: [Entry]]()
        var paths = [UInt32: [String]]()
        for item in objects where item.isPhoto || item.isFolder {
            var current = item
            var chain = [CameraObject]()
            var visited = Set<UInt32>()
            while paths[current.id] == nil {
                guard visited.insert(current.id).inserted, CameraObject.validName(current.name) else {
                    throw ExportError("无法还原相机目录或文件名，请检查卡内目录。")
                }
                chain.append(current)
                if roots.contains(current.id) { break }
                guard let parent = index[current.parent], parent.isFolder else {
                    throw ExportError("缺少 \(current.name) 的上级目录。")
                }
                current = parent
            }
            var path = paths[current.id] ?? []
            for component in chain.reversed() {
                path.append(component.name)
                paths[component.id] = path
            }
            let entry = Entry(snapshot: snapshot, object: item, path: path)
            entries.append(entry)
            children[roots.contains(item.id) ? 0 : item.parent, default: []].append(entry)
        }
        if entries.contains(where: { $0.object.isPhoto }) && !entries.contains(where: { $0.object.isFolder }) {
            throw ExportError("相机只列出平铺照片，未提供可核实的拍摄目录。")
        }
        self.entries = entries
        self.children = children.mapValues { items in
            items.sorted { a, b in
                if a.object.isFolder != b.object.isFolder { return a.object.isFolder }
                return a.object.name.localizedStandardCompare(b.object.name) == .orderedAscending
            }
        }
    }
}

enum ExportScope {
    case photos(storage: UInt32, parent: UInt32, ids: Set<UInt32>)
    case folder(storage: UInt32, path: [String])
    case card(Slot)
    case both
}

struct ExportItem {
    let entry: Entry
    let slot: Slot
    var path: [String] { ["卡\(slot.rawValue)"] + entry.path }
}

struct StorageFailure: LocalizedError, Identifiable {
    let id: UInt32
    let slot: Slot?
    let operation: String
    let detail: String

    var title: String {
        String(format: "%@ 0x%08X 无法读取", slot?.title ?? "存储", id)
    }

    var errorDescription: String? { "\(title) · \(operation) · \(detail)" }
}

struct Catalog {
    var stores = [Storage]()
    private(set) var slots = [UInt32: Slot]()

    let failedStores: [StorageFailure]

    var canExportBoth: Bool {
        failedStores.isEmpty && stores.count == 2 && Set(slots.values) == Set(Slot.allCases)
    }

    init(stores: [Storage] = [], failedStores: [StorageFailure] = []) {
        self.failedStores = failedStores
        self.stores = stores
        for store in stores {
            if let slot = store.reportedSlot { slots[store.id] = slot }
        }
    }

    mutating func confirm(_ slot: Slot?, for id: UInt32) throws {
        guard let store = stores.first(where: { $0.id == id }) else { throw ExportError("存储已断开。") }
        if let reported = store.reportedSlot, slot != reported {
            throw ExportError("机身已确认此存储为\(reported.title)，无法更改关联。")
        }
        if let slot, failedStores.contains(where: { $0.slot == slot }) {
            throw ExportError("\(slot.title) 本次读取失败，不能关联其他存储。")
        }
        if let slot, slots.contains(where: { $0.key != id && $0.value == slot }) {
            throw ExportError("\(slot.title) 已关联其他存储，请先解除原关联。")
        }
        slots[id] = slot
    }

    func plan(_ scope: ExportScope) throws -> [ExportItem] {
        let selected: [Storage]
        var prefix = [String]()
        switch scope {
        case let .photos(id, parent, ids):
            guard !ids.isEmpty, let store = stores.first(where: { $0.id == id }),
                  let slot = slots[id] else { throw ExportError("请选择已核对卡槽中的照片。") }
            let photos = (store.children[parent] ?? []).filter { $0.object.isPhoto && ids.contains($0.id) }
            guard photos.count == ids.count else { throw ExportError("照片选择已变化，请在当前目录重新选择。") }
            return photos.map { ExportItem(entry: $0, slot: slot) }
        case let .folder(id, path):
            guard let store = stores.first(where: { $0.id == id }),
                  !path.isEmpty, store.entries.contains(where: { $0.object.isFolder && $0.path == path })
            else { throw ExportError("请选择相机目录。") }
            selected = [store]
            prefix = path
        case let .card(slot):
            selected = stores.filter { slots[$0.id] == slot }
            guard selected.count == 1 else { throw ExportError("请先核对\(slot.title)的物理卡槽。") }
        case .both:
            guard failedStores.isEmpty else { throw ExportError("有存储无法读取，双卡导出不可用。") }
            guard canExportBoth else {
                throw ExportError("双卡导出需要两张已确认卡槽的存储卡。")
            }
            selected = stores
        }
        var result = [ExportItem]()
        for store in selected {
            guard let slot = slots[store.id] else { throw ExportError("请先确认该存储对应的物理卡槽。") }
            let photos = store.entries.filter { $0.object.isPhoto && $0.path.starts(with: prefix) }
            result += photos.map { ExportItem(entry: $0, slot: slot) }
        }
        return result
    }
}
