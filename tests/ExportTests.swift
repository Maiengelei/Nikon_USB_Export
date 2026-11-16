import ImageCaptureCore
import XCTest
@testable import NikonUSBExport

// Wire-format fixture with unrelated physical-store IDs in reverse order. It is
// intentionally independent of any hypothesized Z8 slot-to-StorageID mapping.
@MainActor
private final class CameraFixture: PTPReading {
    let cf: UInt32 = 0x990003, sd: UInt32 = 0x440002
    var present: [UInt32]
    var intercept: ((ReadCommand, [UInt32]) throws -> Data?)?
    var files = [UInt32: CameraObject]()
    var reads = [UInt32]()
    var thumbnailReads = [UInt32]()
    var commands = [ReadCommand]()
    var respondToThumbnail: ((UInt32) async throws -> Data)?
    var failAt: UInt32?
    var shortAt: UInt32?
    var wrongStorageAt: UInt32?

    init() {
        present = [sd, cf]
        addCard(sd, base: 100)
        addCard(cf, base: 200)
    }

    private func addCard(_ store: UInt32, base: UInt32) {
        func add(_ offset: UInt32, parent: UInt32, name: String, folder: Bool = false) {
            let id = base + offset
            files[id] = CameraObject(id: id, storage: store, parent: parent == 0 ? 0 : base + parent,
                                     format: folder ? 0x3001 : 0x3000, name: name, size: folder ? 0 : 4)
        }
        add(1, parent: 0, name: "DCIM", folder: true)
        add(2, parent: 1, name: "100NCZ_8", folder: true)
        add(3, parent: 2, name: "DSC_0001.NEF")
        add(4, parent: 2, name: "子目录", folder: true)
        add(5, parent: 4, name: "DSC_0002.HIF")
        add(6, parent: 1, name: "101NCZ_8", folder: true)
        add(7, parent: 6, name: "DSC_0003.JPG")
        add(8, parent: 2, name: "DSC_0004.MOV")
    }

    func payload(_ id: UInt32) -> Data { Data([0xaa, 0, UInt8(truncatingIfNeeded: id), 0xbb]) }

    func request(_ command: ReadCommand, _ parameters: [UInt32]) async throws -> Data {
        func bytes<T: FixedWidthInteger>(_ number: T) -> Data {
            var n = number.littleEndian
            return withUnsafeBytes(of: &n) { Data($0) }
        }
        func ids(_ entries: [UInt32]) -> Data {
            entries.reduce(into: bytes(UInt32(entries.count))) { $0.append(bytes($1)) }
        }
        func string(_ name: String) -> Data {
            Data([UInt8(name.utf16.count + 1)]) + name.data(using: .utf16LittleEndian)! + Data([0, 0])
        }
        commands.append(command)
        if let data = try intercept?(command, parameters) { return data }
        switch command {
        case .storageIDs: return ids(present)
        case .storageInfo:
            return Data(count: 6) + bytes(UInt64(128_000_000_000)) + Data(count: 12) + string("Removable") + string("Z8")
        case .objectHandles:
            XCTAssertEqual(parameters.count, 3)
            XCTAssertEqual(parameters[1], 0)
            let rows = files.values.filter { $0.storage == parameters[0] && (parameters[2] == 0 || $0.parent == 0) }
            return ids(rows.map(\.id).sorted())
        case .objectInfo:
            let item = try XCTUnwrap(files[parameters[0]])
            var raw = Data(count: 52)
            raw.replaceSubrange(0..<4, with: bytes(item.id == wrongStorageAt ? 42 : item.storage))
            raw.replaceSubrange(4..<6, with: bytes(item.format))
            raw.replaceSubrange(8..<12, with: bytes(item.size))
            raw.replaceSubrange(38..<42, with: bytes(item.parent))
            return raw + string(item.name)
        case .thumbnail:
            thumbnailReads.append(parameters[0])
            if let respondToThumbnail { return try await respondToThumbnail(parameters[0]) }
            return Data([0xff, 0xd8, 0xff, 0xd9])
        case .object:
            let id = parameters[0]
            reads.append(id)
            if id == failAt { throw ExportError("测试断线") }
            if id == shortAt { return Data([0xee]) }
            return payload(id)
        }
    }

