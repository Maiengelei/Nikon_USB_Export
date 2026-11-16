import Foundation
import ImageCaptureCore
import Combine

@MainActor
final class IOSConnection: ObservableObject {
    enum Access { case waiting, requesting, denied, ready }
    @Published private(set) var access: Access = .waiting
    @Published private(set) var folderError: String?

    private let browser: ICDeviceBrowser
    let camera: CameraModel
    private var generation = UUID()

    init() {
        let browser = ICDeviceBrowser()
        self.browser = browser
        camera = CameraModel(browser: browser)
        prepareFolder()
    }

    private func prepareFolder() {
        do {
            camera.destination = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                             appropriateFor: nil, create: true)
            folderError = nil
        } catch {
            camera.destination = nil
            folderError = error.localizedDescription
        }
    }

    func connect(requestAccess: Bool) async {
        guard access != .requesting else { return }
        let current = generation
        prepareFolder()
        var contents = browser.contentsAuthorizationStatus
        var control = browser.controlAuthorizationStatus
        if requestAccess {
            access = .requesting
            if contents == .notDetermined { contents = await browser.requestContentsAuthorization() }
            guard current == generation else { return }
            if contents == .authorized && control == .notDetermined {
                control = await browser.requestControlAuthorization()
            }
            guard current == generation else { return }
        }
        if contents == .authorized && control == .authorized {
            access = .ready
            camera.start()
        } else {
            camera.stop()
            access = [contents, control].contains { $0 == .denied || $0 == .restricted } ? .denied : .waiting
        }
    }

    func suspend() {
        generation = UUID()
        camera.stop()
        access = .waiting
    }
}
