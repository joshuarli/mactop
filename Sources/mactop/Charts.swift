import AppKit

// MARK: - Support types

struct DoubleValue {
    var ts: Date = Date()
    let value: Double
    init(_ value: Double = 0) { self.value = value }
}

struct ColorValue {
    let value: Double
    var color: NSColor?
    init(_ value: Double, color: NSColor? = nil) {
        self.value = value
        self.color = color
    }
}

var isDarkMode: Bool {
    switch NSAppearance.currentDrawing().name {
    case .darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark:
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

// MARK: - PieChartView
// Closed-circle (CPU/RAM) and open-arc (GPU circles) variants.

final class PieChartView: NSView {
    var id: String = UUID().uuidString

    private var filled: Bool = false
    private var drawValue: Bool = false
    private var drawNeedle: Bool = false
    private var openCircle: Bool = false
    private var nonActiveSegmentColor: NSColor = NSColor.lightGray
    private var _value: Double? = nil
    private var text: String? = nil
    private var activeSegment: Int? = nil
    private var segments: [ColorValue] = []

    init(frame: NSRect = .zero, segments: [ColorValue] = [], filled: Bool = false,
         drawValue: Bool = false, drawNeedle: Bool = false, openCircle: Bool = false) {
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
        let arcSpan: CGFloat = openCircle ? (3/2) * .pi : fullCircle

        if segs.isEmpty {
            segs = [ColorValue(_value ?? 0, color: .controlAccentColor)]
        }

        if openCircle {
            let total = segs.reduce(0) { $0 + $1.value }
            if total < 1 { segs.append(ColorValue(1 - total, color: NSColor.lightGray.withAlphaComponent(0.5))) }
        } else {
            let total = segs.reduce(0) { $0 + $1.value }
            if total < 1 { segs.append(ColorValue(1 - total, color: nonActiveSegmentColor.withAlphaComponent(0.5))) }
        }

        let center = CGPoint(x: frame.width/2, y: frame.height/2)
        let radius = (min(frame.width, frame.height) - arcWidth) / 2

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldAntialias(true)
        ctx.setLineWidth(arcWidth)
        ctx.setLineCap(openCircle ? .round : .butt)

        if openCircle {
            let start: CGFloat = .pi + .pi/4
            var prev = start
            for seg in segs {
                let cur = prev - CGFloat(seg.value) * arcSpan
                ctx.setStrokeColor((seg.color ?? .controlAccentColor).cgColor)
                ctx.addArc(center: center, radius: radius, startAngle: prev, endAngle: cur, clockwise: true)
                ctx.strokePath()
                prev = cur
            }
        } else {
            let start: CGFloat = .pi/2
            var prev = start
            for seg in segs.reversed() {
                let cur = prev + CGFloat(seg.value) * fullCircle
                ctx.setStrokeColor((seg.color ?? .controlAccentColor).cgColor)
                ctx.addArc(center: center, radius: radius, startAngle: prev, endAngle: cur, clockwise: false)
                ctx.strokePath()
                prev = cur
            }
        }

        if drawNeedle, let activeSegment, !segs.isEmpty {
            let needleEndSize: CGFloat = 2
            let start: CGFloat = .pi + .pi/4
            let idx = min(activeSegment, segs.count - 1)
            var needleVal: CGFloat = 0
            for i in 0..<idx { needleVal += CGFloat(segs[i].value) }
            needleVal += CGFloat(segs[idx].value) / 2
            let angle = start - needleVal * arcSpan
            let length = radius - arcWidth/2
            let tip = CGPoint(x: center.x + length * cos(angle), y: center.y + length * sin(angle))
            let perp = angle + .pi/2
            let b1 = CGPoint(x: center.x + needleEndSize * cos(perp), y: center.y + needleEndSize * sin(perp))
            let b2 = CGPoint(x: center.x - needleEndSize * cos(perp), y: center.y - needleEndSize * sin(perp))

            let path = NSBezierPath(); path.move(to: tip); path.line(to: b1); path.line(to: b2); path.close()
            NSColor.systemBlue.setFill(); path.fill()

            let circle = NSBezierPath(roundedRect: NSRect(x: center.x - needleEndSize, y: center.y - needleEndSize, width: needleEndSize*2, height: needleEndSize*2), xRadius: needleEndSize*2, yRadius: needleEndSize*2)
            NSColor.systemBlue.setFill(); circle.fill()
        }

        if drawNeedle, let seg = activeSegment {
            let style = NSMutableParagraphStyle()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .regular), .foregroundColor: isDarkMode ? NSColor.white : NSColor.textColor, .paragraphStyle: style]
            let str = "\(seg+1)"
            let w = str.widthOfString(usingFont: NSFont.systemFont(ofSize: 9))
            NSAttributedString(string: str, attributes: attrs).draw(with: CGRect(x: (frame.width-w)/2, y: (frame.height-26)/2, width: w, height: 12))
        } else if let text {
            let style = NSMutableParagraphStyle(); style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .regular), .foregroundColor: isDarkMode ? NSColor.white : NSColor.textColor, .paragraphStyle: style]
            let w = text.widthOfString(usingFont: NSFont.systemFont(ofSize: 10))
            NSAttributedString(string: text, attributes: attrs).draw(with: CGRect(x: ((frame.width-w)/2)-0.5, y: (frame.height-6)/2, width: w, height: 13))
        } else if let v = _value, drawValue {
            let style = NSMutableParagraphStyle()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .regular), .foregroundColor: isDarkMode ? NSColor.white : NSColor.textColor, .paragraphStyle: style]
            let pct = "\(Int((v * 100).rounded()))%"
            let w = pct.widthOfString(usingFont: NSFont.systemFont(ofSize: 15))
            NSAttributedString(string: pct, attributes: attrs).draw(with: CGRect(x: (frame.width-w)/2, y: (frame.height-11)/2, width: w, height: 12))
        }
    }

    func setValue(_ v: Double) {
        _value = openCircle ? (v > 1 ? v/100 : v) : v
        needsDisplay = true
    }
    func setActiveSegment(_ idx: Int) { activeSegment = idx; needsDisplay = true }
    func setText(_ v: String) { text = v; needsDisplay = true }
    func setSegments(_ s: [ColorValue]) { segments = s; needsDisplay = true }
    func setNonActiveSegmentColor(_ c: NSColor) { nonActiveSegmentColor = c; needsDisplay = true }
}