    func confirmedCatalog() async throws -> Catalog {
        var catalog = try await CameraReader(source: self).scan { _ in }
        try catalog.confirm(.one, for: cf)
        try catalog.confirm(.two, for: sd)
        return catalog
    }
}

@MainActor
private final class DeferredUSBDevice: PTPCommandDevice {
    var hasOpenSession = true
    private(set) var tokens = [UInt32]()
    weak var delegate: USBSource?
    var onSend: ((UInt32) -> Void)?

    func sendReadPacket(_ packet: Data, transaction: UInt32, delegate: USBSource) {
        self.delegate = delegate
        tokens.append(transaction)
        var bytes = PTPBytes(data: packet, offset: 8)
        XCTAssertEqual(try bytes.number(UInt32.self), transaction)
        onSend?(transaction)
    }

    func reply(_ token: UInt32, payload: Data? = nil, code: UInt16 = 0x2001, error: NSError? = nil) {
        var raw = Data([12, 0, 0, 0, 3, 0, UInt8(truncatingIfNeeded: code), UInt8(code >> 8)])
        withUnsafeBytes(of: token.littleEndian) { raw.append(contentsOf: $0) }
        delegate?.received(nil, inData: payload as NSData?, response: raw as NSData, error: error,
                           contextInfo: UnsafeMutableRawPointer(bitPattern: UInt(token)))
    }
}

