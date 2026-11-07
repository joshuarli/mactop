import AppKit
import mactopCore


struct ChartSegmentValue {
  let value: Double
  var color: NSColor?
  init(_ value: Double, color: NSColor? = nil) {
    self.value = value
    self.color = color
  }
}

var isDarkMode: Bool {
  switch NSAppearance.currentDrawing().name {
  case .darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua,
    .accessibilityHighContrastVibrantDark:
    return true
  default:
    return false
  }
}

extension String {
  func widthOfString(usingFont font: NSFont) -> CGFloat {
    self.size(withAttributes: [.font: font]).width
  }
}


final class MetricPieChartView: NSView {
  var id: String = UUID().uuidString

  private var filled: Bool = false
  private var drawValue: Bool = false
  private var drawNeedle: Bool = false
  private var openCircle: Bool = false
  private var nonActiveSegmentColor: NSColor = NSColor.lightGray
  private var _value: Double? = nil
  private var text: String? = nil
  private var activeSegment: Int? = nil
  private var segments: [ChartSegmentValue] = []

  init(
    frame: NSRect = .zero, segments: [ChartSegmentValue] = [], filled: Bool = false,
    drawValue: Bool = false, drawNeedle: Bool = false, openCircle: Bool = false
  ) {
    self.filled = filled
    self.drawValue = drawValue
    self.drawNeedle = drawNeedle
    self.openCircle = openCircle
    self.segments = segments
    super.init(frame: frame)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func draw(_ rect: CGRect) {
    var segs = segments
    let arcWidth: CGFloat = filled ? min(frame.width, frame.height) / 2 : 7
    let fullCircle: CGFloat = 2 * .pi
    let arcSpan: CGFloat = openCircle ? (3 / 2) * .pi : fullCircle

    if segs.isEmpty {
      segs = [ChartSegmentValue(_value ?? 0, color: .controlAccentColor)]
    }

    if openCircle {
      let total = segs.reduce(0) { $0 + $1.value }
      if total < 1 {
        segs.append(ChartSegmentValue(1 - total, color: NSColor.lightGray.withAlphaComponent(0.5)))
      }
    } else {
      let total = segs.reduce(0) { $0 + $1.value }
      if total < 1 {
        segs.append(
          ChartSegmentValue(1 - total, color: nonActiveSegmentColor.withAlphaComponent(0.5)))
      }
    }

    let center = CGPoint(x: frame.width / 2, y: frame.height / 2)
    let radius = (min(frame.width, frame.height) - arcWidth) / 2

    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.setShouldAntialias(true)
    ctx.setLineWidth(arcWidth)
    ctx.setLineCap(openCircle ? .round : .butt)

    if openCircle {
      let start: CGFloat = .pi + .pi / 4
      var prev = start
      for seg in segs {
        let cur = prev - CGFloat(seg.value) * arcSpan
        ctx.setStrokeColor((seg.color ?? .controlAccentColor).cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: prev, endAngle: cur, clockwise: true)
        ctx.strokePath()
        prev = cur
      }
    } else {
      let start: CGFloat = .pi / 2
      var prev = start
      for seg in segs.reversed() {
        let cur = prev + CGFloat(seg.value) * fullCircle
        ctx.setStrokeColor((seg.color ?? .controlAccentColor).cgColor)
        ctx.addArc(
          center: center, radius: radius, startAngle: prev, endAngle: cur, clockwise: false)
        ctx.strokePath()
        prev = cur
      }
    }

    if drawNeedle, let activeSegment, !segs.isEmpty {
      let needleEndSize: CGFloat = 2
      let start: CGFloat = .pi + .pi / 4
      let idx = min(activeSegment, segs.count - 1)
      var needleVal: CGFloat = 0
      for i in 0..<idx { needleVal += CGFloat(segs[i].value) }
      needleVal += CGFloat(segs[idx].value) / 2
      let angle = start - needleVal * arcSpan
      let length = radius - arcWidth / 2
      let tip = CGPoint(x: center.x + length * cos(angle), y: center.y + length * sin(angle))
      let perp = angle + .pi / 2
      let b1 = CGPoint(
        x: center.x + needleEndSize * cos(perp), y: center.y + needleEndSize * sin(perp))
      let b2 = CGPoint(
        x: center.x - needleEndSize * cos(perp), y: center.y - needleEndSize * sin(perp))

      let path = NSBezierPath()
      path.move(to: tip)
      path.line(to: b1)
      path.line(to: b2)
      path.close()
      NSColor.systemBlue.setFill()
      path.fill()

      let circle = NSBezierPath(
        roundedRect: NSRect(
          x: center.x - needleEndSize, y: center.y - needleEndSize, width: needleEndSize * 2,
          height: needleEndSize * 2), xRadius: needleEndSize * 2, yRadius: needleEndSize * 2)
      NSColor.systemBlue.setFill()
      circle.fill()
    }

    if drawNeedle, let seg = activeSegment {
      let style = NSMutableParagraphStyle()
      let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9, weight: .regular),
        .foregroundColor: isDarkMode ? NSColor.white : NSColor.textColor, .paragraphStyle: style,
      ]
      let str = "\(seg+1)"
      let w = str.widthOfString(usingFont: NSFont.systemFont(ofSize: 9))
      NSAttributedString(string: str, attributes: attrs).draw(
        with: CGRect(x: (frame.width - w) / 2, y: (frame.height - 26) / 2, width: w, height: 12))
    } else if let text {
      let style = NSMutableParagraphStyle()
      style.alignment = .center
      let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10, weight: .regular),
        .foregroundColor: isDarkMode ? NSColor.white : NSColor.textColor, .paragraphStyle: style,
      ]
      let w = text.widthOfString(usingFont: NSFont.systemFont(ofSize: 10))
      NSAttributedString(string: text, attributes: attrs).draw(
        with: CGRect(
          x: ((frame.width - w) / 2) - 0.5, y: (frame.height - 6) / 2, width: w, height: 13))
    } else if let v = _value, drawValue {
      let style = NSMutableParagraphStyle()
      let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 15, weight: .regular),
        .foregroundColor: isDarkMode ? NSColor.white : NSColor.textColor, .paragraphStyle: style,
      ]
      let pct = "\(Int((v * 100).rounded()))%"
      let w = pct.widthOfString(usingFont: NSFont.systemFont(ofSize: 15))
      NSAttributedString(string: pct, attributes: attrs).draw(
        with: CGRect(x: (frame.width - w) / 2, y: (frame.height - 11) / 2, width: w, height: 12))
    }
  }

  func setFraction(_ fraction: Double) {
    _value = openCircle ? (fraction > 1 ? fraction / 100 : fraction) : fraction
    needsDisplay = true
  }
  func setActiveSegmentIndex(_ index: Int) {
    activeSegment = index
    needsDisplay = true
  }
  func setCenterText(_ text: String?) {
    self.text = text
    needsDisplay = true
  }
  func setSegmentValues(_ values: [ChartSegmentValue]) {
    segments = values
    needsDisplay = true
  }
  func setInactiveSegmentColor(_ color: NSColor) {
    nonActiveSegmentColor = color
    needsDisplay = true
  }
}


