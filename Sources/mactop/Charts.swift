import AppKit

// MARK: - Support types

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

    private var points: [Double?]
    private var nextPointIndex = 0
    private var pointsAreFull = false
    private var color: NSColor
    private var cursor: NSPoint? = nil
    private var flipY = false
    private var fixedMax: Double?

    init(frame: NSRect = .zero, num: Int, color: NSColor = .controlAccentColor, fixedMax: Double? = nil) {
        self.points = Array(repeating: nil, count: max(num, 1))
        self.color = color
        self.fixedMax = fixedMax
        super.init(frame: frame)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect], owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext, points.count > 1 else { return }
        ctx.setShouldAntialias(true)

        let offset: CGFloat = 1 / (NSScreen.main?.backingScaleFactor ?? 1)
        let height = frame.height - offset
        let width = frame.width
        let xRatio = width / CGFloat(points.count - 1)
        let values = orderedPoints()
        let maxValue = fixedMax ?? values.compactMap({ $0 }).max() ?? 1

        let lineColor = color
        let gradientColor = color.withAlphaComponent(0.5)

        let gradient = NSGradient(colors: [gradientColor.withAlphaComponent(0.5), gradientColor.withAlphaComponent(1.0)])

        var line: [CGPoint] = []
        var allLines: [[CGPoint]] = []
        var list: [(value: Double, point: CGPoint)] = []

        for (i, v) in values.enumerated() {
            guard let v else {
                if !line.isEmpty { allLines.append(line); line = [] }
                continue
            }
            let normalizedY = maxValue > 0 ? CGFloat(v / maxValue) * height : 0
            let y = flipY ? height - normalizedY : normalizedY
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

            guard let fillPath = path.copy() as? NSBezierPath,
                  let lastPoint = linePoints.last else { continue }
            let baseline = flipY ? height : 0
            fillPath.line(to: CGPoint(x: lastPoint.x, y: baseline))
            fillPath.line(to: CGPoint(x: linePoints[0].x, y: baseline))
            fillPath.close()
            gradient?.draw(in: fillPath, angle: 90)
        }

        // Tooltip on hover
        if let p = cursor, !list.isEmpty {
            if let nearest = list.min(by: { abs($0.point.x - p.x) < abs($1.point.x - p.x) }) {
                let vLine = NSBezierPath()
                vLine.setLineDash([4, 4], count: 2, phase: 0)
                vLine.move(to: CGPoint(x: p.x, y: 0)); vLine.line(to: CGPoint(x: p.x, y: height))
                NSColor.tertiaryLabelColor.set(); vLine.lineWidth = offset; vLine.stroke()

                let hLine = NSBezierPath()
                hLine.setLineDash([6, 6], count: 2, phase: 0)
                hLine.move(to: CGPoint(x: 0, y: p.y)); hLine.line(to: CGPoint(x: frame.width, y: p.y))
                hLine.lineWidth = offset; hLine.stroke()

                let pct = "\(Int((nearest.value * 100).rounded()))%"
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
        points[nextPointIndex] = v
        nextPointIndex = (nextPointIndex + 1) % points.count
        if nextPointIndex == 0 { pointsAreFull = true }
        if window?.isVisible ?? false { display() }
    }

    func setValues(_ values: [Double]) {
        points = Array(repeating: nil, count: points.count)
        nextPointIndex = 0
        pointsAreFull = false
        for value in values.suffix(points.count) {
            points[nextPointIndex] = value
            nextPointIndex = (nextPointIndex + 1) % points.count
            if nextPointIndex == 0 { pointsAreFull = true }
        }
        if window?.isVisible ?? false {
            display()
        } else {
            needsDisplay = true
        }
    }

    func setColor(_ c: NSColor) { color = c; needsDisplay = true }
    func setFlipY(_ v: Bool) { flipY = v; needsDisplay = true }

    func reinit(_ num: Int = 60) {
        guard points.count != num else { return }
        let values = orderedPoints().compactMap { $0 }
        points = Array(repeating: nil, count: max(num, 1))
        nextPointIndex = 0
        pointsAreFull = false
        setValues(values)
        needsDisplay = true
    }

    private func orderedPoints() -> [Double?] {
        guard !points.isEmpty else { return [] }
        if pointsAreFull {
            return Array(points[nextPointIndex..<points.count] + points[0..<nextPointIndex])
        }
        let prefixCount = points.count - nextPointIndex
        return Array(repeating: nil, count: prefixCount) + points[0..<nextPointIndex]
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

    func setValues(_ v: [ColorValue]) {
        values = v
        if window?.isVisible ?? false {
            display()
        } else {
            needsDisplay = true
        }
    }

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
        inChart.setFlipY(true)
        super.init(frame: frame)
        addSubview(outChart)
        addSubview(inChart)
    }

    required init?(coder: NSCoder) { fatalError() }

    func addValue(upload: Double, download: Double) {
        outChart.addValue(upload)
        inChart.addValue(download)
    }

    func setValues(_ values: [(up: Double, down: Double)]) {
        outChart.setValues(values.map(\.up))
        inChart.setValues(values.map(\.down))
    }

    func reinit(_ num: Int) {
        outChart.reinit(num)
        inChart.reinit(num)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let h = max(newSize.height, 2)
        outChart.frame = NSRect(x: 0, y: h/2, width: newSize.width, height: h/2)
        inChart.frame  = NSRect(x: 0, y: 0,   width: newSize.width, height: h/2)
    }
}