final class ExportTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor func testSDKInventoryMustMatchBeforeObjectTransfer() async throws {
        let source = CameraFixture()
        source.present = [source.sd]
        let good = SDKStorageRecord(id: source.sd, error: nil)
        let empty = SDKStorageRecord(id: 0x10000, error: nil)
        let catalog = try await CameraReader(source: source).scan(sdkStores: [empty, good]) { _ in }
        XCTAssertEqual(catalog.stores.map(\.id), [source.sd])
        XCTAssertNotNil(catalog.stores.first?.initialFolder)
        for snapshot in [[], [good, good],
                         [SDKStorageRecord(id: source.cf, error: nil)]] {
            source.commands.removeAll()
            do {
                _ = try await CameraReader(source: source).scan(sdkStores: snapshot) { _ in }
                XCTFail("Conflicting SDK and USB metadata must invalidate the catalog")
            } catch {
                XCTAssertFalse(source.commands.contains(.objectHandles))
            }
        }
    }

    @MainActor func testSDKMediaFailureKeepsOnlyHealthyCardExportable() async throws {
        let source = CameraFixture()
        let failed = SDKStorageRecord(id: source.cf, error: "MediaAccessError")
        let healthy = SDKStorageRecord(id: source.sd, error: nil)
        var catalog = try await CameraReader(source: source).scan(sdkStores: [failed, healthy]) { _ in }
        XCTAssertEqual(catalog.stores.map(\.id), [source.sd])
        XCTAssertEqual(catalog.failedStores.map(\.id), [source.cf])
        XCTAssertThrowsError(try catalog.plan(.both))
        try catalog.confirm(.two, for: source.sd)
        let items = try catalog.plan(.card(.two))
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items.allSatisfy { $0.slot == .two && $0.entry.object.storage == source.sd })
    }

    func testEmbeddedSDKLoadsAndEnumeratesWithoutOpeningACamera() async throws {
        let result = try await NikonSDKClient.inspect(readStorage: false)
        XCTAssertTrue(result.stores.isEmpty)
        XCTAssertNil(result.interfaceName)
    }

    @MainActor func testFourScopesAndNestedCardRootPaths() async throws {
        let source = CameraFixture()
        let catalog = try await source.confirmedCatalog()
        XCTAssertEqual(catalog.stores.first?.id, source.sd)
        XCTAssertEqual(catalog.stores.first?.capacity, 128_000_000_000)
        let folder = try catalog.plan(.folder(storage: source.cf, path: ["DCIM", "100NCZ_8"]))
        XCTAssertEqual(folder.map(\.entry.id), [203, 205])
        XCTAssertEqual(folder.last?.path, ["卡1", "DCIM", "100NCZ_8", "子目录", "DSC_0002.HIF"])
        XCTAssertEqual(try catalog.plan(.card(.one)).map(\.entry.id), [203, 205, 207])
        XCTAssertEqual(try catalog.plan(.card(.two)).map(\.entry.id), [103, 105, 107])
        XCTAssertEqual(try catalog.plan(.both).count, 6)
    }

    @MainActor func testSelectionExportsOnlyVisiblePhotosAndPreservesOtherPaths() async throws {
        let source = CameraFixture()
        source.files[209] = CameraObject(id: 209, storage: source.cf, parent: 202, format: 0x3801,
                                         name: "DSC_0009.JPG", size: 4)
        let catalog = try await source.confirmedCatalog()
        let selected = try catalog.plan(.photos(storage: source.cf, parent: 202, ids: [203, 209]))
        XCTAssertEqual(Set(selected.map(\.entry.id)), [203, 209])
        XCTAssertEqual(selected.first?.path, ["卡1", "DCIM", "100NCZ_8", "DSC_0001.NEF"])
        XCTAssertThrowsError(try catalog.plan(.photos(storage: source.cf, parent: 202, ids: [203, 205])))
        XCTAssertThrowsError(try catalog.plan(.photos(storage: source.sd, parent: 102, ids: [203])))
        XCTAssertThrowsError(try catalog.plan(.photos(storage: source.cf, parent: 202, ids: [204])))
        XCTAssertThrowsError(try catalog.plan(.photos(storage: source.cf, parent: 202, ids: [])))

        let destination = Destination(root: try temporaryFolder())
        XCTAssertTrue(try destination.save(Data([42]), to: selected[0].path))
        let report = await exportPhotos(selected, destination: destination, read: CameraReader(source: source).read) { _ in }
        XCTAssertNil(report.failure)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.written, 1)
        XCTAssertEqual(source.reads, [209])
        XCTAssertEqual(try Data(contentsOf: destination.root.appendingPathComponent(selected[0].path.joined(separator: "/"))), Data([42]))
    }

    @MainActor func testDCIMIsDefaultOnlyAtCardRoot() async throws {
        let source = CameraFixture()
        var catalog = try await source.confirmedCatalog()
        XCTAssertEqual(catalog.stores.map { $0.initialFolder?.path }, [["DCIM"], ["DCIM"]])
        source.files[201] = CameraObject(id: 201, storage: source.cf, parent: 0, format: 0x3001, name: "OTHER", size: 0)
        source.files[202] = CameraObject(id: 202, storage: source.cf, parent: 201, format: 0x3001, name: "DCIM", size: 0)
        catalog = try await source.confirmedCatalog()
        XCTAssertNil(catalog.stores.first(where: { $0.id == source.cf })?.initialFolder)
    }

    @MainActor func testPreviewFetchesOncePerSnapshotAndRejectsOldEntries() async throws {
        let source = CameraFixture()
        let catalog = try await source.confirmedCatalog()
        let scope = ExportScope.photos(storage: source.cf, parent: 202, ids: [203])
        let entry = try XCTUnwrap(catalog.plan(scope).first?.entry)
        let thumbnails = CatalogThumbnails(catalog: catalog, source: source)
        source.commands.removeAll()
        let first = try await thumbnails.thumbnail(for: entry)
        XCTAssertEqual(ReadCommand.thumbnail.rawValue, 0x100a)
        XCTAssertEqual(source.commands, [.thumbnail])
        XCTAssertTrue(thumbnails.lastReadNote?.contains("USB GetThumb") == true)
        let second = try await thumbnails.thumbnail(for: entry)
        XCTAssertEqual(first, second)
        XCTAssertEqual(source.commands, [.thumbnail])
        XCTAssertTrue(thumbnails.lastReadNote?.contains("内存缓存") == true)

        let fresh = try await source.confirmedCatalog()
        let next = CatalogThumbnails(catalog: fresh, source: source)
        source.commands.removeAll()
        do {
            _ = try await next.thumbnail(for: entry)
            XCTFail("An entry from an old snapshot must be rejected even if the camera reuses its metadata")
        } catch {
            XCTAssertTrue(source.commands.isEmpty)
        }
        let current = try XCTUnwrap(fresh.plan(scope).first?.entry)
        _ = try await next.thumbnail(for: current)
        XCTAssertEqual(source.commands, [.thumbnail])
    }

    @MainActor func testStaleSelectionCannotCancelCurrentSnapshotPreview() async throws {
        let source = CameraFixture()
        let old = try await source.confirmedCatalog()
        let current = try await source.confirmedCatalog()
        let scope = ExportScope.photos(storage: source.cf, parent: 202, ids: [203])
        let stale = try XCTUnwrap(old.plan(scope).first?.entry)
        let live = try XCTUnwrap(current.plan(scope).first?.entry)
        let previews = CatalogThumbnails(catalog: current, source: source)
        let started = expectation(description: "Current snapshot thumbnail sent")
        var release: CheckedContinuation<Void, Never>?
        source.respondToThumbnail = { _ in
            await withCheckedContinuation { release = $0; started.fulfill() }
            return Data([42])
        }
        let pending = Task { try await previews.thumbnail(for: live) }
        await fulfillment(of: [started], timeout: 2)
        do {
            _ = try await previews.thumbnail(for: stale)
            XCTFail("Obsolete snapshot should be ignored")
        } catch is ExportError {}
        release?.resume()
        let actual = try await pending.value
        XCTAssertEqual(actual, Data([42]))
        XCTAssertEqual(source.thumbnailReads, [live.id])
    }

    @MainActor func testRapidSelectionsSkipSupersededPreviewBeforeItReachesUSB() async throws {
        let source = CameraFixture()
        let catalog = try await source.confirmedCatalog()
        let photos = try catalog.plan(.card(.one)).map(\.entry)
        let previews = CatalogThumbnails(catalog: catalog, source: source)
        let firstSent = expectation(description: "First USB thumbnail is in flight")
        var release: CheckedContinuation<Void, Never>?
        source.respondToThumbnail = { handle in
            if handle == photos[0].id {
                await withCheckedContinuation { release = $0; firstSent.fulfill() }
            }
            return Data([UInt8(truncatingIfNeeded: handle)])
        }
        let first = Task { try await previews.thumbnail(for: photos[0]) }
        await fulfillment(of: [firstSent], timeout: 2)
        let secondStarted = expectation(description: "Second selection is waiting")
        let second = Task {
            secondStarted.fulfill()
            return try await previews.thumbnail(for: photos[1])
        }
        await fulfillment(of: [secondStarted], timeout: 2)
        let lastStarted = expectation(description: "Last selection is waiting")
        let last = Task {
            lastStarted.fulfill()
            return try await previews.thumbnail(for: photos[2])
        }
        await fulfillment(of: [lastStarted], timeout: 2)
        release?.resume()
        let data = try await last.value
        XCTAssertEqual(data, Data([UInt8(truncatingIfNeeded: photos[2].id)]))
        for task in [first, second] {
            do { _ = try await task.value; XCTFail("Superseded preview returned an image") }
            catch is CancellationError {}
        }
        XCTAssertEqual(source.thumbnailReads, [photos[0].id, photos[2].id])
        XCTAssertTrue(source.reads.isEmpty)
    }

    @MainActor func testSingleSDNeverBecomesSlotOneAndUnknownIsBlocked() async throws {
        let source = CameraFixture()
        source.present = [source.sd, 0x10000] // second entry reports no medium
        var catalog = try await CameraReader(source: source).scan { _ in }
        XCTAssertEqual(catalog.stores.count, 1)
        XCTAssertTrue(catalog.slots.isEmpty)
        XCTAssertThrowsError(try catalog.plan(.card(.one)))
        XCTAssertThrowsError(try catalog.plan(.folder(storage: source.sd, path: ["DCIM"])))
        try catalog.confirm(.two, for: source.sd)
        XCTAssertThrowsError(try catalog.plan(.both))
        XCTAssertEqual(try catalog.plan(.card(.two)).first?.path.first, "卡2")
    }

    @MainActor func testSlotClaimsMustBeUniqueAndRescanClearsThem() async throws {
        let source = CameraFixture()
        var catalog = try await source.confirmedCatalog()
        XCTAssertThrowsError(try catalog.confirm(.one, for: source.sd))
        XCTAssertEqual(catalog.slots[source.sd], .two)
        try catalog.confirm(nil, for: source.sd)
        XCTAssertThrowsError(try catalog.plan(.both))
        let fresh = try await CameraReader(source: source).scan { _ in }
        XCTAssertTrue(fresh.slots.isEmpty)
    }

    @MainActor func testSameNamesAreIsolatedAndRetrySkipsExistingBytes() async throws {
        let source = CameraFixture()
        let catalog = try await source.confirmedCatalog()
        let items = try catalog.plan(.both)
        let root = try temporaryFolder()
        let destination = Destination(root: root)
        var counts = [Int]()
        let first = await exportPhotos(items, destination: destination, read: CameraReader(source: source).read) {
            counts.append($0.processed)
        }
        XCTAssertNil(first.failure)
        XCTAssertEqual(first.written, 6)
        XCTAssertEqual(Set(counts), Set(0...6))
        for item in items {
            let url = root.appendingPathComponent(item.path.joined(separator: "/"))
            XCTAssertEqual(try Data(contentsOf: url), source.payload(item.entry.id))
        }
        let existing = root.appendingPathComponent("卡2/DCIM/100NCZ_8/DSC_0001.NEF")
        let sentinel = Data([0x42])
        try sentinel.write(to: existing)
        let second = await exportPhotos(items, destination: destination, read: CameraReader(source: source).read) { _ in }
        XCTAssertNil(second.failure)
        XCTAssertEqual(second.skipped, 6)
        XCTAssertEqual(second.written, 0)
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        XCTAssertEqual(source.reads.count, 6)
    }

    @MainActor func testDisconnectRetainsEarlierFilesAndRetryResumes() async throws {
        let source = CameraFixture()
        let catalog = try await source.confirmedCatalog()
        let items = try catalog.plan(.card(.one))
        let root = try temporaryFolder()
        source.failAt = 205
        let stopped = await exportPhotos(items, destination: Destination(root: root), read: CameraReader(source: source).read) { _ in }
        XCTAssertNotNil(stopped.failure)
        XCTAssertEqual(stopped.processed, 1)
        XCTAssertEqual(stopped.total, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(items[1].path.joined(separator: "/")).path))
        source.failAt = nil
        let retry = await exportPhotos(items, destination: Destination(root: root), read: CameraReader(source: source).read) { _ in }
        XCTAssertNil(retry.failure)
        XCTAssertEqual(retry.skipped, 1)
        XCTAssertEqual(retry.written, 2)
    }

    @MainActor func testShortReadAndStaleObjectAreNeverPublished() async throws {
        let source = CameraFixture()
        let catalog = try await source.confirmedCatalog()
        let items = try catalog.plan(.card(.one))
        let root = try temporaryFolder()
        for stale in [false, true] {
            source.shortAt = stale ? nil : 203
            source.wrongStorageAt = stale ? 203 : nil
            let state = await exportPhotos(items, destination: Destination(root: root), read: CameraReader(source: source).read) { _ in }
            XCTAssertNotNil(state.failure)
            XCTAssertEqual(state.written, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(items[0].path.joined(separator: "/")).path))
        }
    }

    @MainActor func testInvalidDestinationStopsBeforeCameraRead() async throws {
        let source = CameraFixture()
        let items = try await source.confirmedCatalog().plan(.card(.one))
        let root = try temporaryFolder()
        try Data([1]).write(to: root.appendingPathComponent("卡1"))
        let state = await exportPhotos(items, destination: Destination(root: root), read: CameraReader(source: source).read) { _ in }
        XCTAssertNotNil(state.failure)
        XCTAssertEqual(state.processed, 0)
        XCTAssertTrue(source.reads.isEmpty)
    }

    func testExclusivePublishAndSymlinkDirectory() async throws {
        let root = try temporaryFolder(), other = try temporaryFolder()
        let destination = Destination(root: root)
        let name = ["卡1", "one.NEF"]
        async let a = Task.detached { try destination.save(Data([1]), to: name) }.value
        async let b = Task.detached { try destination.save(Data([2]), to: name) }.value
        let outcomes = try await [a, b]
        XCTAssertEqual(outcomes.filter { $0 }.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("卡1").path), ["one.NEF"])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("卡2"), withDestinationURL: other)
        XCTAssertThrowsError(try destination.save(Data([1]), to: ["卡2", "photo.NEF"]))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
    }

    func testBrokenFolderChainsAndInvalidNamesAreRejected() throws {
        func store(name: String, parent: UInt32, roots: Set<UInt32>) throws -> Storage {
            let entry = CameraObject(id: 4, storage: 1, parent: parent, format: 0x3001, name: name, size: 0)
            return try Storage(id: 1, description: "", label: "", capacity: 0, objects: [entry], roots: roots)
        }
        XCTAssertThrowsError(try store(name: "DCIM", parent: 4, roots: []))
        XCTAssertThrowsError(try store(name: "DCIM", parent: 99, roots: []))
        XCTAssertThrowsError(try store(name: "DCIM", parent: 0, roots: []))
        for bad in ["..", ".", "DCIM/../out", "\0", ""] {
            XCTAssertThrowsError(try store(name: bad, parent: 0, roots: [4]))
        }
    }

    @MainActor func testEmptyStoreAndEmptyScope() async throws {
        let source = CameraFixture()
        source.present = [source.sd]
        source.files = [:]
        var notes = [String]()
        var catalog = try await CameraReader(source: source).scan(evidence: { notes.append($0) }) { _ in }
        XCTAssertTrue(notes.contains("对象 0 个，根级对象 0 个"))
        try catalog.confirm(.two, for: source.sd)
        let items = try catalog.plan(.card(.two))
        let report = await exportPhotos(items, destination: Destination(root: try temporaryFolder()),
                                        read: CameraReader(source: source).read) { _ in }
        XCTAssertEqual(report.total, 0)
        XCTAssertNil(report.failure)
        XCTAssertTrue(source.reads.isEmpty)
    }

    func testPhotoOnlyFlatViewCannotMasqueradeAsOriginalFolders() throws {
        let item = CameraObject(id: 5, storage: 1, parent: 0, format: 0x3801, name: "pic.JPG", size: 4)
        XCTAssertThrowsError(try Storage(id: 1, description: "", label: "", capacity: 0, objects: [item], roots: [5]))
    }

    func testNikonSlotTagRequiresMatchingStorageID() throws {
        func empty(_ id: UInt32, _ label: String) throws -> Storage {
            try Storage(id: id, description: "", label: label, capacity: 0, objects: [], roots: [])
        }
        let sd = try empty(0x00020001, "NIKON Z 8   [Slot 2]")
        let cf = try empty(0x00010001, "NIKON Z 8   [Slot 1]")
        XCTAssertEqual(Catalog(stores: [sd]).slots, [sd.id: .two])
        XCTAssertEqual(Catalog(stores: [sd, cf]).slots, [sd.id: .two, cf.id: .one])
        XCTAssertNil(try empty(0x00010001, sd.label).reportedSlot)
        XCTAssertNil(try empty(sd.id, "SD").reportedSlot)
        XCTAssertNil(try empty(sd.id, "NIKON Z 8   [Slot 2] COPY").reportedSlot)
    }

    @MainActor func testUnreadableCardInEitherPositionKeepsHealthyCardExportable() async throws {
        for faultFirst in [true, false] {
            let source = CameraFixture()
            let bad = source.cf
            source.present = faultFirst ? [bad, source.sd] : [source.sd, bad]
            var badRequests = [ReadCommand]()
            source.intercept = { command, params in
                if params.first == bad {
                    badRequests.append(command)
                    throw PTPResponseError(command: command, code: 0x2013)
                }
                return nil
            }
            var notes = [String]()
            var catalog = try await CameraReader(source: source).scan(evidence: { notes.append($0) }) { _ in }
            XCTAssertEqual(catalog.stores.map(\.id), [source.sd])
            let failure = try XCTUnwrap(catalog.failedStores.first)
            XCTAssertEqual(failure.id, bad)
            XCTAssertNil(failure.slot)
            XCTAssertEqual(failure.operation, "GetStorageInfo")
            XCTAssertTrue(notes.contains(where: { $0.contains("0x00990003") && $0.contains("0x2013") }))
            XCTAssertEqual(badRequests, [.storageInfo])
            XCTAssertFalse(catalog.canExportBoth)
            XCTAssertThrowsError(try catalog.confirm(.one, for: bad))
            try catalog.confirm(.two, for: source.sd)
            XCTAssertEqual(try catalog.plan(.card(.two)).map(\.entry.id), [103, 105, 107])
            XCTAssertThrowsError(try catalog.plan(.both))
        }
    }

    @MainActor func testObjectReadAndParentChainFaultsDiscardOnlyAffectedStore() async throws {
        for malformed in [false, true] {
            let source = CameraFixture()
            source.intercept = { command, params in
                guard command == .objectInfo, params == [205] else { return nil }
                if malformed { return Data([0xff]) }
                throw PTPResponseError(command: command, code: 0xa022)
            }
            let result = try await CameraReader(source: source).scan { _ in }
            XCTAssertEqual(result.stores.map(\.id), [source.sd])
            XCTAssertEqual(result.failedStores.first?.operation, "GetObjectInfo")
            XCTAssertEqual(result.failedStores.first?.id, source.cf)
        }
        let source = CameraFixture()
        source.wrongStorageAt = 205
        let result = try await CameraReader(source: source).scan { _ in }
        XCTAssertEqual(result.failedStores.first?.operation, "校验目录")
        XCTAssertEqual(result.stores.map(\.id), [source.sd])
    }

    @MainActor func testSessionFaultsAndStorageIDFailureAbortEntireScan() async throws {
        let faults: [Error] = [PTPResponseError(command: .storageInfo, code: 0x2003),
                               PTPResponseError(command: .storageInfo, code: 0x2019),
                               URLError(.timedOut), CancellationError()]
        for fault in faults {
            let source = CameraFixture()
            let last = source.cf
            source.intercept = { command, params in
                if command == .storageInfo, params == [last] { throw fault }
                return nil
            }
            do {
                _ = try await CameraReader(source: source).scan { _ in }
                XCTFail("A session-wide failure must discard even an already scanned store")
            } catch {
                XCTAssertFalse(error is StorageFailure)
                XCTAssertEqual(error.localizedDescription, fault.localizedDescription)
            }
        }
        let source = CameraFixture()
        source.intercept = { command, _ in
            if command == .storageIDs { throw PTPResponseError(command: command, code: 0x2013) }
            return nil
        }
        do {
            _ = try await CameraReader(source: source).scan { _ in }
            XCTFail("Cannot attribute a failed GetStorageIDs to either slot")
        } catch {
            XCTAssertEqual((error as? PTPResponseError)?.command, .storageIDs)
        }
    }

    @MainActor func testInFlightCancellationWaitsForCallbackAndContinuesTransactionSequence() async throws {
        let device = DeferredUSBDevice()
        let source = USBSource(camera: device, timeoutNanoseconds: 2_000_000_000)
        let firstSent = expectation(description: "First transaction submitted")
        device.onSend = { _ in firstSent.fulfill() }
        let first = Task { try await source.request(.thumbnail, [42]) }
        await fulfillment(of: [firstSent], timeout: 1)
        first.cancel()

        let premature = expectation(description: "No new transaction before the old callback")
        premature.isInverted = true
        device.onSend = { _ in premature.fulfill() }
        let second = Task { try await source.request(.storageIDs, []) }
        await fulfillment(of: [premature], timeout: 0.05)

        let secondSent = expectation(description: "New transaction submitted after callback")
        device.onSend = { _ in secondSent.fulfill() }
        device.reply(1, payload: Data([1]))
        await fulfillment(of: [secondSent], timeout: 1)
        device.reply(1, payload: Data([99])) // duplicate late callback for the cancelled preview
        device.reply(2, payload: Data([2]))
        do {
            _ = try await first.value
            XCTFail("Cancelled request returned stale preview bytes")
        } catch { XCTAssertTrue(error is CancellationError) }
        let current = try await second.value
        XCTAssertEqual(current, Data([2]))
        XCTAssertEqual(device.tokens, [1, 2])
    }

    @MainActor func testDeadlineAndSystemTimeoutRequireANewDeviceSession() async {
        for systemTimeout in [false, true] {
            let device = DeferredUSBDevice()
            let source = USBSource(camera: device, timeoutNanoseconds: 50_000_000)
            if systemTimeout {
                device.onSend = { [weak device] token in
                    device?.reply(token, code: 0x2013, error: NSError(domain: ICErrorDomain,
                                       code: ICReturn.Code.communicationTimedOut.rawValue))
                }
            }
            for _ in 0..<2 {
                do {
                    _ = try await source.request(.storageInfo, [1])
                    XCTFail("A timed-out session should require reconnecting")
                } catch { XCTAssertTrue(error.localizedDescription.contains("重新连接")) }
                device.reply(1, payload: Data([99]))
            }
            XCTAssertEqual(device.tokens, [1])
        }
    }

    @MainActor func testGenericPassThroughErrorKeepsCameraResponseAndTransportFailureStaysGlobal() async {
        for passthrough in [false, true] {
            let device = DeferredUSBDevice()
            let source = USBSource(camera: device, timeoutNanoseconds: 1_000_000_000)
            let systemError = passthrough
                ? NSError(domain: ICErrorDomain, code: ICReturn.Code.failedToCompletePassThroughCommand.rawValue)
                : NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
            device.onSend = { [weak device] token in device?.reply(token, code: 0x2013, error: systemError) }
            do {
                _ = try await source.request(.storageInfo, [1])
                XCTFail("Camera response should be an error")
            } catch {
                if passthrough {
                    XCTAssertEqual((error as? PTPResponseError)?.code, 0x2013)
                } else {
                    XCTAssertEqual(error as NSError, systemError)
                }
            }
        }
    }

    func testPTPCommandBytesAndResponseValidation() throws {
        let commands: [ReadCommand] = [.storageIDs, .storageInfo, .objectHandles, .objectInfo, .object, .thumbnail]
        let expected: [UInt16] = [0x9209, 0x1005, 0x1007, 0x1008, 0x1009, 0x100a]
        for (command, opcode) in zip(commands, expected) {
            var packet = PTPBytes(data: command.packet(transaction: 1, parameters: []), offset: 6)
            XCTAssertEqual(try packet.number(UInt16.self), opcode)
        }
        XCTAssertEqual(ReadCommand.object.packet(transaction: 7, parameters: [0x12345678]),
                       Data([16,0,0,0, 1,0, 9,16, 7,0,0,0, 0x78,0x56,0x34,0x12]))
        try PTPBytes.checkResponse(Data([12,0,0,0,3,0,1,32,7,0,0,0]), to: .object)
        XCTAssertThrowsError(try PTPBytes.checkResponse(Data([12,0,0,0,3,0,2,32,7,0,0,0]), to: .object))
        XCTAssertThrowsError(try PTPBytes.object(Data(count: 51), id: 1))
        XCTAssertThrowsError(try PTPBytes.identifiers(Data([1,0,0,0])))
    }
}
