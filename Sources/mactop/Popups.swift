import AppKit

// MARK: - Constants (matching Stats exactly)

private let popupWidth: CGFloat    = 320
private let sepHeight: CGFloat     = 30
private let rowHeight: CGFloat     = 22
private let margins: CGFloat       = 8
private let spacing: CGFloat       = 2
private let initialChartSamples = 2

extension Notification.Name {
    static let mactopTogglePause = Notification.Name("mactop.togglePause")
    static let mactopPauseStateChanged = Notification.Name("mactop.pauseStateChanged")
}

// MARK: - Shared field classes (matching Stats' LabelField / ValueField exactly)

private final class LabelField: NSTextField {
    init(_ label: String = "", frame: NSRect = .zero) {
        super.init(frame: frame)
        isEditable = false; isSelectable = false; isBezeled = false
        wantsLayer = true; backgroundColor = .clear; canDrawSubviewsIntoLayer = true
        stringValue = label
        textColor = .secondaryLabelColor
        alignment = .natural
        font = NSFont.systemFont(ofSize: 12, weight: .regular)
        cell?.truncatesLastVisibleLine = true; cell?.usesSingleLineMode = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class ValueField: NSTextField {
    init(_ value: String = "", frame: NSRect = .zero) {
        super.init(frame: frame)
        isEditable = false; isSelectable = false; isBezeled = false
        wantsLayer = true; backgroundColor = .clear; canDrawSubviewsIntoLayer = true
        stringValue = value
        textColor = .textColor
        alignment = .right
        font = NSFont.systemFont(ofSize: 13, weight: .regular)
        cell?.usesSingleLineMode = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Layout helpers (matching Stats' separatorView / popupRow / popupWithColorRow)

private func separatorView(_ title: String, width: CGFloat = popupWidth) -> NSView {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: sepHeight))
    view.heightAnchor.constraint(equalToConstant: sepHeight).isActive = true

    let label = NSTextField(labelWithString: title)
    label.frame = NSRect(x: 0, y: (sepHeight - 15)/2, width: width, height: 15)
    label.alignment = .center
    label.textColor = .secondaryLabelColor
    label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
    label.isEditable = false; label.isBordered = false; label.drawsBackground = false
    view.addSubview(label)
    return view
}

@discardableResult
private func popupRow(_ view: NSView, title: String, value: String) -> (LabelField, ValueField, NSView) {
    let w = view.frame.width
    let row = NSView(frame: NSRect(x: 0, y: 0, width: w, height: rowHeight))

    let labelWidth = title.widthOfString(usingFont: .systemFont(ofSize: 12, weight: .regular)) + 4
    let lbl = LabelField(title, frame: NSRect(x: 0, y: (rowHeight-16)/2, width: labelWidth, height: 16))
    let val = ValueField(value, frame: NSRect(x: labelWidth, y: (rowHeight-16)/2, width: w - labelWidth, height: 16))

    row.addSubview(lbl); row.addSubview(val)

    if let sv = view as? NSStackView {
        row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
        sv.addArrangedSubview(row)
    } else {
        view.addSubview(row)
    }
    return (lbl, val, row)
}

@discardableResult
private func popupWithColorRow(_ view: NSView, color: NSColor, title: String, value: String) -> (NSView, LabelField, ValueField) {
    let w = view.frame.width
    let row = NSView(frame: NSRect(x: 0, y: 0, width: w, height: rowHeight))

    let dot = NSView(frame: NSRect(x: 2, y: 5, width: 12, height: 12))
    dot.wantsLayer = true; dot.layer?.backgroundColor = color.cgColor; dot.layer?.cornerRadius = 2

    let labelWidth = min(180, title.widthOfString(usingFont: .systemFont(ofSize: 13, weight: .regular)) + 5)
    let lbl = LabelField(title, frame: NSRect(x: 18, y: (rowHeight-16)/2, width: labelWidth, height: 16))
    let val = ValueField(value, frame: NSRect(x: 18 + labelWidth, y: (rowHeight-16)/2, width: w - labelWidth - 18, height: 16))

    row.addSubview(dot); row.addSubview(lbl); row.addSubview(val)

    if let sv = view as? NSStackView {
        row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
        sv.addArrangedSubview(row)
    } else {
        view.addSubview(row)
    }
    return (dot, lbl, val)
}

// MARK: - Process list view (matching Stats' ProcessesView)

private final class ProcessesView: NSView {
    private let processCount: Int
    private var iconViews:   [NSImageView] = []
    private var nameLabels:  [LabelField]  = []
    private var valueLabels: [ValueField]  = []
    private var iconCacheByPID: [Int32: NSImage] = [:]
    private var iconCacheByName: [String: NSImage] = [:]

    init(frame: NSRect, count: Int, valueHeader _: String) {
        self.processCount = count
        super.init(frame: frame)
        let w = frame.width
        let valueW: CGFloat = 72
        let nameW = w - valueW - margins

        for i in 0..<count {
            let y = CGFloat(count - 1 - i) * rowHeight
            let row = NSView(frame: NSRect(x: 0, y: y, width: w, height: rowHeight))

            let iconView = NSImageView(frame: NSRect(x: 2, y: (rowHeight - 16)/2, width: 16, height: 16))
            iconView.imageScaling = .scaleProportionallyDown

            let nameLabel = LabelField("", frame: NSRect(x: 20, y: (rowHeight - 16)/2, width: nameW - 20, height: 16))
            nameLabel.cell?.lineBreakMode = .byTruncatingTail

            let valueLabel = ValueField("", frame: NSRect(x: nameW, y: (rowHeight - 16)/2, width: valueW, height: 16))

            row.addSubview(iconView); row.addSubview(nameLabel); row.addSubview(valueLabel)
            addSubview(row)

            iconViews.append(iconView); nameLabels.append(nameLabel); valueLabels.append(valueLabel)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func setProcesses(_ procs: [TopProcess], format: (Double) -> String) {
        for i in 0..<processCount {
            if i < procs.count {
                let name = procs[i].name
                let value = format(procs[i].value)
                let icon = iconForProcess(procs[i])
                if nameLabels[i].stringValue != name {
                    nameLabels[i].stringValue = name
                }
                if valueLabels[i].stringValue != value {
                    valueLabels[i].stringValue = value
                }
                if iconViews[i].image !== icon {
                    iconViews[i].image = icon
                }
            } else {
                if !nameLabels[i].stringValue.isEmpty {
                    nameLabels[i].stringValue = ""
                }
                if !valueLabels[i].stringValue.isEmpty {
                    valueLabels[i].stringValue = ""
                }
                if iconViews[i].image != nil {
                    iconViews[i].image = nil
                }
            }
        }
    }

    func clear() {
        setProcesses([]) { _ in "" }
    }

    private func iconForProcess(_ process: TopProcess) -> NSImage? {
        if process.pid > 0 {
            if let cached = iconCacheByPID[process.pid] { return cached }
            if let icon = NSRunningApplication(processIdentifier: pid_t(process.pid))?.icon {
                iconCacheByPID[process.pid] = icon
                return icon
            }
        }

        if let cached = iconCacheByName[process.name] { return cached }
        let icon = NSWorkspace.shared.runningApplications
            .first { $0.localizedName == process.name || $0.executableURL?.lastPathComponent == process.name }
            .flatMap { $0.icon }
        if let icon { iconCacheByName[process.name] = icon }
        return icon
    }
}

// MARK: - Memory formatting (matching Stats' Units)

private let memoryFormatter: ByteCountFormatter = {
    let fmt = ByteCountFormatter()
    fmt.countStyle = .memory
    fmt.includesUnit = true
    fmt.isAdaptive = true
    return fmt
}()

private func fmtMemory(_ bytes: UInt64) -> String {
    var s = memoryFormatter.string(fromByteCount: Int64(bytes))
    if let idx = s.lastIndex(of: ",") { s.replaceSubrange(idx...idx, with: ".") }
    return s
}

private func speedTuple(_ bytes: Double) -> (String, String) {
    let b = Int64(bytes)
    let kb = bytes / 1_000; let mb = bytes / 1_000_000; let gb = bytes / 1_000_000_000
    switch b {
    case 0..<1_000: return ("0", "KB/s")
    case 1_000..<(1_000*1_000): return (String(format: "%.0f", kb), "KB/s")
    case 1_000..<(1_000*1_000*100): return (String(format: "%.1f", mb), "MB/s")
    case (1_000*1_000*100)..<(1_000*1_000*1_000): return (String(format: "%.0f", mb), "MB/s")
    default: return (String(format: "%.1f", gb), "GB/s")
    }
}

// MARK: - PopupPanel

private final class PopupChromeView: NSView {
    private let foreground: NSVisualEffectView
    private let background: NSView
    private let pauseButton: NSButton

    init(content: NSView) {
        let size = NSSize(
            width: content.frame.width + margins*2,
            height: content.frame.height + margins*2
        )
        foreground = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background = NSView(frame: foreground.bounds)
        pauseButton = Self.makePauseButton(panelHeight: size.height)
        super.init(frame: NSRect(origin: .zero, size: size))

        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 6

        foreground.material = .titlebar
        foreground.blendingMode = .behindWindow
        foreground.state = .active
        foreground.wantsLayer = true
        foreground.layer?.cornerRadius = 6
        foreground.layer?.masksToBounds = true

        background.wantsLayer = true
        foreground.addSubview(background)

        content.setFrameOrigin(NSPoint(x: margins, y: margins))
        addSubview(foreground, positioned: .below, relativeTo: nil)
        addSubview(content)
        pauseButton.target = self
        addSubview(pauseButton)
        addSubview(Self.makeQuitButton(panelHeight: size.height))
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pauseStateChanged(_:)),
            name: .mactopPauseStateChanged,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func updateLayer() {
        background.layer?.backgroundColor = isDarkMode ? .clear : NSColor.white.cgColor
    }

    @objc private func togglePause() {
        NotificationCenter.default.post(name: .mactopTogglePause, object: self)
    }

    @objc private func pauseStateChanged(_ notification: Notification) {
        let isPaused = notification.userInfo?["isPaused"] as? Bool ?? false
        pauseButton.image = NSImage(
            systemSymbolName: isPaused ? "play.circle.fill" : "pause.circle.fill",
            accessibilityDescription: isPaused ? "Resume" : "Pause"
        )
        pauseButton.toolTip = isPaused ? "Resume data collection" : "Pause data collection"
    }

    private static func makePauseButton(panelHeight: CGFloat) -> NSButton {
        let button = NSButton(frame: NSRect(x: 26, y: panelHeight - 22, width: 16, height: 16))
        button.image = NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: "Pause")
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.action = #selector(togglePause)
        button.toolTip = "Pause data collection"
        button.autoresizingMask = [.minYMargin, .maxXMargin]
        return button
    }

    private static func makeQuitButton(panelHeight: CGFloat) -> NSButton {
        let button = NSButton(frame: NSRect(x: 6, y: panelHeight - 22, width: 16, height: 16))
        button.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Quit")
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.target = NSApp
        button.action = #selector(NSApplication.terminate(_:))
        button.toolTip = "Quit mactop"
        button.autoresizingMask = [.minYMargin, .maxXMargin]
        return button
    }
}

final class PopupPanel: NSPanel {
    init(contentView content: NSView) {
        let chrome = PopupChromeView(content: content)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: chrome.frame.width, height: chrome.frame.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        self.contentView = chrome
    }
    override var canBecomeKey: Bool { true }
}

// MARK: - CPU Popup
// Matches Stats CPU popup: dashboard (pie + temp circle + freq circle) +
// line chart + column chart + details + average load

final class CPUPopupView: NSStackView {

    private let systemColor = NSColor.systemRed
    private let userColor   = NSColor.systemBlue
    private let idleColor   = NSColor.lightGray
    private let performanceCoreColor = NSColor.systemOrange
    private let efficiencyCoreColor = NSColor.systemTeal.withAlphaComponent(0.38)
    private let unknownCoreColor = NSColor.controlAccentColor.withAlphaComponent(0.75)

    private var circle: PieChartView!
    private var lineChart: LineChartView!
    private var columnChart: ColumnChartView!

    private var systemField: ValueField!
    private var userField: ValueField!
    private var idleField: ValueField!
    private var uptimeField: ValueField!

    private var processesView: ProcessesView!
    private let processCount = 8

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: popupWidth, height: 0))
        orientation = .vertical; spacing = 0

        addArrangedSubview(initDashboard())
        addArrangedSubview(initChart())
        addArrangedSubview(initDetails())
        addArrangedSubview(initProcesses())
        recalcHeight()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func recalcHeight() {
        let h = arrangedSubviews.reduce(0.0) { $0 + $1.bounds.height }
        setFrameSize(NSSize(width: popupWidth, height: h))
    }

    private func initDashboard() -> NSView {
        let dashH: CGFloat = 90
        let view = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: dashH))
        view.heightAnchor.constraint(equalToConstant: dashH).isActive = true

        let usageSize = dashH - 20
        let usageX = (popupWidth - usageSize) / 2
        let usageView = NSView(frame: NSRect(x: usageX, y: (dashH - usageSize)/2, width: usageSize, height: usageSize))

        circle = PieChartView(frame: NSRect(x: 0, y: 0, width: usageSize, height: usageSize),
                              segments: [], drawValue: true)
        usageView.addSubview(circle)
        view.addSubview(usageView)
        return view
    }