// MARK: - LineChartView
// Faithful port of Stats' LineChartView. Gradient fill below line, tooltip on hover.

final class LineChartView: NSView {
    var id: String = UUID().uuidString

    private var points: [DoubleValue?]
    private var color: NSColor
    private var cursor: NSPoint? = nil

    init(frame: NSRect = .zero, num: Int, color: NSColor = .controlAccentColor) {
        self.points = Array(repeating: nil, count: max(num, 1))
        self.color = color
        super.init(frame: frame)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect], owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext, !points.isEmpty else { return }
        ctx.setShouldAntialias(true)

        let offset: CGFloat = 1 / (NSScreen.main?.backingScaleFactor ?? 1)
        let height = frame.height - offset
        let width = frame.width
        let xRatio = width / CGFloat(points.count - 1)
        let maxValue = points.compactMap({ $0 }).map({ $0.value }).max() ?? 1

        let lineColor = color
        let gradientColor = color.withAlphaComponent(0.5)

        let gradient = NSGradient(colors: [gradientColor.withAlphaComponent(0.5), gradientColor.withAlphaComponent(1.0)])

        var line: [CGPoint] = []
        var allLines: [[CGPoint]] = []
        var list: [(value: DoubleValue, point: CGPoint)] = []

        for (i, v) in points.enumerated() {
            guard let v else {
                if !line.isEmpty { allLines.append(line); line = [] }
                continue
            }
            let y = maxValue > 0 ? CGFloat(v.value / maxValue) * height : 0
            let pt = CGPoint(x: CGFloat(i) * xRatio, y: y)
            line.append(pt)
            list.append((value: v, point: pt))
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

            let fillPath = path.copy() as! NSBezierPath
            fillPath.line(to: CGPoint(x: linePoints.last!.x, y: 0))
            fillPath.line(to: CGPoint(x: linePoints[0].x, y: 0))
            fillPath.close()
            gradient?.draw(in: fillPath, angle: 90)
        }