final class MetricLineChartView: NSView {
  var id: String = UUID().uuidString

  private var points: [MetricHistoryPoint<Double>]
  private var pointCapacity: Int
  private var color: NSColor
  private var cursor: NSPoint? = nil
  private var flipY = false
  private var fixedMax: Double?
  var tooltipFormatter: (Double) -> String = { value in
    "\(Int((value * 100).rounded()))%"
  }

  init(
    frame: NSRect = .zero, num: Int, color: NSColor = .controlAccentColor, fixedMax: Double? = nil
  ) {
    self.points = []
    self.pointCapacity = max(num, 1)
    self.color = color
    self.fixedMax = fixedMax
    super.init(frame: frame)

    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
        owner: self, userInfo: nil))
  }

  required init?(coder: NSCoder) { fatalError() }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let ctx = NSGraphicsContext.current?.cgContext, points.count > 1 else { return }
    ctx.setShouldAntialias(true)

    let offset: CGFloat = 1 / (NSScreen.main?.backingScaleFactor ?? 1)
    let height = frame.height - offset
    let width = frame.width
    let now = Date()
    let windowStart = now.addingTimeInterval(-metricGraphHistoryWindow)
    let x = { (date: Date) in
      CGFloat(
        max(0, min(metricGraphHistoryWindow, date.timeIntervalSince(windowStart)))
          / metricGraphHistoryWindow) * width
    }
    let expectedInterval = metricGraphHistoryWindow / Double(pointCapacity)
    let gapThreshold = max(expectedInterval * 2, 2)
    let maxValue = fixedMax ?? points.map(\.value).max() ?? 1

    let lineColor = color
    let gradientColor = color.withAlphaComponent(0.5)

    let gradient = NSGradient(colors: [
      gradientColor.withAlphaComponent(0.5), gradientColor.withAlphaComponent(1.0),
    ])

    var line: [CGPoint] = []
    var allLines: [[CGPoint]] = []
    var list: [(value: Double, point: CGPoint)] = []
    var previous: MetricHistoryPoint<Double>?

    for point in points {
      if let previous, point.date.timeIntervalSince(previous.date) > gapThreshold {
        if !line.isEmpty {
          allLines.append(line)
          line = []
        }
        let left = max(
          0, x(previous.date) + width * CGFloat(expectedInterval / metricGraphHistoryWindow) / 2)
        let right = min(
          width, x(point.date) - width * CGFloat(expectedInterval / metricGraphHistoryWindow) / 2)
        if right > left {
          NSColor.tertiaryLabelColor.withAlphaComponent(0.14).setFill()
          ctx.fill(CGRect(x: left, y: 0, width: right - left, height: height))
        }
      }
      let normalizedY = maxValue > 0 ? CGFloat(point.value / maxValue) * height : 0
      let y = flipY ? height - normalizedY : normalizedY
      let pt = CGPoint(x: x(point.date), y: y)
      line.append(pt)
      list.append((value: point.value, point: pt))
      previous = point
    }
    if !line.isEmpty { allLines.append(line) }

    for linePoints in allLines {
      guard linePoints.count > 1 else { continue }
      let path = NSBezierPath()
      path.move(to: linePoints[0])
      for i in 1..<linePoints.count { path.line(to: linePoints[i]) }
      lineColor.set()
      path.lineWidth = offset
      path.stroke()

      guard let fillPath = path.copy() as? NSBezierPath,
        let lastPoint = linePoints.last
      else { continue }
      let baseline = flipY ? height : 0
      fillPath.line(to: CGPoint(x: lastPoint.x, y: baseline))
      fillPath.line(to: CGPoint(x: linePoints[0].x, y: baseline))
      fillPath.close()
      gradient?.draw(in: fillPath, angle: 90)
    }

    if let p = cursor, !list.isEmpty {
      if let nearest = list.min(by: { abs($0.point.x - p.x) < abs($1.point.x - p.x) }) {
        let vLine = NSBezierPath()
        vLine.setLineDash([4, 4], count: 2, phase: 0)
        vLine.move(to: CGPoint(x: p.x, y: 0))
        vLine.line(to: CGPoint(x: p.x, y: height))
        NSColor.tertiaryLabelColor.set()
        vLine.lineWidth = offset
        vLine.stroke()

        let hLine = NSBezierPath()
        hLine.setLineDash([6, 6], count: 2, phase: 0)
        hLine.move(to: CGPoint(x: 0, y: p.y))
        hLine.line(to: CGPoint(x: frame.width, y: p.y))
        hLine.lineWidth = offset
        hLine.stroke()

        let pct = tooltipFormatter(nearest.value)
        let attrs: [NSAttributedString.Key: Any] = [
          .font: NSFont.systemFont(ofSize: 12, weight: .regular),
          .foregroundColor: isDarkMode ? NSColor.white : NSColor.textColor,
        ]
        let tw = pct.widthOfString(usingFont: NSFont.systemFont(ofSize: 12))
        let tx =
          nearest.point.x + 4 + tw > frame.width ? nearest.point.x - tw - 4 : nearest.point.x + 4
        let box = NSBezierPath(
          roundedRect: NSRect(x: tx - 3, y: nearest.point.y - 2, width: tw + 6, height: 14),
          xRadius: 2, yRadius: 2)
        NSColor.gray.setStroke()
        box.stroke()
        (isDarkMode ? NSColor.black : NSColor.white).withAlphaComponent(0.8).setFill()
        box.fill()
        NSAttributedString(string: pct, attributes: attrs).draw(
          with: CGRect(x: tx, y: nearest.point.y + 1, width: tw, height: 12))
      }
    }
  }

  override func mouseEntered(with event: NSEvent) {
    cursor = convert(event.locationInWindow, from: nil)
    needsDisplay = true
  }
  override func mouseMoved(with event: NSEvent) {
    cursor = convert(event.locationInWindow, from: nil)
    needsDisplay = true
  }
  override func mouseExited(with event: NSEvent) {
    cursor = nil
    needsDisplay = true
  }

  func appendMetricValue(_ value: Double) {
    points.append(MetricHistoryPoint(date: Date(), value: value))
    if points.count > pointCapacity { points.removeFirst(points.count - pointCapacity) }
    if window?.isVisible ?? false { display() }
  }

  func setMetricHistory(_ values: [MetricHistoryPoint<Double>]) {
    points = Array(values.suffix(pointCapacity))
    if window?.isVisible ?? false {
      display()
    } else {
      needsDisplay = true
    }
  }

  func setStrokeColor(_ color: NSColor) {
    self.color = color
    needsDisplay = true
  }
  func setVerticalAxisFlipped(_ flipped: Bool) {
    flipY = flipped
    needsDisplay = true
  }

  func resetMetricHistory(sampleCount: Int = 60) {
    pointCapacity = max(sampleCount, 1)
    if points.count > pointCapacity { points = Array(points.suffix(pointCapacity)) }
    needsDisplay = true
  }
}