    private func initChart() -> NSView {
        let chartContentH: CGFloat = 70
        let barContentH: CGFloat   = 50
        let totalH = sepHeight + chartContentH + barContentH
        let view = NSStackView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: totalH))
        view.heightAnchor.constraint(equalToConstant: totalH).isActive = true
        view.orientation = .vertical; view.spacing = 0

        view.addArrangedSubview(separatorView("Usage history"))

        let lineBox = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: chartContentH))
        lineBox.heightAnchor.constraint(equalToConstant: chartContentH).isActive = true
        lineBox.wantsLayer = true
        lineBox.layer?.backgroundColor = NSColor.lightGray.withAlphaComponent(0.1).cgColor
        lineBox.layer?.cornerRadius = 3
        lineChart = LineChartView(frame: NSRect(x: 1, y: 0, width: popupWidth - 2, height: chartContentH), num: initialChartSamples, fixedMax: 1)
        lineBox.addSubview(lineChart)
        view.addArrangedSubview(lineBox)

        let barBox = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: barContentH))
        barBox.heightAnchor.constraint(equalToConstant: barContentH).isActive = true
        barBox.wantsLayer = true
        barBox.layer?.backgroundColor = NSColor.lightGray.withAlphaComponent(0.1).cgColor
        barBox.layer?.cornerRadius = 3
        columnChart = ColumnChartView(
            frame: NSRect(x: spacing, y: spacing, width: popupWidth - spacing*2, height: barContentH - spacing*2),
            num: ProcessInfo.processInfo.processorCount
        )
        barBox.addSubview(columnChart)
        view.addArrangedSubview(barBox)

        return view
    }

    private func initDetails() -> NSView {
        let rowCount: CGFloat = 4
        let h = (rowHeight * rowCount) + sepHeight
        let view = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: h))
        view.heightAnchor.constraint(equalToConstant: h).isActive = true

        let sep = separatorView("Details")
        sep.frame = NSRect(x: 0, y: h - sepHeight, width: popupWidth, height: sepHeight)
        view.addSubview(sep)

        let container = NSStackView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: sep.frame.origin.y))
        container.orientation = .vertical; container.spacing = 0
        view.addSubview(container)

        systemField = popupWithColorRow(container, color: systemColor, title: "System:", value: "").2
        userField   = popupWithColorRow(container, color: userColor,   title: "User:",   value: "").2
        idleField   = popupWithColorRow(container, color: idleColor.withAlphaComponent(0.5), title: "Idle:", value: "").2
        uptimeField = popupRow(container, title: "Uptime:", value: "").1
        return view
    }

    private func initProcesses() -> NSView {
        let procViewH = CGFloat(processCount) * rowHeight
        let totalH = sepHeight + procViewH
        let view = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: totalH))
        view.heightAnchor.constraint(equalToConstant: totalH).isActive = true

        let sep = separatorView("Top processes")
        sep.frame = NSRect(x: 0, y: procViewH, width: popupWidth, height: sepHeight)
        view.addSubview(sep)

        processesView = ProcessesView(
            frame: NSRect(x: 0, y: 0, width: popupWidth, height: procViewH),
            count: processCount,
            valueHeader: "CPU"
        )
        view.addSubview(processesView)
        return view
    }

    func update(_ d: CPUDetail, processes: [TopProcess], syncHistory _: Bool = false) {
        systemField.stringValue = "\(Int((d.system * 100).rounded()))%"
        userField.stringValue   = "\(Int((d.user   * 100).rounded()))%"
        idleField.stringValue   = "\(Int((d.idle   * 100).rounded()))%"
        uptimeField.stringValue = d.uptime

        circle.setText(nil)
        circle.setSegments([
            ColorValue(d.system, color: systemColor),
            ColorValue(d.user,   color: userColor)
        ])
        circle.setNonActiveSegmentColor(idleColor)
        circle.setValue(d.total)

        lineChart.reinit(max(initialChartSamples, d.historyCapacity))
        lineChart.setValues(d.history)

        if !d.usagePerCore.isEmpty {
            let vals = d.usagePerCore.enumerated().map { idx, value in
                let color: NSColor
                if d.coreKinds.indices.contains(idx) {
                    switch d.coreKinds[idx] {
                    case .efficiency: color = efficiencyCoreColor
                    case .performance: color = performanceCoreColor
                    case .unknown: color = unknownCoreColor
                    }
                } else {
                    color = unknownCoreColor
                }
                return ColorValue(value, color: color)
            }
            columnChart.setValues(vals)
        }

        processesView.setProcesses(processes) { v in
            String(format: v < 10 ? "%.1f%%" : "%.0f%%", v)
        }
    }

    func clearData() {
        systemField.stringValue = "--"
        userField.stringValue = "--"
        idleField.stringValue = "--"
        uptimeField.stringValue = "--"
        circle.setText("--")
        circle.setSegments([])
        circle.setValue(0)
        lineChart.setValues([])
        columnChart.setValues([])
        processesView.clear()
    }
}

