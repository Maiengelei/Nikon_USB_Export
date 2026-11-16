import XCTest
@testable import NikonUSBExport

final class DeviceExportTests: XCTestCase {
    @MainActor func testBothCardsWriteOriginalBytesToLocalFilesAndRetrySkips() async throws {
        let connection = IOSConnection()
        let documents = try XCTUnwrap(connection.camera.destination)
        let expected = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: false)
        XCTAssertEqual(documents.standardizedFileURL, expected.standardizedFileURL)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UIFileSharingEnabled") as? Bool, true)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool, true)
        let directory = "USB-test-\(UUID())"
        let stores = try Slot.allCases.map { slot in
            let id = (UInt32(slot.rawValue) << 16) | 1
            let folder = CameraObject(id: id + 1, storage: id, parent: 0, format: 0x3001, name: directory, size: 0)
            let photo = CameraObject(id: id + 2, storage: id, parent: folder.id, format: 0x3801, name: "SAMPLE.NEF", size: 3)
            return try Storage(id: id, description: "", label: "NIKON Z 8 [Slot \(slot.rawValue)]",
                               capacity: 100, objects: [folder, photo], roots: [folder.id])
        }
        let plan = try Catalog(stores: stores).plan(.both)
        defer {
            for slot in Slot.allCases {
                let folder = documents.appendingPathComponent("卡\(slot.rawValue)").appendingPathComponent(directory)
                try? FileManager.default.removeItem(at: folder)
            }
        }
        let destination = Destination(root: documents)
        let first = await exportPhotos(plan, destination: destination, read: { item in
            Data([0x49, 0x49, UInt8(item.slot.rawValue)])
        }, progress: { _ in })
        XCTAssertNil(first.failure)
        XCTAssertEqual(first.written, 2)
        for item in plan {
            let url = item.path.reduce(documents) { $0.appendingPathComponent($1) }
            XCTAssertEqual(try Data(contentsOf: url), Data([0x49, 0x49, UInt8(item.slot.rawValue)]))
        }
        let retry = await exportPhotos(plan, destination: destination, read: { _ in
            XCTFail("Matching files should skip the camera read")
            return Data()
        }, progress: { _ in })
        XCTAssertEqual(retry.skipped, 2)
    }
}