struct StackedChartSeries {
  let points: [MetricHistoryPoint<Double>]
  let color: NSColor

  init(_ points: [MetricHistoryPoint<Double>], color: NSColor) {
    self.points = points
    self.color = color
  }
}

final class MetricStackedChartView: NSView {
  private var series: [StackedChartSeries] = []
  private var pointCapacity: Int
  private var fixedMax: Double
  private var cursor: NSPoint? = nil

  init(frame: NSRect = .zero, num: Int, fixedMax: Double = 1) {
    self.pointCapacity = max(num, 1)
    self.fixedMax = fixedMax
    super.init(frame: frame)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
        owner: self, userInfo: nil))
  }

  required init?(coder: NSCoder) { fatalError() }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let ctx = NSGraphicsContext.current?.cgContext, !series.isEmpty else { return }
    let count = series.map { $0.points.count }.min() ?? 0
    guard count > 1 else { return }

    ctx.setShouldAntialias(true)
    let offset: CGFloat = 1 / (NSScreen.main?.backingScaleFactor ?? 1)
    let height = frame.height - offset
    let width = frame.width
    let dates = Array(series[0].points.prefix(count).map(\.date))
    let now = Date()
    let windowStart = now.addingTimeInterval(-metricGraphHistoryWindow)
    let x = { (date: Date) in
      CGFloat(
        max(0, min(metricGraphHistoryWindow, date.timeIntervalSince(windowStart)))
          / metricGraphHistoryWindow) * width
    }
    let expectedInterval = metricGraphHistoryWindow / Double(pointCapacity)
    let gapThreshold = max(expectedInterval * 2, 2)
    let y = { (value: Double) in
      CGFloat(min(max(value, 0), self.fixedMax) / self.fixedMax) * height
    }

    for index in 1..<count where dates[index].timeIntervalSince(dates[index - 1]) > gapThreshold {
      let left = max(
        0, x(dates[index - 1]) + width * CGFloat(expectedInterval / metricGraphHistoryWindow) / 2)
      let right = min(
        width, x(dates[index]) - width * CGFloat(expectedInterval / metricGraphHistoryWindow) / 2)
      if right > left {
        NSColor.tertiaryLabelColor.withAlphaComponent(0.14).setFill()
        ctx.fill(CGRect(x: left, y: 0, width: right - left, height: height))
      }
    }

    func cumulativeHeight(upTo layer: Int, at index: Int) -> CGFloat {
      y(series[0...layer].reduce(0.0) { $0 + $1.points[index].value })
    }

    for layer in series.indices {
      let color = series[layer].color
      var start = 0
      while start < count {
        var end = start + 1
        while end < count && dates[end].timeIntervalSince(dates[end - 1]) <= gapThreshold {
          end += 1
        }
        guard end - start > 1 else {
          start = end
          continue
        }

        let path = NSBezierPath()
        path.move(to: CGPoint(x: x(dates[start]), y: cumulativeHeight(upTo: layer, at: start)))
        for index in (start + 1)..<end {
          path.line(to: CGPoint(x: x(dates[index]), y: cumulativeHeight(upTo: layer, at: index)))
        }
        for index in stride(from: end - 1, through: start, by: -1) {
          let bottom = layer == 0 ? 0 : cumulativeHeight(upTo: layer - 1, at: index)
          path.line(to: CGPoint(x: x(dates[index]), y: bottom))
        }
        path.close()
        color.withAlphaComponent(0.55).setFill()
        path.fill()

        let line = NSBezierPath()
        line.move(to: CGPoint(x: x(dates[start]), y: cumulativeHeight(upTo: layer, at: start)))
        for index in (start + 1)..<end {
          line.line(to: CGPoint(x: x(dates[index]), y: cumulativeHeight(upTo: layer, at: index)))
        }
        color.withAlphaComponent(0.9).setStroke()
        line.lineWidth = offset
        line.stroke()
        start = end
      }
    }

    if let p = cursor {
      let totals = (0..<count).map { index in
        series.reduce(0.0) { $0 + $1.points[index].value }
      }
      let points = (0..<count).map { index in
        CGPoint(x: x(dates[index]), y: y(totals[index]))
      }
      if let nearestIndex = points.indices.min(by: { abs(points[$0].x - p.x) < abs(points[$1].x - p.x) }) {
        let vLine = NSBezierPath()
        vLine.setLineDash([4, 4], count: 2, phase: 0)
        vLine.move(to: CGPoint(x: p.x, y: 0))
        vLine.line(to: CGPoint(x: p.x, y: height))
        NSColor.tertiaryLabelColor.set()
        vLine.lineWidth = offset
        vLine.stroke()

        let hLine = NSBezierPath()
        hLine.setLineDash([6, 6], count: 2, phase: 0)
        hLine.move(to: CGPoint(x: 0, y: p.y))
        hLine.line(to: CGPoint(x: frame.width, y: p.y))
        hLine.lineWidth = offset
        hLine.stroke()

        let pct = "\(Int((totals[nearestIndex] * 100).rounded()))%"
        let attrs: [NSAttributedString.Key: Any] = [
          .font: NSFont.systemFont(ofSize: 12, weight: .regular),
          .foregroundColor: isDarkMode ? NSColor.white : NSColor.textColor,
        ]
        let tw = pct.widthOfString(usingFont: NSFont.systemFont(ofSize: 12))
        let tx =
          points[nearestIndex].x + 4 + tw > frame.width
          ? points[nearestIndex].x - tw - 4 : points[nearestIndex].x + 4
        let box = NSBezierPath(
          roundedRect: NSRect(x: tx - 3, y: points[nearestIndex].y - 2, width: tw + 6, height: 14),
          xRadius: 2, yRadius: 2)
        NSColor.gray.setStroke()
        box.stroke()
        (isDarkMode ? NSColor.black : NSColor.white).withAlphaComponent(0.8).setFill()
        box.fill()
        NSAttributedString(string: pct, attributes: attrs).draw(
          with: CGRect(x: tx, y: points[nearestIndex].y + 1, width: tw, height: 12))
      }
    }
  }

  override func mouseEntered(with event: NSEvent) {
    cursor = convert(event.locationInWindow, from: nil)
    needsDisplay = true
  }

  override func mouseMoved(with event: NSEvent) {
    cursor = convert(event.locationInWindow, from: nil)
    needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    cursor = nil
    needsDisplay = true
  }

  func setStackedHistory(_ values: [StackedChartSeries]) {
    series = values.map {
      StackedChartSeries(Array($0.points.suffix(pointCapacity)), color: $0.color)
    }
    if window?.isVisible ?? false {
      display()
    } else {
      needsDisplay = true
    }
  }

  func resetMetricHistory(sampleCount: Int = 60) {
    pointCapacity = max(sampleCount, 1)
    series = series.map {
      StackedChartSeries(Array($0.points.suffix(pointCapacity)), color: $0.color)
    }
    needsDisplay = true
  }
}


