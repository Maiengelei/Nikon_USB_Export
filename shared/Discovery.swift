struct SDKStorageRecord: Codable {
    let id: UInt32
    let error: String?
}

struct NikonDiscovery: Codable {
    let names: [String]
    let interfaceName: String?
    let stores: [SDKStorageRecord]
}