// MARK: - RAM Popup
// Matches Stats RAM popup: dashboard (pie + pressure gauge) + line chart + details

final class RAMPopupView: NSStackView {

    private let appColor        = NSColor.systemBlue
    private let wiredColor      = NSColor.systemOrange
    private let compressedColor = NSColor.systemPink
    private let freeColor       = NSColor.lightGray

    private var circle: PieChartView!
    private var level: PieChartView!
    private var lineChart: LineChartView!

    private var usedField: ValueField!
    private var appField: ValueField!
    private var wiredField: ValueField!
    private var compField: ValueField!
    private var freeField: ValueField!
    private var swapField: ValueField!

    private var processesView: ProcessesView!
    private let processCount = 8

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: popupWidth, height: 0))
        orientation = .vertical; spacing = 0

        addArrangedSubview(initDashboard())
        addArrangedSubview(initChart())
        addArrangedSubview(initDetails())
        addArrangedSubview(initProcesses())
        recalcHeight()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func recalcHeight() {
        let h = arrangedSubviews.reduce(0.0) { $0 + $1.bounds.height }
        setFrameSize(NSSize(width: popupWidth, height: h))
    }

    private func initDashboard() -> NSView {
        let dashH: CGFloat = 90
        let view = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: dashH))
        view.heightAnchor.constraint(equalToConstant: dashH).isActive = true

        let container = NSView(frame: NSRect(x: 0, y: 10, width: popupWidth, height: dashH - 20))
        let circleSize = dashH - 20
        let circleX = (popupWidth - circleSize) / 2
        circle = PieChartView(frame: NSRect(x: circleX, y: 0, width: circleSize, height: circleSize),
                              segments: [], drawValue: true)
        container.addSubview(circle)

        let sideWidth = (popupWidth - circleSize - margins*2) / 2
        level = PieChartView(frame: NSRect(x: (sideWidth - 60)/2, y: 10, width: 60, height: 50),
                             segments: [
                                ColorValue(1/3, color: .systemGreen),
                                ColorValue(1/3, color: .systemYellow),
                                ColorValue(1/3, color: .systemRed)
                             ],
                             drawValue: true, drawNeedle: true, openCircle: true)

        view.addSubview(level)
        view.addSubview(container)
        return view
    }

    private func initChart() -> NSView {
        let chartH: CGFloat = 90
        let totalH = chartH + sepHeight
        let view = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: totalH))
        view.heightAnchor.constraint(equalToConstant: totalH).isActive = true

        let sep = separatorView("Usage history")
        sep.frame = NSRect(x: 0, y: chartH, width: popupWidth, height: sepHeight)
        view.addSubview(sep)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: chartH))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.lightGray.withAlphaComponent(0.1).cgColor
        container.layer?.cornerRadius = 3
        lineChart = LineChartView(frame: NSRect(x: 1, y: 0, width: popupWidth - 2, height: chartH), num: initialChartSamples, fixedMax: 1)
        container.addSubview(lineChart)
        view.addSubview(container)
        return view
    }

    private func initDetails() -> NSView {
        let h = rowHeight*6 + sepHeight
        let view = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: h))
        view.heightAnchor.constraint(equalToConstant: h).isActive = true

        let sep = separatorView("Details")
        sep.frame = NSRect(x: 0, y: h - sepHeight, width: popupWidth, height: sepHeight)
        view.addSubview(sep)

        let container = NSStackView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: sep.frame.origin.y))
        container.orientation = .vertical; container.spacing = 0
        view.addSubview(container)

        usedField = popupRow(container,    title: "Used:",       value: "").1
        appField  = popupWithColorRow(container, color: appColor,        title: "App:",        value: "").2
        wiredField = popupWithColorRow(container, color: wiredColor,     title: "Wired:",      value: "").2
        compField  = popupWithColorRow(container, color: compressedColor, title: "Compressed:", value: "").2
        freeField  = popupWithColorRow(container, color: freeColor.withAlphaComponent(0.5), title: "Free:", value: "").2
        swapField  = popupRow(container,   title: "Swap:",       value: "").1
        return view
    }

    private func initProcesses() -> NSView {
        let procViewH = CGFloat(processCount) * rowHeight
        let totalH = sepHeight + procViewH
        let view = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: totalH))
        view.heightAnchor.constraint(equalToConstant: totalH).isActive = true

        let sep = separatorView("Top processes")
        sep.frame = NSRect(x: 0, y: procViewH, width: popupWidth, height: sepHeight)
        view.addSubview(sep)

        processesView = ProcessesView(
            frame: NSRect(x: 0, y: 0, width: popupWidth, height: procViewH),
            count: processCount,
            valueHeader: "Memory"
        )
        view.addSubview(processesView)
        return view
    }

    func update(_ d: RAMDetail, processes: [TopProcess], syncHistory _: Bool = false) {
        let used = d.appBytes + d.wiredBytes + d.compressedBytes
        usedField.stringValue  = fmtMemory(used)
        appField.stringValue   = fmtMemory(d.appBytes)
        wiredField.stringValue = fmtMemory(d.wiredBytes)
        compField.stringValue  = fmtMemory(d.compressedBytes)
        freeField.stringValue  = fmtMemory(d.freeBytes)
        swapField.stringValue  = fmtMemory(d.swapBytes)

        circle.setText(nil)
        circle.setSegments([
            ColorValue(d.totalBytes > 0 ? Double(d.appBytes)        / Double(d.totalBytes) : 0, color: appColor),
            ColorValue(d.totalBytes > 0 ? Double(d.wiredBytes)      / Double(d.totalBytes) : 0, color: wiredColor),
            ColorValue(d.totalBytes > 0 ? Double(d.compressedBytes) / Double(d.totalBytes) : 0, color: compressedColor)
        ])
        circle.setNonActiveSegmentColor(freeColor)
        circle.setValue(d.total)

        level.setActiveSegment(d.pressureLevel)

        lineChart.reinit(max(initialChartSamples, d.historyCapacity))
        lineChart.setValues(d.history)

        processesView.setProcesses(processes) { v in fmtMemory(UInt64(v)) }
    }

    func clearData() {
        usedField.stringValue = "--"
        appField.stringValue = "--"
        wiredField.stringValue = "--"
        compField.stringValue = "--"
        freeField.stringValue = "--"
        swapField.stringValue = "--"
        circle.setText("--")
        circle.setSegments([])
        circle.setValue(0)
        level.setActiveSegment(0)
        lineChart.setValues([])
        processesView.clear()
    }
}