final class CoreUsageColumnChartView: NSView {
  private var values: [ChartSegmentValue] = []
  private var cursor: CGPoint? = nil

  init(frame: NSRect = .zero, num: Int) {
    super.init(frame: frame)
    values = Array(repeating: ChartSegmentValue(0, color: .controlAccentColor), count: num)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
        owner: self, userInfo: nil))
  }

  required init?(coder: NSCoder) { fatalError() }

  override func draw(_ dirtyRect: NSRect) {
    guard !values.isEmpty else { return }

    let blocks = 16
    let spacing: CGFloat = 2
    let count = CGFloat(values.count)
    guard count > 0, frame.width > 0, frame.height > 0 else { return }

    let partW = (frame.width - count * spacing) / count
    let partH = frame.height
    let blockW = partW - spacing * 2
    let blockH = ((partH - spacing - 1) / CGFloat(blocks)) - 1

    var list: [(value: Double, path: NSBezierPath)] = []
    var x: CGFloat = 0

    for v in values {
      let color = v.color ?? .controlAccentColor
      let partition = NSBezierPath(
        roundedRect: NSRect(x: x, y: 0, width: partW, height: partH), xRadius: 3, yRadius: 3)
      color.withAlphaComponent(0.07).setFill()
      partition.fill()

      let activeBlocks = Int(round(v.value * Double(blocks)))

      if dirtyRect.height < 30 && v.value != 0 {
        let h = v.value * (partH - spacing)
        let block = NSBezierPath(
          roundedRect: NSRect(x: x + spacing, y: 1, width: blockW, height: h), xRadius: 1,
          yRadius: 1)
        color.setFill()
        block.fill()
      } else {
        var y: CGFloat = spacing
        for b in 0..<blocks {
          let block = NSBezierPath(
            roundedRect: NSRect(x: x + spacing, y: y, width: blockW, height: blockH), xRadius: 1,
            yRadius: 1)
          (activeBlocks <= b ? color.withAlphaComponent(0.14) : color).setFill()
          block.fill()
          y += blockH + 1
        }
      }

      list.append((value: v.value, path: partition))
      x += partW + spacing
    }

    if let p = cursor, let match = list.first(where: { $0.path.contains(p) }) {
      let val = "\(Int((match.value * 100).rounded()))%"
      let w: CGFloat = match.value == 1 ? 38 : match.value > 0.1 ? 32 : 24
      let tx = min(p.x + 4, frame.width - w)
      let ty = min(p.y + 4, frame.height - partH)
      let box = NSBezierPath(
        roundedRect: NSRect(x: tx - 3, y: ty - 2, width: w + 6, height: 14), xRadius: 2, yRadius: 2)
      NSColor.gray.setStroke()
      box.stroke()
      (isDarkMode ? NSColor.black : NSColor.white).withAlphaComponent(0.8).setFill()
      box.fill()
      let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .regular),
        .foregroundColor: isDarkMode ? NSColor.white : NSColor.textColor,
      ]
      NSAttributedString(string: val, attributes: attrs).draw(
        with: CGRect(x: tx, y: ty + 1, width: w, height: 12))
    }
  }

  func setCoreUsageValues(_ values: [ChartSegmentValue]) {
    self.values = values
    if window?.isVisible ?? false {
      display()
    } else {
      needsDisplay = true
    }
  }

  override func mouseEntered(with event: NSEvent) {
    cursor = convert(event.locationInWindow, from: nil)
    display()
  }
  override func mouseMoved(with event: NSEvent) {
    cursor = convert(event.locationInWindow, from: nil)
    display()
  }
  override func mouseExited(with event: NSEvent) {
    cursor = nil
    display()
  }
}


