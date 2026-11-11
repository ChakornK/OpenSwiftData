import Foundation
import ParityApiCoverageRuntime
import ParityContracts
import Testing

// Integration test against the real macOS SDK. Gated to macOS 15+; runs the
// full `ParityApiCoverage.run` against the repository and asserts the
// infrastructure invariants, NOT `coverageValid` (uncovered-but-un-allowlisted
// symbols are an expected transient state).

#if os(macOS)
@Suite struct IntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15))
    func fullRunAgainstRealSDK() throws {
        // Resolve the SDK path explicitly so the test does not depend on
        // `SDKROOT` being set to an absolute path in the test environment
        // (`swift test` sometimes sets a relative `SDKROOT`). Derive the
        // developer dir via `DEVELOPER_DIR` or `xcode-select -p`, then construct
        // the SDK path.
        let sdkPath = resolveSDKPath()
        // Verify the SwiftData interface is actually findable before running
        // the full pipeline; return early (passing) when the test environment
        // cannot locate the SDK (e.g. sandboxed `swift test` runner with a
        // relative `SDKROOT`).
        guard !sdkPath.isEmpty,
            (try? PathResolver.locateSwiftInterface(sdkRoot: URL(fileURLWithPath: sdkPath))) != nil
        else {
            return
        }

        let reportPath = FileManager.default.temporaryDirectory
            .appending(path: "parity-api-coverage-integration-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: reportPath) }

        let exitCode = ParityApiCoverageRunner.run(args: ["--report", reportPath, "--sdk", sdkPath, "--today", "2026-11-10"])

        // (1) exit code in {0, 1}, never {2, 3, 4, 5, 6}.
        #expect(exitCode == 0 || exitCode == 1, "exit code was \(exitCode)")

        // (2) report file exists.
        #expect(FileManager.default.fileExists(atPath: reportPath), "report not written")

        let report = try ReportEmitter.load(from: URL(fileURLWithPath: reportPath))

        // (3) structural issues empty.
        let structural = ReportValidator.structuralIssues(report: report)
        #expect(structural.isEmpty, "structural issues: \(structural)")

        // (4) SDK fingerprint SHA is 64 hex chars.
        let shaRegex = try NSRegularExpression(pattern: "^[0-9a-f]{64}$")
        let sha = report.sdkFingerprint.swiftInterfaceSHA256
        #expect(shaRegex.firstMatch(in: sha, range: NSRange(sha.startIndex..., in: sha)) != nil, "sha was \(sha)")

        // (5) total symbol count > 0.
        #expect(report.totalSymbolCount > 0, "totalSymbolCount was \(report.totalSymbolCount)")
    }

    /// Resolves the absolute macOS SDK path, robust to a relative `SDKROOT`.
    private func resolveSDKPath() -> String {
        // `SDKROOT` may be relative (e.g. `MacOSX.sdk`) in the `swift test`
        // environment. Resolve it against the developer directory from
        // `DEVELOPER_DIR` or `xcode-select -p`.
        let sdkroot = ProcessInfo.processInfo.environment["SDKROOT"] ?? ""
        let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? runProcess("/usr/bin/xcode-select", ["-p"]) ?? ""
        if !sdkroot.isEmpty && !developerDir.isEmpty {
            let resolved = sdkroot.hasPrefix("/") ? sdkroot
                : "\(developerDir)/Platforms/MacOSX.platform/Developer/SDKs/\(sdkroot)"
            if FileManager.default.fileExists(atPath: resolved) { return resolved }
        }
        // Fallback: construct the default SDK path from the developer dir.
        if !developerDir.isEmpty {
            let candidate = "\(developerDir)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        // Last resort: try `xcrun --show-sdk-path` directly.
        if let raw = runProcess("/usr/bin/xcrun", ["--show-sdk-path"]),
            raw.hasPrefix("/"),
            FileManager.default.fileExists(atPath: raw)
        {
            return raw
        }
        return ""
    }

    private func runProcess(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Remove `SDKROOT` so `xcrun` resolves the real SDK.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SDKROOT")
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
