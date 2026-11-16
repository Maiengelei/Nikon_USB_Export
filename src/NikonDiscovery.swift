import Foundation

// The private service accepts no paths, camera commands or export destinations.
@objc(NikonDiscoveryProtocol) protocol NikonDiscoveryProtocol {
    func inspect(_ readStorage: Bool, withReply reply: @escaping (Data?, NSError?) -> Void)
}

struct SDKStorageRecord: Codable {
    let id: UInt32
    let error: String?
}

struct NikonDiscovery: Codable {
    let names: [String]
    let interfaceName: String?
    let stores: [SDKStorageRecord]
}