final class NetworkThroughputChartView: NSView {
  private var inChart: MetricLineChartView
  private var outChart: MetricLineChartView
  private var inValues: [MetricHistoryPoint<Double>] = []
  private var outValues: [MetricHistoryPoint<Double>] = []

  init(frame: NSRect, num: Int, outColor: NSColor = .systemRed, inColor: NSColor = .systemBlue) {
    let h = max(frame.height, 2)
    let topFrame = NSRect(x: 0, y: h / 2, width: frame.width, height: h / 2)
    let bottomFrame = NSRect(x: 0, y: 0, width: frame.width, height: h / 2)
    outChart = MetricLineChartView(frame: topFrame, num: num, color: outColor)
    inChart = MetricLineChartView(frame: bottomFrame, num: num, color: inColor)
    inChart.setVerticalAxisFlipped(true)
    let byteRateFormatter: (Double) -> String = { value in
      let b = value.isFinite ? max(0, value) : 0
      if b < 1_000 { return "0 KB/s" }
      if b < 1_000_000 { return "\(Int(b / 1_000)) KB/s" }
      if b < 1_000_000_000 {
        return MactopFormat.string("%.1f MB/s", b / 1_000_000)
      }
      return MactopFormat.string("%.1f GB/s", b / 1_000_000_000)
    }
    outChart.tooltipFormatter = byteRateFormatter
    inChart.tooltipFormatter = byteRateFormatter
    super.init(frame: frame)
    addSubview(outChart)
    addSubview(inChart)
  }