// MARK: - StackedPowerChartView

final class StackedPowerChartView: NSView {
    private var samples: [PowerHistorySample] = []
    private let cpuColor: NSColor
    private let gpuColor: NSColor
    private let aneColor: NSColor
    private let memoryColor: NSColor
    private let mediaColor: NSColor
    private let displayColor: NSColor
    private let otherColor: NSColor
    private let systemColor: NSColor
    private var lastSignature: (count: Int, last: PowerHistorySample)?

    init(frame: NSRect, cpuColor: NSColor, gpuColor: NSColor, aneColor: NSColor, memoryColor: NSColor, mediaColor: NSColor, displayColor: NSColor, otherColor: NSColor, systemColor: NSColor) {
        self.cpuColor = cpuColor
        self.gpuColor = gpuColor
        self.aneColor = aneColor
        self.memoryColor = memoryColor
        self.mediaColor = mediaColor
        self.displayColor = displayColor
        self.otherColor = otherColor
        self.systemColor = systemColor
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let values = samples
        guard let ctx = NSGraphicsContext.current?.cgContext, values.count > 1 else { return }

        ctx.setShouldAntialias(true)

        let width = frame.width
        let height = frame.height
        let xRatio = width / CGFloat(values.count - 1)

        func drawBand(bottom: [Double], top: [Double], color: NSColor, scaleMax: Double, fillAlpha: CGFloat = 0.45, strokeAlpha: CGFloat = 1) {
            guard bottom.count == top.count, top.count > 1 else { return }

            func y(_ watts: Double) -> CGFloat {
                CGFloat(watts / scaleMax) * height
            }

            let path = NSBezierPath()
            path.move(to: CGPoint(x: 0, y: y(top[0])))
            for i in 1..<top.count {
                path.line(to: CGPoint(x: CGFloat(i) * xRatio, y: y(top[i])))
            }
            for i in stride(from: bottom.count - 1, through: 0, by: -1) {
                path.line(to: CGPoint(x: CGFloat(i) * xRatio, y: y(bottom[i])))
            }
            path.close()

            color.withAlphaComponent(fillAlpha).setFill()
            path.fill()

            let line = NSBezierPath()
            line.move(to: CGPoint(x: 0, y: y(top[0])))
            for i in 1..<top.count {
                line.line(to: CGPoint(x: CGFloat(i) * xRatio, y: y(top[i])))
            }
            color.withAlphaComponent(strokeAlpha).setStroke()
            line.lineWidth = 1 / (NSScreen.main?.backingScaleFactor ?? 1)
            line.stroke()
        }

        let cpuTop = values.map(\.cpu)
        let gpuTop = values.map { $0.cpu + $0.gpu }
        let aneTop = values.map { $0.cpu + $0.gpu + $0.ane }
        let memoryTop = values.map { $0.cpu + $0.gpu + $0.ane + $0.memory }
        let mediaTop = values.map { $0.cpu + $0.gpu + $0.ane + $0.memory + $0.media }
        let displayTop = values.map { $0.cpu + $0.gpu + $0.ane + $0.memory + $0.media + $0.display }
        let otherTop = values.map { $0.cpu + $0.gpu + $0.ane + $0.memory + $0.media + $0.display + $0.other }
        let systemTop = values.map(\.total)
        let zero = Array(repeating: 0.0, count: values.count)
        let systemMax = max(systemTop.max() ?? 0, 1)

        drawBand(bottom: zero, top: systemTop, color: systemColor, scaleMax: systemMax, fillAlpha: 0.16, strokeAlpha: 0.55)
        drawBand(bottom: zero, top: cpuTop, color: cpuColor, scaleMax: systemMax)
        drawBand(bottom: cpuTop, top: gpuTop, color: gpuColor, scaleMax: systemMax)
        drawBand(bottom: gpuTop, top: aneTop, color: aneColor, scaleMax: systemMax)
        drawBand(bottom: aneTop, top: memoryTop, color: memoryColor, scaleMax: systemMax)
        drawBand(bottom: memoryTop, top: mediaTop, color: mediaColor, scaleMax: systemMax)
        drawBand(bottom: mediaTop, top: displayTop, color: displayColor, scaleMax: systemMax)
        drawBand(bottom: displayTop, top: otherTop, color: otherColor, scaleMax: systemMax)
    }

