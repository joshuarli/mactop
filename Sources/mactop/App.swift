import AppKit

@main
struct Mactop {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItems: [NSStatusItem] = []
    private var cpuView: MiniView!
    private var ramView: MiniView!
    private var gpuView: MiniView!
    private var netView: SpeedView!
    private var monitor: SystemMonitor!
    private var netProcessTimer: Timer?
    private var netProcessReader = NetProcessReader()

    private var cpuPopupView: CPUPopupView!
    private var ramPopupView: RAMPopupView!
    private var gpuPopupView: GPUPopupView!
    private var netPopupView: NetPopupView!

    private var cpuPanel: PopupPanel!
    private var ramPanel: PopupPanel!
    private var gpuPanel: PopupPanel!
    private var netPanel: PopupPanel!
    private var statusPanels: [PopupPanel] = []

    private var allPanels: [PopupPanel] { statusPanels }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let barH  = NSStatusBar.system.thickness
        let viewH = barH - 4

        cpuView = MiniView(label: "CPU")
        ramView = MiniView(label: "RAM")
        gpuView = MiniView(label: "GPU")
        netView = SpeedView()

        cpuPopupView = CPUPopupView()
        ramPopupView = RAMPopupView()
        gpuPopupView = GPUPopupView()
        netPopupView = NetPopupView()

        cpuPanel = PopupPanel(contentView: cpuPopupView)
        ramPanel = PopupPanel(contentView: ramPopupView)
        gpuPanel = PopupPanel(contentView: gpuPopupView)
        netPanel = PopupPanel(contentView: netPopupView)

        let entries: [(view: NSView, width: CGFloat, panel: PopupPanel)] = [
            (netView!, 55, netPanel),
            (cpuView!, 31, cpuPanel),
            (ramView!, 31, ramPanel),
            (gpuView!, 31, gpuPanel),
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
            onCPU: { [weak self] cpu, procs in
                guard let self else { return }
                self.cpuView.value = cpu.total
                self.cpuPopupView.update(cpu, processes: procs)
            },
            onRAM: { [weak self] ram, procs in
                guard let self else { return }
                self.ramView.value = ram.total
                self.ramPopupView.update(ram, processes: procs)
            },
            onGPU: { [weak self] gpu in
                guard let self else { return }
                self.gpuView.value = gpu.total
                self.gpuPopupView.update(gpu)
            },
            onNet: { [weak self] net in
                guard let self else { return }
                self.netView.upload   = Int64(net.upload)
                self.netView.download = Int64(net.download)
                self.netPopupView.update(net)
            }
        )

        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeAllPanels()
        }

        // nettop spawns a subprocess — run it off the main thread so it never
        // blocks the run loop or status-bar repaints.
        netProcessTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let procs = self.netProcessReader.read()
                DispatchQueue.main.async { [weak self] in
                    self?.netPopupView.updateProcesses(procs)
                }
            }
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let item = statusItems.first(where: { $0.button === sender }) else { return }
        let idx = statusItems.firstIndex(where: { $0.button === sender }) ?? 0

        let panels = allPanels
        let targetPanel = panels[idx]

        // Close others, toggle target
        for (i, panel) in panels.enumerated() {
            if i != idx { panel.orderOut(nil) }
        }

        if targetPanel.isVisible {
            targetPanel.orderOut(nil)
            return
        }

        guard let button = item.button,
              let screen = button.window?.screen ?? NSScreen.main else { return }

        let buttonRect = button.window!.convertToScreen(button.frame)
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
        targetPanel.makeKeyAndOrderFront(nil)
    }

    private func closeAllPanels() {
        allPanels.forEach { $0.orderOut(nil) }
    }
}

final class SystemMonitor {
    private let cpuReader        = CPUReader()
    private let ramReader        = RAMReader()
    private let gpuReader        = GPUReader()
    private let netReader        = NetReader()
    private let cpuProcessReader = CPUProcessReader()
    private let ramProcessReader = RAMProcessReader()
    private var timers: [Timer]  = []

    init(config: Config,
         onCPU: @escaping (CPUDetail, [TopProcess]) -> Void,
         onRAM: @escaping (RAMDetail, [TopProcess]) -> Void,
         onGPU: @escaping (GPUDetail) -> Void,
         onNet: @escaping (NetDetail) -> Void) {

        _ = cpuReader.read()
        _ = netReader.read()

        func every(_ interval: Double, _ block: @escaping () -> Void) -> Timer {
            Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in block() }
        }

        timers = [
            every(config.cpuInterval) { [weak self] in
                guard let self else { return }
                onCPU(self.cpuReader.read(), self.cpuProcessReader.read())
            },
            every(config.ramInterval) { [weak self] in
                guard let self else { return }
                onRAM(self.ramReader.read(), self.ramProcessReader.read())
            },
            every(config.gpuInterval) { [weak self] in
                guard let self else { return }
                onGPU(self.gpuReader.read())
            },
            every(config.netInterval) { [weak self] in
                guard let self else { return }
                onNet(self.netReader.read())
            },
        ]
    }
}