        // Tooltip on hover
        if let p = cursor, !list.isEmpty {
            let overPoints = list.filter { $0.point.x >= p.x }
            let underPoints = list.filter { $0.point.x <= p.x }
            if let over = overPoints.min(by: { $0.point.x < $1.point.x }),
               let under = underPoints.max(by: { $0.point.x < $1.point.x }) {
                let nearest = (over.point.x - p.x < p.x - under.point.x) ? over : under

                let vLine = NSBezierPath()
                vLine.setLineDash([4, 4], count: 2, phase: 0)
                vLine.move(to: CGPoint(x: p.x, y: 0)); vLine.line(to: CGPoint(x: p.x, y: height))
                NSColor.tertiaryLabelColor.set(); vLine.lineWidth = offset; vLine.stroke()

                let hLine = NSBezierPath()
                hLine.setLineDash([6, 6], count: 2, phase: 0)
                hLine.move(to: CGPoint(x: 0, y: p.y)); hLine.line(to: CGPoint(x: frame.width, y: p.y))
                hLine.lineWidth = offset; hLine.stroke()

                let pct = "\(Int((nearest.value.value * 100).rounded()))%"
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .regular), .foregroundColor: isDarkMode ? NSColor.white : NSColor.textColor]
                let tw = pct.widthOfString(usingFont: NSFont.systemFont(ofSize: 12))
                let tx = nearest.point.x + 4 + tw > frame.width ? nearest.point.x - tw - 4 : nearest.point.x + 4
                let box = NSBezierPath(roundedRect: NSRect(x: tx-3, y: nearest.point.y-2, width: tw+6, height: 14), xRadius: 2, yRadius: 2)
                NSColor.gray.setStroke(); box.stroke()
                (isDarkMode ? NSColor.black : NSColor.white).withAlphaComponent(0.8).setFill(); box.fill()
                NSAttributedString(string: pct, attributes: attrs).draw(with: CGRect(x: tx, y: nearest.point.y+1, width: tw, height: 12))
            }
        }
    }

    override func mouseEntered(with event: NSEvent) { cursor = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseMoved(with event: NSEvent) { cursor = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { cursor = nil; needsDisplay = true }

    func addValue(_ v: Double) {
        guard !points.isEmpty else { return }
        points.removeFirst()
        points.append(DoubleValue(v))
        if window?.isVisible ?? false { display() }
    }

    func setColor(_ c: NSColor) { color = c; needsDisplay = true }

    func reinit(_ num: Int = 60) {
        guard points.count != num else { return }
        if num < points.count {
            points = Array(points[points.count-num..<points.count])
        } else {
            let origin = points
            points = Array(repeating: nil, count: num)
            points.replaceSubrange((num-origin.count)..<num, with: origin)
        }
        needsDisplay = true
    }
}

// MARK: - ColumnChartView
// Per-core usage bars. Faithful port of Stats' ColumnChartView.

final class ColumnChartView: NSView {
    private var values: [ColorValue] = []
    private var cursor: CGPoint? = nil

    init(frame: NSRect = .zero, num: Int) {
        super.init(frame: frame)
        values = Array(repeating: ColorValue(0, color: .controlAccentColor), count: num)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect], owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard !values.isEmpty else { return }

        let blocks = 16
        let spacing: CGFloat = 2
        let count = CGFloat(values.count)
        guard count > 0, frame.width > 0, frame.height > 0 else { return }

        let partW = (frame.width - count*spacing) / count
        let partH = frame.height
        let blockW = partW - spacing*2
        let blockH = ((partH - spacing - 1) / CGFloat(blocks)) - 1

        var list: [(value: Double, path: NSBezierPath)] = []
        var x: CGFloat = 0

        for v in values {
            let partition = NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: partW, height: partH), xRadius: 3, yRadius: 3)
            NSColor.underPageBackgroundColor.withAlphaComponent(0.5).setFill()
            partition.fill()

            let color = v.color ?? .controlAccentColor
            let activeBlocks = Int(round(v.value * Double(blocks)))

            if dirtyRect.height < 30 && v.value != 0 {
                let h = v.value * (partH - spacing)
                let block = NSBezierPath(roundedRect: NSRect(x: x+spacing, y: 1, width: blockW, height: h), xRadius: 1, yRadius: 1)
                color.setFill(); block.fill()
            } else {
                var y: CGFloat = spacing
                for b in 0..<blocks {
                    let block = NSBezierPath(roundedRect: NSRect(x: x+spacing, y: y, width: blockW, height: blockH), xRadius: 1, yRadius: 1)
                    (activeBlocks <= b ? NSColor.controlBackgroundColor.withAlphaComponent(0.4) : color).setFill()
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
            let tx = min(p.x+4, frame.width - w)
            let ty = min(p.y+4, frame.height - partH)
            let box = NSBezierPath(roundedRect: NSRect(x: tx-3, y: ty-2, width: w+6, height: 14), xRadius: 2, yRadius: 2)
            NSColor.gray.setStroke(); box.stroke()
            (isDarkMode ? NSColor.black : NSColor.white).withAlphaComponent(0.8).setFill(); box.fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .regular), .foregroundColor: isDarkMode ? NSColor.white : NSColor.textColor]
            NSAttributedString(string: val, attributes: attrs).draw(with: CGRect(x: tx, y: ty+1, width: w, height: 12))
        }
    }

    func setValues(_ v: [ColorValue]) { values = v; if window?.isVisible ?? false { display() } }

    override func mouseEntered(with event: NSEvent) { cursor = convert(event.locationInWindow, from: nil); display() }
    override func mouseMoved(with event: NSEvent) { cursor = convert(event.locationInWindow, from: nil); display() }
    override func mouseExited(with event: NSEvent) { cursor = nil; display() }
}

