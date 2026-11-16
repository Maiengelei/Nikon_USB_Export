import AppKit

// The Nikon module can enumerate a Z8 on its first initialization and report
// no devices after FreeSDK and a second initialization in the same process.
// Give every SDK session its own process and running macOS event loop.
private func runSDK(readStorage: Bool) -> Never {
    let outputFD = dup(STDOUT_FILENO)
    guard outputFD >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else { exit(2) }
    let result = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
    alarm(45)
    _ = NSApplication.shared
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            try NikonSDKProfiles.prepare()
            let discovery: NikonDiscovery
            if readStorage {
                let camera = try NikonSDKBridge.probe()
                discovery = NikonDiscovery(names: [camera.name], interfaceName: camera.interfaceName,
                    stores: camera.stores.map { SDKStorageRecord(id: $0.storageID, error: $0.readError) })
            } else {
                discovery = NikonDiscovery(names: try NikonSDKBridge.deviceNames(), interfaceName: nil, stores: [])
            }
            try result.write(contentsOf: JSONEncoder().encode(discovery))
            try result.close()
            exit(0)
        } catch {
            try? result.write(contentsOf: Data(error.localizedDescription.utf8))
            try? result.close()
            exit(1)
        }
    }
    CFRunLoopRun()
    exit(2)
}

private let storageArgument = "--read-sdk-storage"
private let devicesArgument = "--list-sdk-devices"
if CommandLine.arguments.count == 2 {
    switch CommandLine.arguments[1] {
    case storageArgument: runSDK(readStorage: true)
    case devicesArgument: runSDK(readStorage: false)
    default: exit(2)
    }
}

final class DiscoveryService: NSObject, NikonDiscoveryProtocol, NSXPCListenerDelegate {
    private let queue = DispatchQueue(label: "local.cameratools.Z8Export.maid")

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: NikonDiscoveryProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func inspect(_ readStorage: Bool, withReply reply: @escaping (Data?, NSError?) -> Void) {
        queue.async {
            do {
                guard let executable = Bundle.main.executableURL else { throw CocoaError(.executableNotLoadable) }
                let process = Process()
                let pipe = Pipe()
                process.executableURL = executable
                process.arguments = [readStorage ? storageArgument : devicesArgument]
                process.standardOutput = pipe
                try process.run()
                let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
                process.waitUntilExit()
                guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                    let message = String(data: data, encoding: .utf8) ?? ""
                    throw NSError(domain: "NikonRemoteSDK", code: Int(process.terminationStatus),
                                  userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "尼康 SDK 进程已中断，请刷新重试。" : message])
                }
                reply(data, nil)
            } catch { reply(nil, error as NSError) }
        }
    }
}

let delegate = DiscoveryService()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
