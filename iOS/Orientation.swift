import UIKit

final class FlickAppDelegate: NSObject, UIApplicationDelegate {
    static var allowed: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.allowed
    }
}

enum Orientation {
    /// Drive mode wants the phone held like a wheel.
    static func lock(_ mask: UIInterfaceOrientationMask, prefer: UIInterfaceOrientationMask) {
        FlickAppDelegate.allowed = mask
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: prefer)) { _ in }
    }
}
