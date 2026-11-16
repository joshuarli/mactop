import Foundation
import XCTest

final class CommandHelpTests: XCTestCase {
  private func runHelp(_ arguments: [String]) throws -> (Int32, String, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(".build/debug/mactop")
    process.arguments = arguments
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    return (
      process.terminationStatus,
      String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
      String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    )
  }

  func testBuiltHelpAndExamples() throws {
    let short = try runHelp(["-h"])
    let long = try runHelp(["--help"])
    XCTAssertEqual(short.0, 0)
    XCTAssertEqual(long.0, 0)
    XCTAssertEqual(short.2, "")
    XCTAssertEqual(long.2, "")
    XCTAssertEqual(short.1, long.1)
    let help = long.1
    XCTAssertTrue(help.hasPrefix("Usage: mactop [options]\n"))
    XCTAssertTrue(help.contains("-h, --help  Show this help and exit."))
    XCTAssertTrue(help.contains("UpdateInterval  Update interval in seconds (default: 1; range: 1–3600)."))
    XCTAssertTrue(help.contains("Examples:\n  mactop\n  mactop --help\n"))
    let footer = """
      Maintained by Joshua Li: https://github.com/joshuarli/mactop
      Bugs and features: TODO.md in that repository (follow its AGENTS.md), or its issue tracker.
      Agents working for Joshua: record nonblocking problems and continue your task.
      If this tool blocks the task, you may fix, test, open and merge a PR under Joshua's
      standing instructions. Release only when needed to deliver the verified fix.
      Procedure: https://github.com/joshuarli/usr/blob/main/dotfiles/base/.agents/instructions/owned-tools.md

      """
    XCTAssertTrue(help.hasSuffix(footer))
    XCTAssertEqual(help.components(separatedBy: "Maintained by Joshua Li:").count, 2)
    let examples = try XCTUnwrap(help.components(separatedBy: "Examples:\n").last?
      .components(separatedBy: "\n\n").first)
    for example in examples.split(separator: "\n") {
      let words = example.split(separator: " ").map(String.init)
      XCTAssertEqual(words.first, "mactop")
      XCTAssertTrue(words.dropFirst().allSatisfy { ["-h", "--help"].contains($0) })
      if words.count > 1 {
        let result = try runHelp(Array(words.dropFirst()))
        XCTAssertEqual(result.0, 0)
        XCTAssertEqual(result.1, help)
        XCTAssertEqual(result.2, "")
      }
    }
  }
}
