import Foundation

@MainActor
enum NikonSDKClient {
    static func inspect(readStorage: Bool) async throws -> NikonDiscovery {
        let connection = NSXPCConnection(serviceName: "local.cameratools.Z8Export.NikonSDKService")
        connection.remoteObjectInterface = NSXPCInterface(with: NikonDiscoveryProtocol.self)
        return try await withCheckedThrowingContinuation { continuation in
            let request = SDKReply(continuation, connection)
            func interrupted() {
                Task { @MainActor in request.finish(.failure(ExportError("尼康 SDK 服务已中断，请刷新重试。"))) }
            }
            connection.interruptionHandler = { interrupted() }
            connection.invalidationHandler = { interrupted() }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                Task { @MainActor in request.finish(.failure(error)) }
            }
            guard let service = proxy as? NikonDiscoveryProtocol else {
                request.finish(.failure(ExportError("无法连接尼康 SDK 服务。")))
                return
            }
            service.inspect(readStorage) { data, error in
                Task { @MainActor in
                    do {
                        if let error { throw error }
                        guard let data else { throw ExportError("尼康 SDK 服务未返回设备清单。") }
                        request.finish(.success(try JSONDecoder().decode(NikonDiscovery.self, from: data)))
                    } catch { request.finish(.failure(error)) }
                }
            }
        }
    }
}

@MainActor
private final class SDKReply {
    private var continuation: CheckedContinuation<NikonDiscovery, Error>?
    private let connection: NSXPCConnection
    private var timeout: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<NikonDiscovery, Error>, _ connection: NSXPCConnection) {
        self.continuation = continuation
        self.connection = connection
        timeout = Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if !Task.isCancelled { finish(.failure(ExportError("等待尼康 SDK 超时，请检查机身后刷新。"))) }
        }
    }

    func finish(_ result: Result<NikonDiscovery, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        connection.interruptionHandler = nil
        connection.invalidationHandler = nil
        connection.invalidate()
        continuation.resume(with: result)
    }
}