// MARK: - GPU Popup
// Matches Stats GPU popup: title row + circles row (utilization/render/tiler) + charts row

final class GPUPopupView: NSStackView {

    private var modelLabel: NSTextField!
    private var circleRow: NSStackView!
    private var chartRow: NSStackView!
    private var gpuCircle: PieChartView!
    private var renderCircle: PieChartView!
    private var tilerCircle: PieChartView!
    private var gpuChart: LineChartView!
    private var renderChart: LineChartView!
    private var tilerChart: LineChartView!

    private let circleSize: CGFloat = 50
    private let chartSize:  CGFloat = 60

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: popupWidth, height: 0))
        orientation = .vertical; spacing = 0
        wantsLayer = true; layer?.cornerRadius = 2

        addArrangedSubview(initTitle())
        addArrangedSubview(initStats())
        recalcHeight()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = (isDarkMode
            ? NSColor(red: 17/255, green: 17/255, blue: 17/255, alpha: 0.25)
            : NSColor(red: 245/255, green: 245/255, blue: 245/255, alpha: 1)).cgColor
    }

    private func recalcHeight() {
        let h = arrangedSubviews.reduce(0.0) { $0 + $1.bounds.height }
        setFrameSize(NSSize(width: popupWidth, height: h))
    }

    private func initTitle() -> NSView {
        let titleH: CGFloat = 24
        let view = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: titleH))
        view.heightAnchor.constraint(equalToConstant: titleH).isActive = true

        modelLabel = NSTextField(labelWithString: "GPU")
        modelLabel.frame = NSRect(x: 0, y: (titleH-16)/2, width: popupWidth, height: 16)
        modelLabel.alignment = .center
        modelLabel.textColor = .secondaryLabelColor
        modelLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        view.addSubview(modelLabel)
        return view
    }

    private func initStats() -> NSView {
        let labelH: CGFloat = 18
        let circleRowH = circleSize + 20
        let chartRowH = chartSize + 20
        let totalH = labelH + circleRowH + chartRowH
        let view = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: totalH))
        view.heightAnchor.constraint(equalToConstant: totalH).isActive = true

        let labelRow = NSStackView(frame: NSRect(x: 0, y: chartRowH + circleRowH, width: popupWidth, height: labelH))
        labelRow.orientation = .horizontal
        labelRow.distribution = .fillEqually
        labelRow.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)

        circleRow = NSStackView(frame: NSRect(x: 0, y: chartRowH, width: popupWidth, height: circleRowH))
        circleRow.orientation = .horizontal
        circleRow.distribution = .fillEqually
        circleRow.alignment = .bottom
        circleRow.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 0, right: 10)

        chartRow = NSStackView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: chartRowH))
        chartRow.orientation = .horizontal
        chartRow.distribution = .fillEqually
        chartRow.spacing = margins
        chartRow.edgeInsets = NSEdgeInsets(top: margins, left: margins, bottom: margins, right: margins)

        addGPUColumnLabel("GPU")
        addGPUColumnLabel("Render")
        addGPUColumnLabel("Tiler")

        addCircle(id: "GPU utilization")
        addCircle(id: "Render utilization")
        addCircle(id: "Tiler utilization")
        addChart(id: "GPU utilization")
        addChart(id: "Render utilization")
        addChart(id: "Tiler utilization")

        view.addSubview(labelRow)
        view.addSubview(circleRow)
        view.addSubview(chartRow)
        return view

        func addGPUColumnLabel(_ text: String) {
            let label = NSTextField(labelWithString: text)
            label.alignment = .center
            label.textColor = .secondaryLabelColor
            label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            labelRow.addArrangedSubview(label)
        }
    }

    private func addCircle(id: String) {
        let c = PieChartView(frame: NSRect(x: 0, y: 0, width: circleSize, height: circleSize), openCircle: true)
        c.id = id
        circleRow.addArrangedSubview(c)
        switch id {
        case "GPU utilization":    gpuCircle    = c
        case "Render utilization": renderCircle = c
        case "Tiler utilization":  tilerCircle  = c
        default: break
        }
    }

    private func addChart(id: String) {
        let c = LineChartView(frame: NSRect(x: 0, y: 0, width: 100, height: chartSize), num: initialChartSamples, fixedMax: 1)
        c.id = id
        c.wantsLayer = true
        c.layer?.backgroundColor = NSColor.lightGray.withAlphaComponent(0.1).cgColor
        c.layer?.cornerRadius = 3
        chartRow.addArrangedSubview(c)
        switch id {
        case "GPU utilization":    gpuChart    = c
        case "Render utilization": renderChart = c
        case "Tiler utilization":  tilerChart  = c
        default: break
        }
    }

    func update(_ d: GPUDetail, syncHistory _: Bool = false) {
        modelLabel.stringValue = d.model

        gpuCircle.setValue(d.total)
        gpuCircle.setText("\(Int((d.total * 100).rounded()))%")
        gpuChart.reinit(max(initialChartSamples, d.historyCapacity))
        gpuChart.setValues(d.history)

        renderCircle.setValue(d.render)
        renderCircle.setText("\(Int((d.render * 100).rounded()))%")
        renderChart.reinit(max(initialChartSamples, d.historyCapacity))
        renderChart.setValues(d.renderHistory)

        tilerCircle.setValue(d.tiler)
        tilerCircle.setText("\(Int((d.tiler * 100).rounded()))%")
        tilerChart.reinit(max(initialChartSamples, d.historyCapacity))
        tilerChart.setValues(d.tilerHistory)
    }

    func clearData() {
        modelLabel.stringValue = "--"
        gpuCircle.setValue(0)
        gpuCircle.setText("--")
        gpuChart.setValues([])
        renderCircle.setValue(0)
        renderCircle.setText("--")
        renderChart.setValues([])
        tilerCircle.setValue(0)
        tilerCircle.setText("--")
        tilerChart.setValues([])
    }
}

