import Foundation
import ObjectiveC
import UIKit

@MainActor
enum SileoPackageHandoff {
    static var isInstalled: Bool {
        guard let scheme = URL(string: "sileo://") else { return false }
        return UIApplication.shared.canOpenURL(scheme)
    }

    /// Use Launch Services to target Sileo's document importer. The URL
    /// scheme only detects availability; it does not accept local packages.
    /// The return value only reports whether Launch Services accepted the URL.
    static func open(_ file: URL) -> Bool {
        let sharedWorkspace = NSSelectorFromString("defaultWorkspace")
        let openDocument = NSSelectorFromString("openSensitiveURL:withOptions:")
        guard let type = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              class_getClassMethod(type, sharedWorkspace) != nil,
              let workspace = type.perform(sharedWorkspace)?.takeUnretainedValue(),
              let method = class_getInstanceMethod(type, openDocument),
              method_getNumberOfArguments(method) == 4,
              let encoding = method_getTypeEncoding(method), encoding.pointee == 66
        else { return false } // BOOL is encoded as B on arm64.
        typealias OpenDocument = @convention(c) (AnyObject, Selector, NSURL, NSDictionary) -> Bool
        let open = unsafeBitCast(method_getImplementation(method), to: OpenDocument.self)
        return open(workspace, openDocument, file as NSURL, [
            "LSOpenApplicationIdentifier": "org.coolstar.SileoStore",
        ] as NSDictionary)
    }
}
