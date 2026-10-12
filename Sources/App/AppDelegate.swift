import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let rowCount = 15
    /// At most `processesPerRanking` in the helper, so the rows are a true top list in either sort.
    private let processRowCount = 10
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let summaryItem = NSMenuItem()
    private let memoryDetailItem = NSMenuItem()
    private let headerItem = NSMenuItem()
    private var appItems: [NSMenuItem] = []
    private var processMenus: [NSMenu] = []
    private var rowAppNames: [String] = []
    private var openProcessMenu: NSMenu?
    private let sortByCPUItem = NSMenuItem(title: "Sort by CPU", action: #selector(sortByCPU), keyEquivalent: "")
    private let sortByMemoryItem = NSMenuItem(title: "Sort by Memory", action: #selector(sortByMemory), keyEquivalent: "")
    private var sortsByMemory = UserDefaults.standard.bool(forKey: "sortByMemory")
    private var snapshot: Snapshot?
    private var menuIsOpen = false

    private let titleFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private let rowFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)
    private let columns: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.tabStops = [270, 355, 405].map { NSTextTab(textAlignment: .right, location: $0) }
        return style
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(summaryItem)
        menu.addItem(memoryDetailItem)
        menu.addItem(.separator())
        headerItem.attributedTitle = row("App", "CPU", "Memory", "Procs", color: .secondaryLabelColor)
        headerItem.toolTip = "Memory includes data macOS has compressed or swapped, counted at full size as in Activity Monitor, so app totals can exceed physical RAM."
        menu.addItem(headerItem)
        for _ in 0..<rowCount {
            let item = NSMenuItem()
            item.isHidden = true
            appItems.append(item)
            menu.addItem(item)

            let processMenu = NSMenu()
            processMenu.autoenablesItems = false
            processMenu.delegate = self
            let processHeader = NSMenuItem()
            processHeader.attributedTitle = row("Process", "CPU", "Memory", "PID", color: .secondaryLabelColor)
            processHeader.toolTip = "Hold ⌘ and click a process to force kill it."
            processMenu.addItem(processHeader)
            // Each process has a plain row and a red row that replaces it while ⌘ is held.
            for _ in 0..<processRowCount {
                let processItem = NSMenuItem()
                processItem.keyEquivalentModifierMask = []
                let killItem = NSMenuItem(title: "", action: #selector(forceKill(_:)), keyEquivalent: "")
                killItem.keyEquivalentModifierMask = .command
                killItem.isAlternate = true
                killItem.target = self
                processMenu.addItem(processItem)
                processMenu.addItem(killItem)
            }
            processMenus.append(processMenu)
        }
        menu.addItem(.separator())
        for item in [sortByCPUItem, sortByMemoryItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Act", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        updateTitle()
        HelperClient.start { [weak self] snapshot in
            DispatchQueue.main.async { self?.apply(snapshot) }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu {
            menuIsOpen = true
            renderMenu()
        } else {
            openProcessMenu = menu
            renderProcesses(in: menu)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu { menuIsOpen = false }
        if menu === self.menu || menu === openProcessMenu { openProcessMenu = nil }
    }

    /// While a process submenu is open, the rows keep their order so the submenu stays on its app.
    private func apply(_ snapshot: Snapshot?) {
        self.snapshot = snapshot
        updateTitle()
        if let openProcessMenu {
            renderProcesses(in: openProcessMenu)
        } else if menuIsOpen {
            renderMenu()
        }
    }

    private var topApps: [AppUsage] {
        let apps = snapshot?.apps ?? []
        let sorted = sortsByMemory ? apps.sorted { $0.memory > $1.memory } : apps.sorted { $0.cpuTenths > $1.cpuTenths }
        return Array(sorted.prefix(rowCount))
    }

    private func updateTitle() {
        var text = "Act –"
        if let top = topApps.first {
            text = "\(truncated(top.name, to: 16)) \(sortsByMemory ? memoryText(top.memory) : cpuText(top.cpuTenths))"
        }
        statusItem.button?.attributedTitle = NSAttributedString(string: text, attributes: [.font: titleFont])
    }

    private func renderMenu() {
        if let snapshot {
            let summary = "CPU \(cpuText(snapshot.cpuTenths)) of \(snapshot.cores * 100)%    Memory \(memoryText(snapshot.memoryUsed)) of \(memoryText(snapshot.memoryTotal))"
            summaryItem.attributedTitle = NSAttributedString(string: summary, attributes: [.font: rowFont])
            let detail = "Compressed \(memoryText(snapshot.compressedData)) into \(memoryText(snapshot.compressorMemory))    Swap \(memoryText(snapshot.swapUsed))"
            memoryDetailItem.attributedTitle = NSAttributedString(string: detail, attributes: [.font: rowFont, .foregroundColor: NSColor.secondaryLabelColor])
        } else {
            summaryItem.attributedTitle = NSAttributedString(string: "Waiting for the Act helper…", attributes: [.font: rowFont])
        }
        memoryDetailItem.isHidden = snapshot == nil
        let apps = topApps
        rowAppNames = apps.map(\.name)
        for (index, item) in appItems.enumerated() {
            item.isHidden = index >= apps.count
            guard index < apps.count else { continue }
            let app = apps[index]
            item.attributedTitle = row(app.name, cpuText(app.cpuTenths), memoryText(app.memory), "\(app.processCount)")
            let submenu = app.topProcesses.isEmpty ? nil : processMenus[index]
            if item.submenu !== submenu { item.submenu = submenu }
        }
        sortByCPUItem.state = sortsByMemory ? .off : .on
        sortByMemoryItem.state = sortsByMemory ? .on : .off
    }

    /// Keeps the last rows if the app has dropped out of the snapshot.
    private func renderProcesses(in processMenu: NSMenu) {
        guard let index = processMenus.firstIndex(where: { $0 === processMenu }), index < rowAppNames.count,
              let app = snapshot?.apps.first(where: { $0.name == rowAppNames[index] }) else { return }
        let processes = sortsByMemory
            ? app.topProcesses.sorted { $0.memory > $1.memory }
            : app.topProcesses.sorted { $0.cpuTenths > $1.cpuTenths }
        let items = processMenu.items
        for position in 0..<processRowCount {
            let processItem = items[1 + position * 2]
            let killItem = items[2 + position * 2]
            let shown = position < min(processes.count, processRowCount)
            processItem.isHidden = !shown
            killItem.isHidden = !shown
            guard shown else { continue }
            let process = processes[position]
            let cpu = cpuText(process.cpuTenths), memory = memoryText(process.memory), pid = "\(process.pid)"
            processItem.attributedTitle = row(process.name, cpu, memory, pid)
            killItem.attributedTitle = row(process.name, cpu, memory, pid, color: .systemRed)
            killItem.tag = process.pid
        }
    }

    /// Runs with the user's rights, so processes owned by root or other users fail and beep.
    @objc private func forceKill(_ item: NSMenuItem) {
        // kill() treats 0 and negative pids as process groups.
        guard item.tag > 1 else { return }
        if kill(pid_t(item.tag), SIGKILL) != 0 { NSSound.beep() }
    }

    @objc private func sortByCPU() { setSort(byMemory: false) }
    @objc private func sortByMemory() { setSort(byMemory: true) }

    private func setSort(byMemory: Bool) {
        sortsByMemory = byMemory
        UserDefaults.standard.set(byMemory, forKey: "sortByMemory")
        updateTitle()
        renderMenu()
    }

    private func row(_ name: String, _ cpu: String, _ memory: String, _ processes: String, color: NSColor = .labelColor) -> NSAttributedString {
        NSAttributedString(
            string: "\(fitted(name, width: 200))\t\(cpu)\t\(memory)\t\(processes)",
            attributes: [.font: rowFont, .paragraphStyle: columns, .foregroundColor: color]
        )
    }

    /// Cuts the name so it ends before the CPU column, even for a 5-digit CPU value.
    private func fitted(_ name: String, width: CGFloat) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: rowFont]
        guard (name as NSString).size(withAttributes: attributes).width > width else { return name }
        var text = name
        while !text.isEmpty, ((text + "…") as NSString).size(withAttributes: attributes).width > width {
            text.removeLast()
        }
        return text + "…"
    }

    private func truncated(_ text: String, to length: Int) -> String {
        text.count > length ? text.prefix(length - 1) + "…" : text
    }

    private func cpuText(_ tenths: Int) -> String {
        tenths >= 100 ? "\(tenths / 10)%" : "\(tenths / 10).\(tenths % 10)%"
    }

    private func memoryText(_ bytes: UInt64) -> String {
        let gigabyte = 1_073_741_824.0
        let value = Double(bytes)
        return value >= gigabyte ? String(format: "%.1f GB", value / gigabyte) : String(format: "%.0f MB", value / 1_048_576)
    }
}
