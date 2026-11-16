import Foundation

// The private service accepts no paths, camera commands or export destinations.
@objc(NikonDiscoveryProtocol) protocol NikonDiscoveryProtocol {
    func inspect(_ readStorage: Bool, withReply reply: @escaping (Data?, NSError?) -> Void)
}