    func setValues(_ values: [PowerHistorySample]) {
        guard !values.isEmpty else {
            guard !samples.isEmpty || lastSignature != nil else { return }
            samples = []
            lastSignature = nil
            needsDisplay = true
            return
        }

        let signature = values.last.map { (count: values.count, last: $0) }
        if let signature, let lastSignature, signature.count == lastSignature.count, signature.last == lastSignature.last {
            return
        }

        samples = values
        lastSignature = signature

        if window?.isVisible ?? false {
            self.display()
        } else {
            needsDisplay = true
        }
    }
}

// MARK: - PowerFlowView

final class PowerFlowView: NSView {
    private var charging: ChargingDetail?

    func update(_ detail: ChargingDetail?) {
        charging = detail
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let charging else {
            drawText("Charging data unavailable", at: CGPoint(x: 10, y: 28), align: .left, color: .tertiaryLabelColor)
            return
        }

        let systemWatts = max(charging.inputWatts ?? 0, 0)
        let batteryWatts = charging.batteryWatts ?? 0
        let chargeWatts = max(batteryWatts, 0)
        let dischargeWatts = max(-batteryWatts, 0)
        let adapterWatts = charging.externalConnected ? max(charging.chargerWatts ?? (systemWatts + chargeWatts), 0) : 0
        let batteryFraction = charging.batteryFraction
        let batteryPercent = batteryFraction.map { "\(Int(round($0 * 100)))%" }

        let bar = NSRect(x: 10, y: 29, width: bounds.width - 20, height: 14)
        let radius: CGFloat = 3
        let background = NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius)
        NSColor.underPageBackgroundColor.withAlphaComponent(0.55).setFill()
        background.fill()

        func drawFill(fraction: Double, color: NSColor) {
            let fill = NSRect(x: bar.minX, y: bar.minY, width: max(2, min(bar.width, CGFloat(fraction) * bar.width)), height: bar.height)
            color.withAlphaComponent(0.82).setFill()
            NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
        }

