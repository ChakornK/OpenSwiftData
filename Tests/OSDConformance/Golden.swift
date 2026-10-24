import Foundation
import XCTest

/// Looks up named oracle traces used by conformance tests.
public enum Golden {
    /// Returns whether a named golden trace is present in the package resources.
    public static func exists(_ name: String) -> Bool {
        Bundle.module.url(forResource: resourceName(for: name), withExtension: "json") != nil
    }

    static func resourceName(for name: String) -> String {
        name.hasSuffix(".json") ? String(name.dropLast(".json".count)) : name
    }
}