// MARK: - NetworkChartView
// Two stacked line charts (upload top / download bottom). Faithful port.

final class NetworkChartView: NSView {
    private var inChart: LineChartView
    private var outChart: LineChartView

    init(frame: NSRect, num: Int, outColor: NSColor = .systemRed, inColor: NSColor = .systemBlue) {
        let h = max(frame.height, 2)
        let topFrame = NSRect(x: 0, y: h/2, width: frame.width, height: h/2)
        let bottomFrame = NSRect(x: 0, y: 0, width: frame.width, height: h/2)
        // upload = out = top, download = in = bottom; download flipped (grows downward)
        outChart = LineChartView(frame: topFrame, num: num, color: outColor)
        inChart  = LineChartView(frame: bottomFrame, num: num, color: inColor)
        super.init(frame: frame)
        addSubview(outChart)
        addSubview(inChart)
    }

    required init?(coder: NSCoder) { fatalError() }

    func addValue(upload: Double, download: Double) {
        outChart.addValue(upload)
        inChart.addValue(download)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let h = max(newSize.height, 2)
        outChart.frame = NSRect(x: 0, y: h/2, width: newSize.width, height: h/2)
        inChart.frame  = NSRect(x: 0, y: 0,   width: newSize.width, height: h/2)
    }
}

// MARK: - GridChartView
// Connectivity history grid. Faithful port.

final class GridChartView: NSView {
    private let okColor: NSColor = .systemGreen
    private let notOkColor: NSColor = .systemRed
    private let inactiveColor: NSColor = .underPageBackgroundColor.withAlphaComponent(0.4)
    private var values: [NSColor] = []
    private let grid: (rows: Int, columns: Int)

    init(frame: NSRect, grid: (rows: Int, columns: Int)) {
        self.grid = grid
        super.init(frame: frame)
        values = Array(repeating: inactiveColor, count: max(grid.rows * grid.columns, 1))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let spacing: CGFloat = 2
        let size = CGSize(
            width:  (frame.width  - CGFloat(grid.rows-1)    * spacing) / CGFloat(grid.rows),
            height: (frame.height - CGFloat(grid.columns-1) * spacing) / CGFloat(grid.columns)
        )
        var origin = CGPoint(x: 0, y: (size.height + spacing) * CGFloat(grid.columns - 1))
        var i = 0
        for _ in 0..<grid.columns {
            for _ in 0..<grid.rows {
                let box = NSBezierPath(roundedRect: NSRect(origin: origin, size: size), xRadius: 1, yRadius: 1)
                values[i].setFill(); box.fill()
                i += 1; origin.x += size.width + spacing
            }
            origin.x = 0; origin.y -= size.height + spacing
        }
    }

    func addValue(_ ok: Bool) {
        values.removeFirst()
        values.append(ok ? okColor : notOkColor)
        if window?.isVisible ?? false { display() }
    }
}
