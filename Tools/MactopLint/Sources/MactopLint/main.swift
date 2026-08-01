import Foundation
import SwiftParser

private struct Violation {
    let path: String
    let line: Int
    let message: String
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
let sourceRoot = root.appendingPathComponent("Sources")
let files = (FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
    .filter { $0.pathExtension == "swift" }
let platformPrefix = "Sources/mactop/Platform/"
let corePrefix = "Sources/mactop/Core/"
let forbiddenCore = [
    "unsafe", "OpaquePointer", "UnsafePointer", "UnsafeMutablePointer", "UnsafeRawPointer",
    "UnsafeMutableRawPointer", "withUnsafe", "unsafeBitCast", "String(cString:", "sqlite3_",
    "host_processor_info", "host_statistics", "sysctl", "getifaddrs", "IOKit", "FSEvent",
    "dlopen", "proc_pid", "proc_list", "Unmanaged", "@convention(c)",
]
private var violations: [Violation] = []

for file in files {
    let source = try String(contentsOf: file, encoding: .utf8)
    _ = Parser.parse(source: source)
    let path = file.path.replacingOccurrences(of: root.path + "/", with: "")
    let isPlatform = path.hasPrefix(platformPrefix)
    let isCore = path.hasPrefix(corePrefix)
    for (index, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.hasPrefix("//") else { continue }
        let lineNumber = index + 1
        if isCore {
            for symbol in forbiddenCore where line.contains(symbol) {
                violations.append(Violation(path: path, line: lineNumber, message: "mactopCore may not contain \(symbol); move the boundary to mactopPlatform"))
            }
        }
        if isCore, (line.contains("import IOKit") || line.contains("import SystemConfiguration") || line.contains("import SQLite3")) {
            violations.append(Violation(path: path, line: lineNumber, message: "platform imports must live under Sources/mactop/Platform"))
        }
        if line.hasPrefix("import ") { continue }
        if (path.hasPrefix("Sources/mactop/UI/") || path.hasPrefix("Sources/mactopBench/")), line.contains("String(format:") {
            violations.append(Violation(path: path, line: lineNumber, message: "use typed FormatStyle formatting instead of String(format:)"))
        }
        if !isPlatform, line.contains("OpaquePointer") || (!isPlatform && line.contains("sqlite3_")) {
            violations.append(Violation(path: path, line: lineNumber, message: "raw SQLite symbols must live under Sources/mactop/Platform"))
        }
    }
}

for violation in violations.sorted(by: { ($0.path, $0.line, $0.message) < ($1.path, $1.line, $1.message) }) {
    print("\(violation.path):\(violation.line): error: \(violation.message)")
}
exit(violations.isEmpty ? 0 : 1)
