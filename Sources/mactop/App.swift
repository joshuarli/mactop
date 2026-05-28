import AppKit
import IOKit.ps

@main
struct Mactop {
    private static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItems: [NSStatusItem] = []
    private var cpuView: MiniView!
    private var ramView: MiniView!
    private var gpuView: MiniView!
    private var powerView: PowerView!
    private var netView: SpeedView!
    private var monitor: SystemMonitor!
    private var detailTimer: DispatchSourceTimer?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private let cpuProcessQueue = DispatchQueue(label: "mactop.cpu-process-reader", qos: .utility)
    private let ramProcessQueue = DispatchQueue(label: "mactop.ram-process-reader", qos: .utility)
    private let netProcessQueue = DispatchQueue(label: "mactop.net-process-reader", qos: .utility)
    private var cpuProcessReader = CPUProcessReader()
    private var ramProcessReader = RAMProcessReader()
    private var netProcessReader = NetProcessReader()

    private var cpuPopupView: CPUPopupView!
    private var ramPopupView: RAMPopupView!
    private var gpuPopupView: GPUPopupView!
    private var powerPopupView: PowerPopupView!
    private var netPopupView: NetPopupView!

    private var cpuPanel: PopupPanel!
    private var ramPanel: PopupPanel!
    private var gpuPanel: PopupPanel!
    private var powerPanel: PopupPanel!
    private var netPanel: PopupPanel!
    private var statusPanels: [PopupPanel] = []

    private var allPanels: [PopupPanel] { statusPanels }
    private var latestCPU: CPUDetail?
    private var latestRAM: RAMDetail?
    private var latestGPU: GPUDetail?
    private var latestPower: PowerDetail?
    private var latestNet: NetDetail?
    private var latestCPUProcesses: [TopProcess] = []
    private var latestRAMProcesses: [TopProcess] = []
    private var latestNetProcesses: [TopProcess] = []
    private var cpuProcessReadInFlight = false
    private var ramProcessReadInFlight = false
    private var netProcessReadInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let barH  = NSStatusBar.system.thickness
        let viewH = barH - 4

        cpuView = MiniView(label: "CPU")
        ramView = MiniView(label: "RAM")
        gpuView = MiniView(label: "GPU")
        powerView = PowerView()
        netView = SpeedView()

        cpuPopupView = CPUPopupView()
        ramPopupView = RAMPopupView()
        gpuPopupView = GPUPopupView()
        powerPopupView = PowerPopupView()
        netPopupView = NetPopupView()

        cpuPanel = PopupPanel(contentView: cpuPopupView)
        ramPanel = PopupPanel(contentView: ramPopupView)
        gpuPanel = PopupPanel(contentView: gpuPopupView)
        powerPanel = PopupPanel(contentView: powerPopupView)
        netPanel = PopupPanel(contentView: netPopupView)

        let entries: [(view: NSView, width: CGFloat, panel: PopupPanel)] = [
            (netView!, 55, netPanel),
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

        let config = Config.load()
        monitor = SystemMonitor(
            config: config,
            onCPU: { [weak self] cpu in
                guard let self else { return }
                self.latestCPU = cpu
                self.cpuView.value = cpu.total
                if self.cpuPanel.isVisible {
                    self.cpuPopupView.update(cpu, processes: self.latestCPUProcesses)
                }
            },
            onRAM: { [weak self] ram in
                guard let self else { return }
                self.latestRAM = ram
                self.ramView.value = ram.total
                if self.ramPanel.isVisible {
                    self.ramPopupView.update(ram, processes: self.latestRAMProcesses)
                }
            },
            onGPU: { [weak self] gpu in
                guard let self else { return }
                self.latestGPU = gpu
                self.gpuView.value = gpu.total
                if self.gpuPanel.isVisible {
                    self.gpuPopupView.update(gpu)
                }
            },
            onPower: { [weak self] power in
                guard let self else { return }
                self.latestPower = power
                self.powerView.watts = power.total
                if self.powerPanel.isVisible {
                    self.powerPopupView.update(power)
                }
            },
            onNet: { [weak self] net in
                guard let self else { return }
                self.latestNet = net
                self.netView.upload   = Int64(net.upload)
                self.netView.download = Int64(net.download)
                if self.netPanel.isVisible {
                    self.netPopupView.update(net)
                }
            }
        )
        installPowerSourceObserver()

        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeAllPanels()
        }

