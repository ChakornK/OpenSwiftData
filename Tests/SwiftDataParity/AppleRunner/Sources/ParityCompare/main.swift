import Foundation
import ParityContracts

private struct AllowlistFile: Decodable {
    let differences: [AllowedDifference]
}

@main
struct ParityCompare {
    static func main() throws {
        let values = try Arguments.parse(CommandLine.arguments)
        let decoder = JSONDecoder()
        let osd = try decoder.decode(RunnerOutput.self, from: Data(contentsOf: values.osd))
        let apple = try decoder.decode(RunnerOutput.self, from: Data(contentsOf: values.apple))
        let allowlist = try decoder.decode(AllowlistFile.self, from: Data(contentsOf: values.allowlist))
        let comparison = try ParityComparator.compare(osd: osd, apple: apple, allowedDifferences: allowlist.differences)
        try CanonicalJSON.encode(comparison).write(to: values.report, options: .atomic)
        if comparison.hasUnexpectedDifferences {
            FileHandle.standardError.write(Data("Parity comparison failed. See \(values.report.path)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
        print("Parity comparison passed for \(osd.results.count) scenario(s).")
    }
}

private struct Arguments {
    let osd: URL
    let apple: URL
    let allowlist: URL
    let report: URL

    static func parse(_ arguments: [String]) throws -> Self {
        var options: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard arguments[index].hasPrefix("--"), arguments.indices.contains(index + 1) else {
                throw ArgumentError.invalidArguments
            }
            options[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let osd = options["--osd"], let apple = options["--apple"],
            let allowlist = options["--allowlist"], let report = options["--report"]
        else { throw ArgumentError.invalidArguments }
        return Self(
            osd: URL(fileURLWithPath: osd), apple: URL(fileURLWithPath: apple),
            allowlist: URL(fileURLWithPath: allowlist), report: URL(fileURLWithPath: report))
    }
}

private enum ArgumentError: Error { case invalidArguments }