        if charging.externalConnected {
            let color: NSColor = chargeWatts > 0 || charging.isCharging ? .systemYellow : .systemGreen
            drawFill(fraction: batteryFraction ?? 1, color: color)

            let title = chargeWatts > 0 || charging.isCharging ? "Charging battery" : "Power adapter"
            let center = chargeWatts > 0 ? "+" + fmt(chargeWatts) : fmt(adapterWatts)
            let right = batteryPercent ?? charging.status
            drawText(title, at: CGPoint(x: 10, y: 49), align: .left, color: .secondaryLabelColor)
            drawText(center, at: CGPoint(x: bounds.midX, y: 49), align: .center, color: color, weight: .medium)
            drawText(right, at: CGPoint(x: bounds.width - 10, y: 49), align: .right, color: .secondaryLabelColor)
            drawText("Adapter input " + fmt(adapterWatts), at: CGPoint(x: 10, y: 8), align: .left, color: .secondaryLabelColor)
            drawText("System " + fmt(systemWatts), at: CGPoint(x: bounds.width - 10, y: 8), align: .right, color: .secondaryLabelColor)
        } else if dischargeWatts > 0 {
            let color = batteryColor(fraction: batteryFraction)
            drawFill(fraction: batteryFraction ?? 1, color: color)

            drawText("Battery powering Mac", at: CGPoint(x: 10, y: 49), align: .left, color: .secondaryLabelColor)
            drawText(fmt(dischargeWatts), at: CGPoint(x: bounds.midX, y: 49), align: .center, color: .labelColor, weight: .medium)
            drawText(batteryPercent ?? "Discharging", at: CGPoint(x: bounds.width - 10, y: 49), align: .right, color: color)
            drawText("System load " + fmt(systemWatts), at: CGPoint(x: 10, y: 8), align: .left, color: .secondaryLabelColor)
            drawText("Battery -> system", at: CGPoint(x: bounds.width - 10, y: 8), align: .right, color: .secondaryLabelColor)
        } else {
            drawFill(fraction: batteryFraction ?? 1, color: batteryColor(fraction: batteryFraction))
            drawText("Battery", at: CGPoint(x: 10, y: 49), align: .left, color: .secondaryLabelColor)
            drawText(fmt(systemWatts), at: CGPoint(x: bounds.midX, y: 49), align: .center, color: .labelColor, weight: .medium)
            drawText(batteryPercent ?? charging.status, at: CGPoint(x: bounds.width - 10, y: 49), align: .right, color: .secondaryLabelColor)
            drawText("System load " + fmt(systemWatts), at: CGPoint(x: 10, y: 8), align: .left, color: .secondaryLabelColor)
        }
    }

    private enum TextAlign {
        case left
        case center
        case right
    }

    private func drawText(_ text: String, at point: CGPoint, align: TextAlign, color: NSColor, weight: NSFont.Weight = .regular) {
        let font = NSFont.systemFont(ofSize: 11, weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let width = text.widthOfString(usingFont: font)
        let x: CGFloat
        switch align {
        case .left: x = point.x
        case .center: x = point.x - width / 2
        case .right: x = point.x - width
        }
        NSAttributedString(string: text, attributes: attrs)
            .draw(with: NSRect(x: x, y: point.y, width: width + 1, height: 14))
    }

    private func fmt(_ watts: Double) -> String {
        watts < 10 ? String(format: "%.1f W", watts) : String(format: "%.0f W", watts)
    }

    private func batteryColor(fraction: Double?) -> NSColor {
        guard let fraction else { return .systemGreen }
        if fraction <= 0.2 { return .systemRed }
        if fraction <= 0.5 { return .systemYellow }
        return .systemGreen
    }
}

// MARK: - GridChartView
// Connectivity history grid. Faithful port.

final class GridChartView: NSView {
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
            width:  (frame.width  - CGFloat(grid.rows-1)    * spacing) / CGFloat(grid.rows),
            height: (frame.height - CGFloat(grid.columns-1) * spacing) / CGFloat(grid.columns)
        )
        var origin = CGPoint(x: 0, y: (size.height + spacing) * CGFloat(grid.columns - 1))
        var i = 0
        for _ in 0..<grid.columns {
            for _ in 0..<grid.rows {
                let box = NSBezierPath(roundedRect: NSRect(origin: origin, size: size), xRadius: 1, yRadius: 1)
                drawValues[i].setFill(); box.fill()
                i += 1; origin.x += size.width + spacing
            }
            origin.x = 0; origin.y -= size.height + spacing
        }
    }

    func addValue(_ ok: Bool) {
        values[nextValueIndex] = ok ? okColor : notOkColor
        nextValueIndex = (nextValueIndex + 1) % values.count
        if nextValueIndex == 0 { valuesAreFull = true }
        if window?.isVisible ?? false { display() }
    }

    private func orderedValues() -> [NSColor] {
        guard !values.isEmpty else { return [] }
        if valuesAreFull {
            return Array(values[nextValueIndex..<values.count] + values[0..<nextValueIndex])
        }
        return Array(repeating: inactiveColor, count: values.count - nextValueIndex) + values[0..<nextValueIndex]
    }
}
