import Foundation
import ParityContracts
import OSDParityRuntime

@main
struct OSDParityRunner {
    @MainActor
    static func main() throws {
        let outputURL = outputURL(from: CommandLine.arguments)
        let results = try OSDScenarioAdapter.runAll()
        let output = RunnerOutput(
            manifest: RunnerManifest(
                schemaVersion: 2,
                implementation: "openswiftdata",
                gitSHA: ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? "local",
                scenarios: results.map { $0.id }),
            results: results)
        let data = try CanonicalJSON.encode(output)
        try data.write(to: outputURL, options: .atomic)
        FileHandle.standardOutput.write(Data("Wrote \(results.count) scenario result(s) to \(outputURL.path)\n".utf8))
    }

    private static func outputURL(from arguments: [String]) -> URL {
        guard let index = arguments.firstIndex(of: "--output"), arguments.indices.contains(index + 1) else {
            return URL(fileURLWithPath: "osd-observations.json")
        }
        return URL(fileURLWithPath: arguments[index + 1])
    }
}