// MARK: - Power Popup

final class PowerPopupView: NSStackView {
    private let cpuColor = NSColor.systemOrange
    private let gpuColor = NSColor.systemPurple
    private let aneColor = NSColor.systemTeal
    private let memoryColor = NSColor.systemGreen
    private let mediaColor = NSColor.systemBlue
    private let displayColor = NSColor.systemYellow
    private let otherColor = NSColor.systemGray
    private let systemColor = NSColor.secondaryLabelColor

    private var systemValue: ValueField!
    private var modeledValue: ValueField!
    private var cpuValue: ValueField!
    private var gpuValue: ValueField!
    private var aneValue: ValueField!
    private var memoryValue: ValueField!
    private var mediaValue: ValueField!
    private var displayValue: ValueField!
    private var otherValue: ValueField!
    private var chart: StackedPowerChartView!
    private var flowView: PowerFlowView!

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: popupWidth, height: 0))
        orientation = .vertical
        spacing = 0
        wantsLayer = true
        layer?.cornerRadius = 2

        addArrangedSubview(separatorView("Power"))
        addArrangedSubview(initFlow())
        initRows()
        addArrangedSubview(initChart())
        recalcHeight()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = (isDarkMode
            ? NSColor(red: 17/255, green: 17/255, blue: 17/255, alpha: 0.25)
            : NSColor(red: 245/255, green: 245/255, blue: 245/255, alpha: 1)).cgColor
    }

    private func recalcHeight() {
        let h = arrangedSubviews.reduce(0.0) { $0 + $1.bounds.height }
        setFrameSize(NSSize(width: popupWidth, height: h))
    }

    private func initRows() {
        (_, systemValue, _) = popupRow(self, title: "System", value: "--W")
        (_, modeledValue, _) = popupRow(self, title: "Modeled", value: "--W")
        (_, _, cpuValue) = popupWithColorRow(self, color: cpuColor, title: "CPU", value: "--W")
        (_, _, gpuValue) = popupWithColorRow(self, color: gpuColor, title: "GPU", value: "--W")
        (_, _, aneValue) = popupWithColorRow(self, color: aneColor, title: "ANE", value: "--W")
        (_, _, memoryValue) = popupWithColorRow(self, color: memoryColor, title: "Memory", value: "--W")
        (_, _, mediaValue) = popupWithColorRow(self, color: mediaColor, title: "Media", value: "--W")
        (_, _, displayValue) = popupWithColorRow(self, color: displayColor, title: "Display", value: "--W")
        (_, _, otherValue) = popupWithColorRow(self, color: otherColor, title: "Other SoC", value: "--W")
    }

    private func initFlow() -> NSView {
        let flowH: CGFloat = 70
        let view = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: flowH))
        view.heightAnchor.constraint(equalToConstant: flowH).isActive = true

        flowView = PowerFlowView(frame: NSRect(x: margins, y: 0, width: popupWidth - margins*2, height: flowH))
        flowView.wantsLayer = true
        flowView.layer?.backgroundColor = NSColor.lightGray.withAlphaComponent(0.1).cgColor
        flowView.layer?.cornerRadius = 3
        view.addSubview(flowView)
        return view
    }

    private func initChart() -> NSView {
        let chartH: CGFloat = 120
        let view = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: chartH))
        view.heightAnchor.constraint(equalToConstant: chartH).isActive = true

        chart = StackedPowerChartView(
            frame: NSRect(x: margins, y: margins, width: popupWidth - margins*2, height: chartH - margins*2),
            cpuColor: cpuColor,
            gpuColor: gpuColor,
            aneColor: aneColor,
            memoryColor: memoryColor,
            mediaColor: mediaColor,
            displayColor: displayColor,
            otherColor: otherColor,
            systemColor: systemColor
        )
        chart.wantsLayer = true
        chart.layer?.backgroundColor = NSColor.lightGray.withAlphaComponent(0.1).cgColor
        chart.layer?.cornerRadius = 3
        view.addSubview(chart)
        return view
    }

    func update(_ d: PowerDetail, syncHistory _: Bool = false) {
        systemValue.stringValue = fmtPower(d.system)
        modeledValue.stringValue = fmtPower(d.modeled)
        cpuValue.stringValue = fmtPower(d.cpu)
        gpuValue.stringValue = fmtPower(d.gpu)
        aneValue.stringValue = fmtPower(d.ane)
        memoryValue.stringValue = fmtPower(d.memory)
        mediaValue.stringValue = fmtPower(d.media)
        displayValue.stringValue = fmtPower(d.display)
        otherValue.stringValue = fmtPower(d.other)
        updateCharging(d.charging)

        guard d.cpu != nil,
              d.gpu != nil,
              d.ane != nil,
              d.memory != nil,
              d.media != nil,
              d.display != nil,
              d.other != nil else {
            chart.setValues([])
            return
        }

        chart.setValues(d.history)
    }

    func clearData() {
        systemValue.stringValue = "--W"
        modeledValue.stringValue = "--W"
        cpuValue.stringValue = "--W"
        gpuValue.stringValue = "--W"
        aneValue.stringValue = "--W"
        memoryValue.stringValue = "--W"
        mediaValue.stringValue = "--W"
        displayValue.stringValue = "--W"
        otherValue.stringValue = "--W"
        flowView.showPlaceholder()
        chart.setValues([])
    }

    private func updateCharging(_ detail: ChargingDetail?) {
        flowView.update(detail)
    }

    private func fmtPower(_ watts: Double?) -> String {
        guard let watts else { return "--W" }
        switch watts {
        case ..<10:
            return String(format: "%.1f W", watts)
        default:
            return String(format: "%.0f W", watts)
        }
    }
}