  required init?(coder: NSCoder) { fatalError() }

  func appendThroughput(upload: Double, download: Double) {
    outChart.appendMetricValue(upload)
    inChart.appendMetricValue(download)
  }

  func setThroughputHistory(_ values: [MetricHistoryPoint<(up: Double, down: Double)>]) {
    outValues.removeAll(keepingCapacity: true)
    inValues.removeAll(keepingCapacity: true)
    outValues.reserveCapacity(values.count)
    inValues.reserveCapacity(values.count)
    for value in values {
      outValues.append(MetricHistoryPoint(date: value.date, value: value.value.up))
      inValues.append(MetricHistoryPoint(date: value.date, value: value.value.down))
    }
    outChart.setMetricHistory(outValues)
    inChart.setMetricHistory(inValues)
  }

  func resetThroughputHistory(sampleCount: Int) {
    outChart.resetMetricHistory(sampleCount: sampleCount)
    inChart.resetMetricHistory(sampleCount: sampleCount)
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    let h = max(newSize.height, 2)
    outChart.frame = NSRect(x: 0, y: h / 2, width: newSize.width, height: h / 2)
    inChart.frame = NSRect(x: 0, y: 0, width: newSize.width, height: h / 2)
  }
}


final class ConnectivityHistoryGridChartView: NSView {
  private let okColor: NSColor = .systemGreen
  private let notOkColor: NSColor = .systemRed
  private let inactiveColor: NSColor = .underPageBackgroundColor.withAlphaComponent(0.4)
  private var values: [NSColor] = []
  private var nextValueIndex = 0
  private var valuesAreFull = false
  private let grid: (rows: Int, columns: Int)

