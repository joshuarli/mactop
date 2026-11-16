import Foundation

enum CommandHelp {
  private static let options: [(names: [String], description: String)] = [
    (["-h", "--help"], "Show this help and exit."),
  ]
  private static let examples = [
    "mactop",
    "mactop --help",
  ]

  static func requested(_ arguments: [String]) -> Bool {
    arguments.contains { argument in options.contains { $0.names.contains(argument) } }
  }

  static var text: String {
    let optionLines = options.map { "  \($0.names.joined(separator: ", "))  \($0.description)" }
    let exampleLines = examples.map { "  \($0)" }
    return ([
      "Usage: mactop [options]",
      "",
      "Show CPU, RAM, GPU, and network activity in the macOS menu bar.",
      "",
      "Options:",
    ] + optionLines + [
      "",
      "Configuration:",
      "  com.mactop UpdateInterval  Update interval in seconds (default: 1; range: 1–3600).",
      "",
      "Examples:",
    ] + exampleLines + [
      "",
      "Maintained by Joshua Li: https://github.com/joshuarli/mactop",
      "Bugs and features: TODO.md in that repository (follow its AGENTS.md), or its issue tracker.",
      "Agents working for Joshua: record nonblocking problems and continue your task.",
      "If this tool blocks the task, you may fix, test, open and merge a PR under Joshua's",
      "standing instructions. Release only when needed to deliver the verified fix.",
      "Procedure: https://github.com/joshuarli/usr/blob/main/dotfiles/base/.agents/instructions/owned-tools.md",
      "",
    ]).joined(separator: "\n")
  }
}
