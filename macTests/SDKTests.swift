import XCTest
@testable import NikonUSBExport

final class SDKTests: XCTestCase {
    func testEmbeddedSDKLoadsAndEnumeratesWithoutOpeningACamera() async throws {
        let result = try await NikonSDKClient.inspect(readStorage: false)
        XCTAssertTrue(result.stores.isEmpty)
        XCTAssertNil(result.interfaceName)
    }
}
