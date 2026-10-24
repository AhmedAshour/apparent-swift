import Foundation
#if canImport(SwiftUI)
import SwiftUI

public extension View {
    /// Records a `screen_view` each time this view appears: `.apparentScreen("practice/topic")`.
    func apparentScreen(_ name: String, properties: ApparentProperties? = nil) -> some View {
        onAppear { Apparent.screen(name, properties: properties) }
    }
}
#endif

#if canImport(UIKit) && !os(watchOS)
import UIKit

public extension Apparent {
    /// Optional, off unless you call it: a `screen_view` for every view controller of your own app that appears
    /// (UIKit's own containers and SwiftUI's hosting controllers are skipped). The name is the class name without
    /// "ViewController" ("SettingsViewController" → "Settings"). Call once, after `start`.
    @MainActor static func trackUIKitScreens() {
        UIKitScreens.install()
    }
}

enum UIKitScreens {
    private static var installed = false

    @MainActor static func install() {
        guard !installed else { return }
        installed = true
        let cls: AnyClass = UIViewController.self
        guard let original = class_getInstanceMethod(cls, #selector(UIViewController.viewDidAppear(_:))),
              let replacement = class_getInstanceMethod(cls, #selector(UIViewController.apparent_viewDidAppear(_:)))
        else { return }
        method_exchangeImplementations(original, replacement)
    }

    static func name(for vc: UIViewController) -> String? {
        let type: AnyClass = Swift.type(of: vc)
        // Only the app's own screens: not UINavigationController, UIHostingController, keyboards, alerts…
        guard Bundle(for: type) == Bundle.main else { return nil }
        var name = String(describing: type)
        if let dot = name.lastIndex(of: ".") { name = String(name[name.index(after: dot)...]) }
        if name.hasPrefix("UI") || name.hasPrefix("_") || name.contains("<") { return nil }
        for suffix in ["ViewController", "Controller"] where name.hasSuffix(suffix) && name.count > suffix.count {
            name.removeLast(suffix.count)
            break
        }
        return name
    }
}

extension UIViewController {
    @objc dynamic func apparent_viewDidAppear(_ animated: Bool) {
        apparent_viewDidAppear(animated) // the original, after the swap
        // Containers and children: only the screen in charge counts.
        if parent == nil || parent is UINavigationController || parent is UITabBarController,
           let name = UIKitScreens.name(for: self) {
            Apparent.screen(name)
        }
    }
}
#endif
