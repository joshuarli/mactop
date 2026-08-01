import AppKit
import IOKit.ps
import mactopCore

@main
struct MactopApp {
    private static var delegate: MactopAppDelegate?

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = MactopAppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}

@MainActor
class MactopAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItems: [NSStatusItem] = []
    private var cpuView: PercentageStatusItemView!
    private var ramView: PercentageStatusItemView!
    private var gpuView: PercentageStatusItemView!
    private var powerView: PowerStatusItemView!
    private var networkView: NetworkSpeedStatusItemView!
    private var systemMetricsCoordinator: SystemMetricsCoordinator!
    private var popupRefreshTimer: DispatchSourceTimer?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private let cpuProcessQueue = DispatchQueue(label: "mactop.cpu-process-reader", qos: .utility)
    private let ramProcessQueue = DispatchQueue(label: "mactop.ram-process-reader", qos: .utility)
    private let networkProcessQueue = DispatchQueue(label: "mactop.network-process-reader", qos: .utility)
    private var cpuProcessReader = CPUProcessUsageReader()
    private var ramProcessReader = RAMProcessMemoryReader()
    private var networkProcessReader = NetworkProcessReader()

    private var cpuPopupView: CPUPopupView!
    private var ramPopupView: RAMPopupView!
    private var gpuPopupView: GPUPopupView!
    private var powerPopupView: PowerPopupView!
    private var networkPopupView: NetworkPopupView!

    private var cpuPanel: MetricPopupPanel!
    private var ramPanel: MetricPopupPanel!
    private var gpuPanel: MetricPopupPanel!
    private var powerPanel: MetricPopupPanel!
    private var networkPanel: MetricPopupPanel!
    private var statusPanels: [MetricPopupPanel] = []

    private var latestCPU: CPUUsageDetail?
    private var latestRAM: RAMUsageDetail?
    private var latestGPU: GPUUsageDetail?
    private var latestPower: PowerUsageDetail?
    private var latestNetwork: NetworkUsageDetail?
    private var latestCPUProcesses: [RankedProcessMetric] = []
    private var latestRAMProcesses: [RankedProcessMetric] = []
    private var latestNetworkProcesses: [RankedProcessMetric] = []
    private var cpuProcessReadInFlight = false
    private var ramProcessReadInFlight = false
    private var networkProcessReadInFlight = false
    private var isPaused = false
    private var dataEpoch = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let barH  = NSStatusBar.system.thickness
        let viewH = barH - 4

        cpuView = PercentageStatusItemView(label: "CPU")
        ramView = PercentageStatusItemView(label: "RAM")
        gpuView = PercentageStatusItemView(label: "GPU")
        powerView = PowerStatusItemView()
        networkView = NetworkSpeedStatusItemView()

        cpuPopupView = CPUPopupView()
        ramPopupView = RAMPopupView()
        gpuPopupView = GPUPopupView()
        powerPopupView = PowerPopupView()
        networkPopupView = NetworkPopupView()

        cpuPanel = MetricPopupPanel(contentView: cpuPopupView)
        ramPanel = MetricPopupPanel(contentView: ramPopupView)
        gpuPanel = MetricPopupPanel(contentView: gpuPopupView)
        powerPanel = MetricPopupPanel(contentView: powerPopupView)
        networkPanel = MetricPopupPanel(contentView: networkPopupView)

        let entries: [(view: NSView, width: CGFloat, panel: MetricPopupPanel)] = [
            (networkView!, 55, networkPanel),
            (cpuView!, 31, cpuPanel),
            (ramView!, 31, ramPanel),
            (gpuView!, 31, gpuPanel),
            (powerView!, 40, powerPanel),
        ]
        for entry in entries {
            let view = entry.view
            let w = entry.width
            let item = NSStatusBar.system.statusItem(withLength: w)
            guard let button = item.button else { continue }
            view.frame = CGRect(x: 0, y: 2, width: w, height: viewH)
            button.addSubview(view)
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: .leftMouseUp)
            statusItems.append(item)
            statusPanels.append(entry.panel)
        }

        let config = MactopConfig.load()
        systemMetricsCoordinator = SystemMetricsCoordinator(
            config: config,
            onCPU: { [weak self] cpu in
                guard let self else { return }
                guard !self.isPaused else { return }
                self.latestCPU = cpu
                self.cpuView.value = cpu.total
                if self.cpuPanel.isVisible {
                    self.cpuPopupView.updateCPUUsage(cpu, processes: self.latestCPUProcesses)
                }
            },
            onRAM: { [weak self] ram in
                guard let self else { return }
                guard !self.isPaused else { return }
                self.latestRAM = ram
                self.ramView.value = ram.total
                if self.ramPanel.isVisible {
                    self.ramPopupView.updateRAMUsage(ram, processes: self.latestRAMProcesses)
                }
            },
            onGPU: { [weak self] gpu in
                guard let self else { return }
                guard !self.isPaused else { return }
                self.latestGPU = gpu
                self.gpuView.value = gpu.total
                if self.gpuPanel.isVisible {
                    self.gpuPopupView.updateGPUUsage(gpu)
                }
            },
            onPower: { [weak self] power in
                guard let self else { return }
                guard !self.isPaused else { return }
                self.latestPower = power
                self.powerView.watts = power.total
                if self.powerPanel.isVisible {
                    self.powerPopupView.updatePowerUsage(power)
                }
            },
            onNetwork: { [weak self] network in
                guard let self else { return }
                guard !self.isPaused else { return }
                self.latestNetwork = network
                self.networkView.upload   = Int64(network.upload)
                self.networkView.download = Int64(network.download)
                if self.networkPanel.isVisible {
                    self.networkPopupView.updateNetworkUsage(network)
                }
            }
        )
        installPowerSourceObserver()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(togglePause),
            name: .mactopTogglePause,
            object: nil
        )

        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeAllPanels()
        }

        let cpuProcessReader = self.cpuProcessReader
        cpuProcessQueue.async {
            _ = cpuProcessReader.readTopCPUProcessMetrics()
        }
        let detailTimer = DispatchSource.makeTimerSource(queue: .main)
        detailTimer.schedule(deadline: .now() + .seconds(3), repeating: .seconds(3), leeway: .milliseconds(250))
        detailTimer.setEventHandler { [weak self] in
            guard let self else { return }
            guard !self.isPaused else { return }
            if self.cpuPanel.isVisible {
                self.refreshProcesses(for: 1)
            }
            if self.ramPanel.isVisible {
                self.refreshProcesses(for: 2)
            }
            if self.networkPanel.isVisible {
                self.refreshProcesses(for: 0)
            }
        }
        detailTimer.resume()
        self.popupRefreshTimer = detailTimer
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        popupRefreshTimer?.cancel()
        if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .defaultMode)
        }
        popupRefreshTimer = nil
        powerSourceRunLoopSource = nil
    }

    @objc private func systemDidWake(_ notification: Notification) {
        systemMetricsCoordinator.systemDidWake()
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        systemMetricsCoordinator.systemWillSleep()
    }

    @objc private func togglePause() {
        setPaused(!isPaused)
    }

    private func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        dataEpoch += 1
        systemMetricsCoordinator.setPaused(paused)
        NotificationCenter.default.post(
            name: .mactopPauseStateChanged,
            object: self,
            userInfo: ["isPaused": paused]
        )

        if paused {
            clearDisplayData()
        }
    }

    private func clearDisplayData() {
        latestCPU = nil
        latestRAM = nil
        latestGPU = nil
        latestPower = nil
        latestNetwork = nil
        latestCPUProcesses = []
        latestRAMProcesses = []
        latestNetworkProcesses = []

        cpuView.showPercentagePlaceholder()
        ramView.showPercentagePlaceholder()
        gpuView.showPercentagePlaceholder()
        powerView.showPowerPlaceholder()
        networkView.showNetworkSpeedPlaceholder()

        cpuPopupView.clearCPUUsageDisplay()
        ramPopupView.clearRAMUsageDisplay()
        gpuPopupView.clearGPUUsageDisplay()
        powerPopupView.clearPowerUsageDisplay()
        networkPopupView.clearNetworkUsageDisplay()
    }

    private func installPowerSourceObserver() {
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let delegate = Unmanaged<MactopAppDelegate>.fromOpaque(context).takeUnretainedValue()
            delegate.systemMetricsCoordinator.powerSourceChanged()
        }, context)?.takeRetainedValue() else { return }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSourceRunLoopSource = source
    }

    private func refreshProcesses(for index: Int) {
        guard !isPaused else { return }
        let epoch = dataEpoch
        switch index {
        case 0:
            guard !networkProcessReadInFlight else { return }
            networkProcessReadInFlight = true
            let reader = networkProcessReader
            networkProcessQueue.async { [weak self] in
                let procs = reader.readTopNetworkProcessMetrics()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.networkProcessReadInFlight = false
                    guard !self.isPaused, self.dataEpoch == epoch else { return }
                    self.latestNetworkProcesses = procs
                    if self.networkPanel.isVisible {
                        self.networkPopupView.updateNetworkProcesses(procs)
                    }
                }
            }
        case 1:
            guard !cpuProcessReadInFlight else { return }
            cpuProcessReadInFlight = true
            let reader = cpuProcessReader
            cpuProcessQueue.async { [weak self] in
                let procs = reader.readTopCPUProcessMetrics()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.cpuProcessReadInFlight = false
                    guard !self.isPaused, self.dataEpoch == epoch else { return }
                    self.latestCPUProcesses = procs
                    if self.cpuPanel.isVisible, let latestCPU = self.latestCPU {
                        self.cpuPopupView.updateCPUUsage(latestCPU, processes: procs)
                    }
                }
            }
        case 2:
            guard !ramProcessReadInFlight else { return }
            ramProcessReadInFlight = true
            let reader = ramProcessReader
            ramProcessQueue.async { [weak self] in
                let procs = reader.readTopRAMProcessMetrics()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.ramProcessReadInFlight = false
                    guard !self.isPaused, self.dataEpoch == epoch else { return }
                    self.latestRAMProcesses = procs
                    if self.ramPanel.isVisible, let latestRAM = self.latestRAM {
                        self.ramPopupView.updateRAMUsage(latestRAM, processes: procs)
                    }
                }
            }
        default:
            break
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let item = statusItems.first(where: { $0.button === sender }) else { return }
        let idx = statusItems.firstIndex(where: { $0.button === sender }) ?? 0

        let panels = statusPanels
        let targetPanel = panels[idx]

        // Close others, toggle target
        for (i, panel) in panels.enumerated() {
            if i != idx {
                panel.orderOut(nil)
                systemMetricsCoordinator.setHistoryEnabled(false, for: i)
            }
        }

        if targetPanel.isVisible {
            targetPanel.orderOut(nil)
            systemMetricsCoordinator.setHistoryEnabled(false, for: idx)
            return
        }

        guard let button = item.button,
              let window = button.window,
              let screen = window.screen ?? NSScreen.main else { return }

        let buttonRect = window.convertToScreen(button.frame)
        let panelW = targetPanel.frame.width
        let panelH = targetPanel.frame.height

        var x = buttonRect.minX
        var y = buttonRect.minY - panelH - 2

        // Keep within screen bounds
        if x + panelW > screen.visibleFrame.maxX {
            x = screen.visibleFrame.maxX - panelW
        }
        if y < screen.visibleFrame.minY {
            y = buttonRect.maxY + 2
        }

        targetPanel.setFrameOrigin(NSPoint(x: x, y: y))
        systemMetricsCoordinator.setHistoryEnabled(true, for: idx)
        refreshPopup(at: idx, syncHistory: true)
        refreshProcesses(for: idx)
        targetPanel.makeKeyAndOrderFront(nil)
    }

    private func closeAllPanels() {
        statusPanels.forEach { $0.orderOut(nil) }
        systemMetricsCoordinator.setAllHistoryDisabled()
    }

    private func refreshPopup(at index: Int, syncHistory: Bool) {
        switch index {
        case 0:
            if let latestNetwork {
                networkPopupView.updateNetworkUsage(latestNetwork, syncHistory: syncHistory)
            }
            networkPopupView.updateNetworkProcesses(latestNetworkProcesses)
        case 1:
            if let latestCPU {
                cpuPopupView.updateCPUUsage(latestCPU, processes: latestCPUProcesses, syncHistory: syncHistory)
            }
        case 2:
            if let latestRAM {
                ramPopupView.updateRAMUsage(latestRAM, processes: latestRAMProcesses, syncHistory: syncHistory)
            }
        case 3:
            if let latestGPU {
                gpuPopupView.updateGPUUsage(latestGPU, syncHistory: syncHistory)
            }
        case 4:
            if let latestPower {
                powerPopupView.updatePowerUsage(latestPower, syncHistory: syncHistory)
            }
        default:
            break
        }
    }
}
