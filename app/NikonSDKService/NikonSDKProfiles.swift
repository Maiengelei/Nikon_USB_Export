import Foundation

enum NikonSDKProfiles {
    // Install matching profiles at the per-user location fixed by the SDK.
    private static func profileError(_ message: String) -> NSError {
        NSError(domain: "NikonSDKProfiles", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func prepare(bundle: Bundle = .main) throws {
        let fm = FileManager.default
        let library = try fm.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let folder = library.appendingPathComponent("Preferences/Nikon/NXTether", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in ["DC_PTP_Config", "MaidLayer", "RangeValue"] {
            guard let resource = bundle.url(forResource: file, withExtension: "config", subdirectory: "NikonProfiles") else {
                throw profileError("应用中缺少尼康 SDK 配置 " + file + ".config。")
            }
            let target = folder.appendingPathComponent(resource.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                guard fm.contentsEqual(atPath: target.path, andPath: resource.path) else {
                    throw profileError("尼康 SDK 配置版本不一致，请核对 " + target.path)
                }
            } else {
                let temp = folder.appendingPathComponent(UUID().uuidString + ".tmp")
                defer { try? fm.removeItem(at: temp) }
                try fm.copyItem(at: resource, to: temp)
                // Atomically publish the complete profile, including concurrent launches.
                if link(temp.path, target.path) != 0 {
                    guard errno == EEXIST, fm.contentsEqual(atPath: target.path, andPath: resource.path) else {
                        throw profileError("无法安装尼康 SDK 配置，请核对 " + target.path)
                    }
                }
            }
        }
    }
}
