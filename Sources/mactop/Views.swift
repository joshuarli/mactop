import AppKit

// MARK: - Mini widget (CPU / RAM / GPU)
// Mirrors Stats' Mini.swift: label (7pt light) on top, value (12pt) on bottom,
// monochrome color = labelColor (white in dark mode, black in light mode).

final class MiniView: NSView {
    let label: String
    private let labelString: NSAttributedString
    private var valueString: NSAttributedString
    private var displayedPercent = 0

    var value: Double = 0 {
        didSet {
            let percent = Int((value * 100).rounded())
            if percent != displayedPercent {
                displayedPercent = percent
                valueString = NSAttributedString(string: "\(percent)%", attributes: Self.valueAttrs)
                needsDisplay = true
            }
        }
    }

    func showPlaceholder() {
        displayedPercent = -1
        valueString = NSAttributedString(string: "--", attributes: Self.valueAttrs)
        needsDisplay = true
    }

    private static let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 7, weight: .light),
        .foregroundColor: NSColor.labelColor,
    ]

    private static let valueAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor.labelColor,
    ]

    init(label: String) {
        self.label = label
        self.labelString = NSAttributedString(string: label, attributes: Self.labelAttrs)
        self.valueString = NSAttributedString(string: "0%", attributes: Self.valueAttrs)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width

        // Label: 7pt light, y=12 from bottom (same coordinates as Stats)
        labelString.draw(with: CGRect(x: 0, y: 12, width: w, height: 7))

        // Value: 12pt regular, y=1 from bottom
        valueString.draw(with: CGRect(x: 0, y: 1, width: w, height: 13))
    }
}

// MARK: - Power widget

final class PowerView: NSView {
    private let labelString: NSAttributedString
    private var valueString: NSAttributedString
    private var displayedValue = "--W"

    var watts: Double? = nil {
        didSet {
            let text = watts.map(Self.fmtWatts) ?? "--W"
            guard text != displayedValue else { return }
            displayedValue = text
            valueString = NSAttributedString(string: text, attributes: Self.valueAttrs)
            needsDisplay = true
        }
    }

    func showPlaceholder() {
        displayedValue = "--W"
        valueString = NSAttributedString(string: "--W", attributes: Self.valueAttrs)
        needsDisplay = true
    }

    private static let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 7, weight: .light),
        .foregroundColor: NSColor.labelColor,
    ]

    private static let valueAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.labelColor,
    ]

    override init(frame: NSRect) {
        labelString = NSAttributedString(string: "PWR", attributes: Self.labelAttrs)
        valueString = NSAttributedString(string: "--W", attributes: Self.valueAttrs)
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        labelString.draw(with: CGRect(x: 0, y: 12, width: w, height: 7))
        valueString.draw(with: CGRect(x: 0, y: 1, width: w, height: 13))
    }

    private static func fmtWatts(_ watts: Double) -> String {
        switch watts {
        case ..<10:
            return String(format: "%.1fW", watts)
        default:
            return String(format: "%.0fW", watts)
        }
    }
}

// MARK: - Speed widget (Network)
// Mirrors Stats' SpeedWidget drawTwoRows() with icon="dots", displayValueState="oi":
//   top row = upload (red dot), bottom row = download (blue dot).
// Dots are colored when traffic ≥ 1024 B/s, labelColor otherwise.

final class SpeedView: NSView {
    private var uploadText = "0 KB/s"
    private var downloadText = "0 KB/s"

    var upload: Int64 = 0 {
        didSet {
            guard upload != oldValue else { return }
            uploadText = Self.fmtSpeed(upload)
            needsDisplay = true
        }
    }
    var download: Int64 = 0 {
        didSet {
            guard download != oldValue else { return }
            downloadText = Self.fmtSpeed(download)
            needsDisplay = true
        }
    }

    func showPlaceholder() {
        upload = -1
        download = -1
        uploadText = "--"
        downloadText = "--"
        needsDisplay = true
    }

    private static let textAttrs: [NSAttributedString.Key: Any] = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        return [
            .font: NSFont.systemFont(ofSize: 9, weight: .light),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]
    }()

    override init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height       // ~18px
        let rowH = h / 2            // ~9px
        let dotSize: CGFloat = 6
        let dotY = (rowH - dotSize) / 2  // centers dot in its half-row

        // Upload dot (top half): y=10.5 — matches Stats' hardcoded value
        let upColor: NSColor = upload >= 1024 ? .systemRed : .labelColor
        upColor.setFill()
        NSBezierPath(ovalIn: CGRect(x: 0, y: 10.5, width: dotSize, height: dotSize)).fill()

        // Download dot (bottom half): y=dotY-0.2
        let downColor: NSColor = download >= 1024 ? .systemBlue : .labelColor
        downColor.setFill()
        NSBezierPath(ovalIn: CGRect(x: 0, y: dotY - 0.2, width: dotSize, height: dotSize)).fill()

        // Values: 9pt light, right-aligned, starting at x=7 (after dots)
        let textX: CGFloat = 7
        let textW = bounds.width - textX

        // Upload top row: y = rowH + 1
        NSAttributedString(string: uploadText, attributes: Self.textAttrs)
            .draw(with: CGRect(x: textX, y: rowH + 1, width: textW, height: rowH))

        // Download bottom row: y = 1
        NSAttributedString(string: downloadText, attributes: Self.textAttrs)
            .draw(with: CGRect(x: textX, y: 1, width: textW, height: rowH))
    }

    private static func fmtSpeed(_ bytes: Int64) -> String {
        let b = Double(bytes)
        switch b {
        case ..<1_000:           return "0 KB/s"
        case ..<1_000_000:      return "\(Int(b / 1_000)) KB/s"
        case ..<1_000_000_000:  return String(format: "%.1f MB/s", b / 1_000_000)
        default:                 return String(format: "%.1f GB/s", b / 1_000_000_000)
        }
    }
}
