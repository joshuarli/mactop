import AppKit
import mactopCore

func safePercentage(_ value: Double) -> Int {
  guard value.isFinite else { return 0 }
  return Int((min(max(value, 0), 1) * 100).rounded())
}


final class PercentageStatusItemView: NSView {
  let label: String
  private let labelString: NSAttributedString
  private var valueString: NSAttributedString
  private var displayedPercent = 0

  var value: Double = 0 {
    didSet {
      let percent = safePercentage(value)
      if percent != displayedPercent {
        displayedPercent = percent
        valueString = NSAttributedString(string: "\(percent)%", attributes: Self.valueAttrs)
        needsDisplay = true
      }
    }
  }

  func showPercentagePlaceholder() {
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

    labelString.draw(with: CGRect(x: 0, y: 12, width: w, height: 7))

    valueString.draw(with: CGRect(x: 0, y: 1, width: w, height: 13))
  }
}


final class NetworkSpeedStatusItemView: NSView {
  private var uploadText = "0 KB/s"
  private var downloadText = "0 KB/s"

  var upload: Double = 0 {
    didSet {
      guard upload != oldValue else { return }
      uploadText = Self.formatNetworkSpeed(upload)
      needsDisplay = true
    }
  }
  var download: Double = 0 {
    didSet {
      guard download != oldValue else { return }
      downloadText = Self.formatNetworkSpeed(download)
      needsDisplay = true
    }
  }

  func showNetworkSpeedPlaceholder() {
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
    let h = bounds.height
    let rowH = h / 2
    let dotSize: CGFloat = 6
    let dotY = (rowH - dotSize) / 2

    let upColor: NSColor = upload >= 1024 ? .systemRed : .labelColor
    upColor.setFill()
    NSBezierPath(ovalIn: CGRect(x: 0, y: 10.5, width: dotSize, height: dotSize)).fill()

    let downColor: NSColor = download >= 1024 ? .systemBlue : .labelColor
    downColor.setFill()
    NSBezierPath(ovalIn: CGRect(x: 0, y: dotY - 0.2, width: dotSize, height: dotSize)).fill()

    let textX: CGFloat = 7
    let textW = bounds.width - textX

    NSAttributedString(string: uploadText, attributes: Self.textAttrs)
      .draw(with: CGRect(x: textX, y: rowH + 1, width: textW, height: rowH))

    NSAttributedString(string: downloadText, attributes: Self.textAttrs)
      .draw(with: CGRect(x: textX, y: 1, width: textW, height: rowH))
  }

  private static func formatNetworkSpeed(_ bytes: Double) -> String {
    let b = bytes.isFinite ? max(0, bytes) : 0
    switch b {
    case ..<1_000: return "0 KB/s"
    case ..<1_000_000: return "\(Int(b / 1_000)) KB/s"
    case ..<1_000_000_000: return MactopFormat.string("%.1f MB/s", b / 1_000_000)
    default: return MactopFormat.string("%.1f GB/s", b / 1_000_000_000)
    }
  }
}