  init(frame: NSRect, grid: (rows: Int, columns: Int)) {
    self.grid = grid
    super.init(frame: frame)
    values = Array(repeating: inactiveColor, count: max(grid.rows * grid.columns, 1))
  }

  required init?(coder: NSCoder) { fatalError() }

  override func draw(_ dirtyRect: NSRect) {
    let drawValues = orderedValues()
    let spacing: CGFloat = 2
    let size = CGSize(
      width: (frame.width - CGFloat(grid.rows - 1) * spacing) / CGFloat(grid.rows),
      height: (frame.height - CGFloat(grid.columns - 1) * spacing) / CGFloat(grid.columns)
    )
    var origin = CGPoint(x: 0, y: (size.height + spacing) * CGFloat(grid.columns - 1))
    var i = 0
    for _ in 0..<grid.columns {
      for _ in 0..<grid.rows {
        let box = NSBezierPath(
          roundedRect: NSRect(origin: origin, size: size), xRadius: 1, yRadius: 1)
        drawValues[i].setFill()
        box.fill()
        i += 1
        origin.x += size.width + spacing
      }
      origin.x = 0
      origin.y -= size.height + spacing
    }
  }

  func appendConnectivityStatus(_ isConnected: Bool) {
    values[nextValueIndex] = isConnected ? okColor : notOkColor
    nextValueIndex = (nextValueIndex + 1) % values.count
    if nextValueIndex == 0 { valuesAreFull = true }
    if window?.isVisible ?? false { display() }
  }

  private func orderedValues() -> [NSColor] {
    guard !values.isEmpty else { return [] }
    if valuesAreFull {
      return Array(values[nextValueIndex..<values.count] + values[0..<nextValueIndex])
    }
    return Array(repeating: inactiveColor, count: values.count - nextValueIndex)
      + values[0..<nextValueIndex]
  }
}