// MARK: - Net Popup
// Matches Stats Net popup: dashboard (large up/down values) + usage history +
// details + interface + address

final class NetPopupView: NSStackView {

    private let uploadColor   = NSColor.systemRed
    private let downloadColor = NSColor.systemBlue

    private var uploadValueField: NSTextField!
    private var uploadUnitField:  NSTextField!
    private var uploadView: NSView!
    private var uploadContainerView: NSView!

    private var downloadValueField: NSTextField!
    private var downloadUnitField:  NSTextField!
    private var downloadView: NSView!
    private var downloadContainerView: NSView!

    private var usageChart: NetworkChartView!

    private var totalUpField:   ValueField!
    private var totalDownField: ValueField!
    private var statusField:    ValueField!

    // Interface section
    private var interfaceField:       ValueField!
    private var ifaceStatusField:     ValueField!

    // Address section
    private var localIPField:  ValueField!
    private var publicIPField: ValueField!

    private var netProcessesView: ProcessesView!
    private let processCount = 8

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: popupWidth, height: 0))
        orientation = .vertical; spacing = 0

        addArrangedSubview(initDashboard())
        addArrangedSubview(initChart())
        addArrangedSubview(initDetails())
        addArrangedSubview(initInterface())
        addArrangedSubview(initAddress())
        addArrangedSubview(initProcesses())
        recalcHeight()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func recalcHeight() {
        let h = arrangedSubviews.reduce(0.0) { $0 + $1.bounds.height }
        setFrameSize(NSSize(width: popupWidth, height: h))
    }

    private func topValueView(_ container: NSView, title: String, color: NSColor) -> (NSView, NSTextField, NSTextField) {
        let topH: CGFloat = 30
        let titleH: CGFloat = 15
        let valueWidth = "0".widthOfString(usingFont: .systemFont(ofSize: 26, weight: .light)) + 5
        let unitWidth  = "KB/s".widthOfString(usingFont: .systemFont(ofSize: 13, weight: .light)) + 5
        let topPartW = valueWidth + unitWidth

        let topView = NSView(frame: NSRect(
            x: (container.frame.width - topPartW) / 2,
            y: (container.frame.height - topH - titleH)/2 + titleH,
            width: topPartW, height: topH
        ))

        let valueField = NSTextField(labelWithString: "0")
        valueField.frame = NSRect(x: 0, y: 0, width: valueWidth, height: 30)
        valueField.font = NSFont.systemFont(ofSize: 26, weight: .light)
        valueField.textColor = .textColor; valueField.alignment = .right
        valueField.isEditable = false; valueField.isBordered = false; valueField.drawsBackground = false

        let unitField = NSTextField(labelWithString: "KB/s")
        unitField.frame = NSRect(x: valueField.frame.width, y: 4, width: unitWidth, height: 15)
        unitField.font = NSFont.systemFont(ofSize: 13, weight: .light)
        unitField.textColor = .labelColor; unitField.alignment = .left
        unitField.isEditable = false; unitField.isBordered = false; unitField.drawsBackground = false

        let titleWidth = title.widthOfString(usingFont: NSFont.systemFont(ofSize: 12, weight: .regular)) + 8
        let iconSize: CGFloat = 12
        let bottomW = titleWidth + iconSize
        let bottomView = NSView(frame: NSRect(
            x: (container.frame.width - bottomW) / 2,
            y: topView.frame.origin.y - titleH,
            width: bottomW, height: titleH
        ))

        let dot = NSView(frame: NSRect(x: 0, y: 1, width: iconSize, height: iconSize))
        dot.wantsLayer = true; dot.layer?.backgroundColor = color.cgColor; dot.layer?.cornerRadius = 4

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.frame = NSRect(x: iconSize, y: 0, width: titleWidth, height: titleH)
        titleLabel.alignment = .center; titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        titleLabel.isEditable = false; titleLabel.isBordered = false; titleLabel.drawsBackground = false

        topView.addSubview(valueField); topView.addSubview(unitField)
        bottomView.addSubview(dot); bottomView.addSubview(titleLabel)
        container.addSubview(topView); container.addSubview(bottomView)

        return (topView, valueField, unitField)
    }

    private func initDashboard() -> NSView {
        let dashH: CGFloat = 90
        let view = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: dashH))
        view.heightAnchor.constraint(equalToConstant: dashH).isActive = true

        let left = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth/2, height: dashH))
        let (lv, dvf, duf) = topValueView(left, title: "Downloading", color: downloadColor)
        downloadContainerView = left
        downloadView = lv
        downloadValueField = dvf
        downloadUnitField = duf

        let right = NSView(frame: NSRect(x: popupWidth/2, y: 0, width: popupWidth/2, height: dashH))
        let (rv, uvf, uuf) = topValueView(right, title: "Uploading", color: uploadColor)
        uploadContainerView = right
        uploadView = rv
        uploadValueField = uvf
        uploadUnitField = uuf

        view.addSubview(left); view.addSubview(right)
        return view
    }

    private func initChart() -> NSView {
        let chartH: CGFloat = 90
        let totalH = chartH + sepHeight
        let view = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: totalH))
        view.heightAnchor.constraint(equalToConstant: totalH).isActive = true

        let sep = separatorView("Usage history")
        sep.frame = NSRect(x: 0, y: chartH, width: popupWidth, height: sepHeight)
        view.addSubview(sep)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: chartH))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.lightGray.withAlphaComponent(0.1).cgColor
        container.layer?.cornerRadius = 3
        usageChart = NetworkChartView(
            frame: NSRect(x: 0, y: 1, width: popupWidth, height: chartH - 2),
            num: initialChartSamples,
            outColor: uploadColor, inColor: downloadColor
        )
        container.addSubview(usageChart)
        view.addSubview(container)
        return view
    }

    private func initDetails() -> NSView {
        let rowCount: CGFloat = 3
        let h = sepHeight + rowCount * rowHeight
        let view = NSStackView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: h))
        view.orientation = .vertical; view.spacing = 0
        view.heightAnchor.constraint(equalToConstant: h).isActive = true

        let sepRow = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: sepHeight))
        sepRow.heightAnchor.constraint(equalToConstant: sepHeight).isActive = true
        sepRow.addSubview(separatorView("Details", width: popupWidth))
        view.addArrangedSubview(sepRow)

        let (_, _, tu) = popupWithColorRow(view, color: uploadColor,   title: "Total upload:",   value: "0")
        let (_, _, td) = popupWithColorRow(view, color: downloadColor, title: "Total download:", value: "0")
        totalUpField   = tu
        totalDownField = td

        statusField = popupRow(view, title: "Status:", value: "Unknown").1
        return view
    }

    private func initInterface() -> NSView {
        let rowCount: CGFloat = 2
        let h = sepHeight + rowCount * rowHeight
        let view = NSStackView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: h))
        view.orientation = .vertical; view.spacing = 0
        view.heightAnchor.constraint(equalToConstant: h).isActive = true

        let sepRow = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: sepHeight))
        sepRow.heightAnchor.constraint(equalToConstant: sepHeight).isActive = true
        sepRow.addSubview(separatorView("Interface", width: popupWidth))
        view.addArrangedSubview(sepRow)

        interfaceField   = popupRow(view, title: "Interface:",        value: "Unknown").1
        ifaceStatusField = popupRow(view, title: "Status:",           value: "Unknown").1
        return view
    }

    private func initAddress() -> NSView {
        let rowCount: CGFloat = 2
        let h = sepHeight + rowCount * rowHeight
        let view = NSStackView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: h))
        view.orientation = .vertical; view.spacing = 0
        view.heightAnchor.constraint(equalToConstant: h).isActive = true

        let sepRow = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: sepHeight))
        sepRow.heightAnchor.constraint(equalToConstant: sepHeight).isActive = true
        sepRow.addSubview(separatorView("Address", width: popupWidth))
        view.addArrangedSubview(sepRow)

        localIPField  = popupRow(view, title: "Local IP:",  value: "Unknown").1
        publicIPField = popupRow(view, title: "Public IP:", value: "Unknown").1
        return view
    }

    private func initProcesses() -> NSView {
        let procViewH = CGFloat(processCount) * rowHeight
        let totalH = sepHeight + procViewH
        let view = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: totalH))
        view.heightAnchor.constraint(equalToConstant: totalH).isActive = true

        let sep = separatorView("Top processes")
        sep.frame = NSRect(x: 0, y: procViewH, width: popupWidth, height: sepHeight)
        view.addSubview(sep)

        netProcessesView = ProcessesView(
            frame: NSRect(x: 0, y: 0, width: popupWidth, height: procViewH),
            count: processCount,
            valueHeader: "Network"
        )
        view.addSubview(netProcessesView)
        return view
    }

    func updateProcesses(_ procs: [TopProcess]) {
        netProcessesView.setProcesses(procs) { v in
            let (val, unit) = speedTuple(v)
            return "\(val) \(unit)"
        }
    }

    private func setSpeedFields(upload: Double, download: Double) {
        let up   = speedTuple(upload)
        let down = speedTuple(download)

        let upValueW   = up.0.widthOfString(usingFont: .systemFont(ofSize: 26, weight: .light)) + 5
        let upUnitW    = up.1.widthOfString(usingFont: .systemFont(ofSize: 13, weight: .light)) + 5
        let upTopW     = upValueW + upUnitW
        let downValueW = down.0.widthOfString(usingFont: .systemFont(ofSize: 26, weight: .light)) + 5
        let downUnitW  = down.1.widthOfString(usingFont: .systemFont(ofSize: 13, weight: .light)) + 5
        let downTopW   = downValueW + downUnitW
        let halfW      = popupWidth / 2

        if let uploadView, let uploadValueField, let uploadUnitField {
            uploadView.setFrameSize(NSSize(width: upTopW, height: uploadView.frame.height))
            uploadView.setFrameOrigin(NSPoint(x: (halfW - upTopW)/2, y: uploadView.frame.origin.y))
            uploadValueField.setFrameSize(NSSize(width: upValueW, height: 30))
            uploadValueField.stringValue = up.0
            uploadUnitField.setFrameSize(NSSize(width: upUnitW, height: 15))
            uploadUnitField.setFrameOrigin(NSPoint(x: upValueW, y: uploadUnitField.frame.origin.y))
            uploadUnitField.stringValue = up.1
        }

        if let downloadView, let downloadValueField, let downloadUnitField {
            downloadView.setFrameSize(NSSize(width: downTopW, height: downloadView.frame.height))
            downloadView.setFrameOrigin(NSPoint(x: (halfW - downTopW)/2, y: downloadView.frame.origin.y))
            downloadValueField.setFrameSize(NSSize(width: downValueW, height: 30))
            downloadValueField.stringValue = down.0
            downloadUnitField.setFrameSize(NSSize(width: downUnitW, height: 15))
            downloadUnitField.setFrameOrigin(NSPoint(x: downValueW, y: downloadUnitField.frame.origin.y))
            downloadUnitField.stringValue = down.1
        }
    }

    func update(_ d: NetDetail, syncHistory _: Bool = false) {
        setSpeedFields(upload: d.upload, download: d.download)
        totalUpField.stringValue   = fmtMemory(d.totalUp)
        totalDownField.stringValue = fmtMemory(d.totalDown)
        statusField.stringValue    = d.isUp ? "UP" : "DOWN"

        let ifaceName = d.interfaceName.isEmpty ? "Unknown" : d.interfaceName
        let dispName  = d.displayName.isEmpty   ? ifaceName : d.displayName
        interfaceField.stringValue   = "\(dispName) (\(ifaceName))"
        ifaceStatusField.stringValue = d.isUp ? "Active" : "Inactive"

        localIPField.stringValue  = d.localIP.isEmpty    ? "Unknown" : d.localIP
        publicIPField.stringValue = d.publicIP ?? "Fetching…"

        usageChart.reinit(max(initialChartSamples, d.historyCapacity))
        usageChart.setValues(d.history)
    }

    func clearData() {
        setPlaceholderSpeedFields()
        totalUpField.stringValue = "--"
        totalDownField.stringValue = "--"
        statusField.stringValue = "--"
        interfaceField.stringValue = "--"
        ifaceStatusField.stringValue = "--"
        localIPField.stringValue = "--"
        publicIPField.stringValue = "--"
        usageChart.setValues([])
        netProcessesView.clear()
    }

    private func setPlaceholderSpeedFields() {
        let value = "--"
        let valueW = value.widthOfString(usingFont: .systemFont(ofSize: 26, weight: .light)) + 5
        let halfW = popupWidth / 2

        if let uploadView, let uploadValueField, let uploadUnitField {
            uploadView.setFrameSize(NSSize(width: valueW, height: uploadView.frame.height))
            uploadView.setFrameOrigin(NSPoint(x: (halfW - valueW)/2, y: uploadView.frame.origin.y))
            uploadValueField.setFrameSize(NSSize(width: valueW, height: 30))
            uploadValueField.stringValue = value
            uploadUnitField.stringValue = ""
        }

        if let downloadView, let downloadValueField, let downloadUnitField {
            downloadView.setFrameSize(NSSize(width: valueW, height: downloadView.frame.height))
            downloadView.setFrameOrigin(NSPoint(x: (halfW - valueW)/2, y: downloadView.frame.origin.y))
            downloadValueField.setFrameSize(NSSize(width: valueW, height: 30))
            downloadValueField.stringValue = value
            downloadUnitField.stringValue = ""
        }
    }
}
