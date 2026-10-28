import Bylaws

let app = Codebase(including: ["Sources/mactop/**"])
let core = Codebase(
  including: ["Sources/mactop/Core/**", "Sources/mactop/Platform/**"]
)
let checkedTypes = Codebase(
  including: ["Sources/mactop/**"],
  excluding: [
    "Sources/mactop/Platform/NetworkStatisticsPlatform.swift",
    "Sources/mactop/Platform/PowerTelemetryPlatform.swift",
    "Sources/mactop/Core/Power/PowerTelemetryReader.swift",
  ]
)

let layers = Layering(
  Layer("mactopPlatform", files: ["Sources/mactop/Platform/**"]),
  Layer(
    "mactopCore",
    files: ["Sources/mactop/Core/**"],
    mayImport: ["mactopPlatform"]
  ),
  Layer("mactop", files: ["Sources/mactop/UI/**"], mayImport: ["mactopCore"])
)

let rules: [Rule] = [
  Rule(
    "module-boundaries",
    "Modules follow their declared dependencies",
    hint: "keep the dependency inside its layer or invert it"
  ) {
    try await app.checkLayering(layers)
  },

  Rule(
    "ui-free-core",
    "Core and Platform stay free of UI frameworks",
    hint: "keep AppKit and QuickLook in the UI layer"
  ) {
    try await core.files.violations(
      matching: .imports(
        "AppKit",
        "Cocoa",
        "SwiftUI",
        "UIKit",
        "QuickLookUI",
        "QuickLookThumbnailing"
      )
    )
  },

  Rule(
    "final-classes",
    "Classes are final",
    hint: "mark the class final or exclude a deliberate extension point"
  ) {
    try await app.classes.violations(of: .isFinal)
  },

  Rule(
    "checked-concurrency",
    "Sources use checked concurrency annotations",
    hint: "use structured isolation instead of an unchecked escape hatch"
  ) {
    try await app.properties.violations(matching: .isNonisolatedUnsafe)
    try await checkedTypes.types.violations(
      matching: .declaresInheritance("@unchecked Sendable")
    )
    try await app.imports.violations(matching: .hasAttribute("preconcurrency"))
  },

  Rule(
    "no-task-sleep",
    "Sources advance on demand instead of sleeping",
    hint: "drive progress from demand completion, not a timer"
  ) {
    try await app.calls.violations(matching: .references("Task.sleep"))
  },

  Rule(
    "no-print",
    "Shipped sources do not call print",
    hint: "remove the call or route it through logging"
  ) {
    try await app.calls.violations(matching: .references("print"))
  },
]