        cpuProcessQueue.async { [weak self] in
            _ = self?.cpuProcessReader.read()
        }
        let detailTimer = DispatchSource.makeTimerSource(queue: .main)
        detailTimer.schedule(deadline: .now() + .seconds(3), repeating: .seconds(3), leeway: .milliseconds(250))
        detailTimer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.cpuPanel.isVisible {
                self.refreshProcesses(for: 1)
            }
            if self.ramPanel.isVisible {
                self.refreshProcesses(for: 2)
            }
            if self.netPanel.isVisible {
                self.refreshProcesses(for: 0)
            }
        }
        detailTimer.resume()
        self.detailTimer = detailTimer
    }

    deinit {
        detailTimer?.cancel()
        if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .defaultMode)
        }
    }

    private func installPowerSourceObserver() {
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            delegate.monitor.powerSourceChanged()
        }, context)?.takeRetainedValue() else { return }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSourceRunLoopSource = source
    }

    private func refreshProcesses(for index: Int) {
        switch index {
        case 0:
            guard !netProcessReadInFlight else { return }
            netProcessReadInFlight = true
            netProcessQueue.async { [weak self] in
                guard let self else { return }
                let procs = self.netProcessReader.read()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.netProcessReadInFlight = false
                    self.latestNetProcesses = procs
                    if self.netPanel.isVisible {
                        self.netPopupView.updateProcesses(procs)
                    }
                }
            }
        case 1:
            guard !cpuProcessReadInFlight else { return }
            cpuProcessReadInFlight = true
            cpuProcessQueue.async { [weak self] in
                guard let self else { return }
                let procs = self.cpuProcessReader.read()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.cpuProcessReadInFlight = false
                    self.latestCPUProcesses = procs
                    if self.cpuPanel.isVisible, let latestCPU = self.latestCPU {
                        self.cpuPopupView.update(latestCPU, processes: procs)
                    }
                }
            }
        case 2:
            guard !ramProcessReadInFlight else { return }
            ramProcessReadInFlight = true
            ramProcessQueue.async { [weak self] in
                guard let self else { return }
                let procs = self.ramProcessReader.read()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.ramProcessReadInFlight = false
                    self.latestRAMProcesses = procs
                    if self.ramPanel.isVisible, let latestRAM = self.latestRAM {
                        self.ramPopupView.update(latestRAM, processes: procs)
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

        let panels = allPanels
        let targetPanel = panels[idx]

        // Close others, toggle target
        for (i, panel) in panels.enumerated() {
            if i != idx {
                panel.orderOut(nil)
                monitor.setHistoryEnabled(false, for: i)
            }
        }

        if targetPanel.isVisible {
            targetPanel.orderOut(nil)
            monitor.setHistoryEnabled(false, for: idx)
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
        monitor.setHistoryEnabled(true, for: idx)
        refreshPopup(at: idx, syncHistory: true)
        refreshProcesses(for: idx)
        targetPanel.makeKeyAndOrderFront(nil)
    }

    private func closeAllPanels() {
        allPanels.forEach { $0.orderOut(nil) }
        monitor.setAllHistoryDisabled()
    }

    private func refreshPopup(at index: Int, syncHistory: Bool) {
        switch index {
        case 0:
            if let latestNet {
                netPopupView.update(latestNet, syncHistory: syncHistory)
            }
            netPopupView.updateProcesses(latestNetProcesses)
        case 1:
            if let latestCPU {
                cpuPopupView.update(latestCPU, processes: latestCPUProcesses, syncHistory: syncHistory)
            }
        case 2:
            if let latestRAM {
                ramPopupView.update(latestRAM, processes: latestRAMProcesses, syncHistory: syncHistory)
            }
        case 3:
            if let latestGPU {
                gpuPopupView.update(latestGPU, syncHistory: syncHistory)
            }
        case 4:
            if let latestPower {
                powerPopupView.update(latestPower, syncHistory: syncHistory)
            }
        default:
            break
        }
    }
}

final class SystemMonitor {
    private let cpuReader: CPUReader
    private let ramReader: RAMReader
    private let gpuReader: GPUReader
    private let powerReader: PowerReader
    private let netReader: NetReader
    private let coordinatorQueue = DispatchQueue(label: "mactop.monitor.coordinator", qos: .utility)
    private let cpuQueue = DispatchQueue(label: "mactop.monitor.cpu", qos: .utility)
    private let ramQueue = DispatchQueue(label: "mactop.monitor.ram", qos: .utility)
    private let gpuQueue = DispatchQueue(label: "mactop.monitor.gpu", qos: .utility)
    private let powerQueue = DispatchQueue(label: "mactop.monitor.power", qos: .utility)
    private let netQueue = DispatchQueue(label: "mactop.monitor.net", qos: .utility)
    private let onPower: (PowerDetail) -> Void
    private var timers: [DispatchSourceTimer] = []
    private var cpuReadInFlight = false
    private var ramReadInFlight = false
    private var gpuReadInFlight = false
    private var powerReadInFlight = false
    private var netReadInFlight = false
    private var historyEnabled = Array(repeating: false, count: 5)

    init(config: Config,
         onCPU: @escaping (CPUDetail) -> Void,
         onRAM: @escaping (RAMDetail) -> Void,
         onGPU: @escaping (GPUDetail) -> Void,
         onPower: @escaping (PowerDetail) -> Void,
         onNet: @escaping (NetDetail) -> Void) {

        let interval = config.updateInterval
        cpuReader = CPUReader(updateInterval: interval)
        ramReader = RAMReader(updateInterval: interval)
        gpuReader = GPUReader(updateInterval: interval)
        powerReader = PowerReader(updateInterval: interval)
        netReader = NetReader(updateInterval: interval)
        self.onPower = onPower

        let timer = DispatchSource.makeTimerSource(queue: coordinatorQueue)
        let ms = max(1, Int(interval * 1000))
        let repeating = DispatchTimeInterval.milliseconds(ms)
        timer.schedule(deadline: .now() + repeating, repeating: repeating, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.refreshAll(onCPU: onCPU, onRAM: onRAM, onGPU: onGPU, onNet: onNet)
        }
        timer.resume()
        timers = [timer]
    }

    private func refreshAll(onCPU: @escaping (CPUDetail) -> Void,
                            onRAM: @escaping (RAMDetail) -> Void,
                            onGPU: @escaping (GPUDetail) -> Void,
                            onNet: @escaping (NetDetail) -> Void) {
        let includeNetHistory = historyEnabled[0]
        let includeCPUHistory = historyEnabled[1]
        let includeRAMHistory = historyEnabled[2]
        let includeGPUHistory = historyEnabled[3]
        let includePowerHistory = historyEnabled[4]

        if !cpuReadInFlight {
            cpuReadInFlight = true
            cpuQueue.async { [weak self] in
                guard let self else { return }
                let cpu = self.cpuReader.read(includeHistory: includeCPUHistory)
                DispatchQueue.main.async { onCPU(cpu) }
                self.coordinatorQueue.async { self.cpuReadInFlight = false }
            }
        }

        if !ramReadInFlight {
            ramReadInFlight = true
            ramQueue.async { [weak self] in
                guard let self else { return }
                let ram = self.ramReader.read(includeHistory: includeRAMHistory)
                DispatchQueue.main.async { onRAM(ram) }
                self.coordinatorQueue.async { self.ramReadInFlight = false }
            }
        }

        if !gpuReadInFlight {
            gpuReadInFlight = true
            gpuQueue.async { [weak self] in
                guard let self else { return }
                let gpu = self.gpuReader.read(includeHistory: includeGPUHistory)
                DispatchQueue.main.async { onGPU(gpu) }
                self.coordinatorQueue.async { self.gpuReadInFlight = false }
            }
        }

        if !powerReadInFlight {
            powerReadInFlight = true
            powerQueue.async { [weak self] in
                guard let self else { return }
                let power = self.powerReader.read(includeHistory: includePowerHistory)
                DispatchQueue.main.async { self.onPower(power) }
                self.coordinatorQueue.async { self.powerReadInFlight = false }
            }
        }

        if !netReadInFlight {
            netReadInFlight = true
            netQueue.async { [weak self] in
                guard let self else { return }
                let net = self.netReader.read(includeHistory: includeNetHistory)
                DispatchQueue.main.async { onNet(net) }
                self.coordinatorQueue.async { self.netReadInFlight = false }
            }
        }
    }

    func setHistoryEnabled(_ enabled: Bool, for index: Int) {
        guard historyEnabled.indices.contains(index) else { return }
        coordinatorQueue.async { [weak self] in
            self?.historyEnabled[index] = enabled
        }
    }

    func setAllHistoryDisabled() {
        coordinatorQueue.async { [weak self] in
            self?.historyEnabled = Array(repeating: false, count: 5)
        }
    }

    func powerSourceChanged() {
        powerQueue.async { [weak self] in
            guard let self else { return }
            self.powerReader.invalidateChargingCache()
        }
    }

    deinit {
        timers.forEach { $0.cancel() }
    }
}
