import AppKit

// MARK: - Mini widget (CPU / RAM / GPU)
// Mirrors Stats' Mini.swift: label (7pt light) on top, value (12pt) on bottom,
// monochrome color = labelColor (white in dark mode, black in light mode).

final class MiniView: NSView {
    let label: String
    var value: Double = 0 { didSet { needsDisplay = true } }

    init(label: String) {
        self.label = label
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width

        // Label: 7pt light, y=12 from bottom (same coordinates as Stats)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .light),
            .foregroundColor: NSColor.labelColor,
        ]
        NSAttributedString(string: label, attributes: labelAttrs)
            .draw(with: CGRect(x: 0, y: 12, width: w, height: 7))

        // Value: 12pt regular, y=1 from bottom
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        let pct = Int((value * 100).rounded())
        NSAttributedString(string: "\(pct)%", attributes: valueAttrs)
            .draw(with: CGRect(x: 0, y: 1, width: w, height: 13))
    }
}

// MARK: - Speed widget (Network)
// Mirrors Stats' SpeedWidget drawTwoRows() with icon="dots", displayValueState="oi":
//   top row = upload (red dot), bottom row = download (blue dot).
// Dots are colored when traffic ≥ 1024 B/s, labelColor otherwise.

final class SpeedView: NSView {
    var upload: Int64 = 0   { didSet { needsDisplay = true } }
    var download: Int64 = 0 { didSet { needsDisplay = true } }

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
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .light),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]
        let textX: CGFloat = 7
        let textW = bounds.width - textX

        // Upload top row: y = rowH + 1
        NSAttributedString(string: fmtSpeed(upload), attributes: attrs)
            .draw(with: CGRect(x: textX, y: rowH + 1, width: textW, height: rowH))

        // Download bottom row: y = 1
        NSAttributedString(string: fmtSpeed(download), attributes: attrs)
            .draw(with: CGRect(x: textX, y: 1, width: textW, height: rowH))
    }

    private func fmtSpeed(_ bytes: Int64) -> String {
        let b = Double(bytes)
        switch b {
        case ..<1_000:           return "0 KB/s"
        case ..<1_000_000:      return "\(Int(b / 1_000)) KB/s"
        case ..<1_000_000_000:  return String(format: "%.1f MB/s", b / 1_000_000)
        default:                 return String(format: "%.1f GB/s", b / 1_000_000_000)
        }
    }
}
