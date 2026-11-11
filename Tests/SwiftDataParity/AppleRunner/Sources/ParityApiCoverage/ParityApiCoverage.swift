import Foundation
import ParityApiCoverageRuntime

// The `parity-api-coverage` executable entry point. Delegates all logic to
// `ParityApiCoverageRunner` in the runtime module so the test target can
// exercise the same code path without depending on the executable.

@main
struct ParityApiCoverage {
    static func main() {
        Foundation.exit(ParityApiCoverageRunner.run(args: CommandLine.arguments))
    }
}
