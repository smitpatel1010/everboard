import AppKit
import Network
import ServiceManagement

/// Wake-from-sleep, network changes and the login item.
@MainActor
final class SystemEvents {
    static let shared = SystemEvents()

    private let monitor = NWPathMonitor()
    private var lastStatus: NWPath.Status?
    private var observers: [NSObjectProtocol] = []

    func start(onWake: @escaping @MainActor () -> Void, onNetworkUp: @escaping @MainActor () -> Void) {
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                // Give Wi-Fi/VPN a moment to come back before polling.
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { MainActor.assumeIsolated { onWake() } }
            })
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let changed = self.lastStatus != nil && self.lastStatus != path.status
                self.lastStatus = path.status
                // Interface changes (e.g. VPN connecting) also land here as a satisfied → satisfied update.
                if path.status == .satisfied, changed || path.usesInterfaceType(.other) { onNetworkUp() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "everboard.network"))
    }

    static var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func setLaunchAtLogin(_ on: Bool) -> String? {
        do {
            if on { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() } }
            else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
