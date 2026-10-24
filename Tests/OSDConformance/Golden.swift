import Foundation
import XCTest

/// Looks up named oracle traces used by conformance tests.
public enum Golden {
    /// Returns whether a named golden trace is present in the package resources.
    public static func exists(_ name: String) -> Bool {
        url(for: name) != nil
    }

    /// Returns the URL of a named golden trace, if it is present.
    public static func url(for name: String) -> URL? {
        Bundle.module.url(forResource: resourceName(for: name), withExtension: "json")
    }

    static func resourceName(for name: String) -> String {
        name.hasSuffix(".json") ? String(name.dropLast(".json".count)) : name
    }
}
