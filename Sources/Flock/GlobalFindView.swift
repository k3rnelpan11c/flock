import AppKit
import SwiftTerm

// MARK: - Global Find (search across all panes)

class GlobalFindView {
    weak var paneManager: PaneManager?
    private var backdropView: CommandBackdropView?
    private var panel: GlobalFindPanel?
    private var isVisible = false

    func show(in window: NSWindow, paneManager: PaneManager) {
        guard !isVisible, let contentView = window.contentView else { return }
        isVisible = true
        self.paneManager = paneManager

        // Backdrop
        let backdrop = CommandBackdropView(frame: contentView.bounds)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.onClickOutside = { [weak self] in self?.dismiss() }
        contentView.addSubview(backdrop)
        self.backdropView = backdrop

        // Panel
        let panelW: CGFloat = 480
        let panelH: CGFloat = 400
        let panelX = floor((contentView.bounds.width - panelW) / 2)
        let panelY: CGFloat
        if contentView.isFlipped {
            panelY = contentView.bounds.height * 0.18
        } else {
            panelY = contentView.bounds.height - contentView.bounds.height * 0.18 - panelH
        }

        let panel = GlobalFindPanel(
            frame: NSRect(x: panelX, y: panelY, width: panelW, height: panelH),
            paneManager: paneManager
        )
        panel.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        panel.onDismiss = { [weak self] in self?.dismiss() }
        contentView.addSubview(panel)
        self.panel = panel

        // Animate in
        backdrop.alphaValue = 0
        panel.alphaValue = 0
        panel.wantsLayer = true
        panel.layer?.transform = CATransform3DMakeScale(0.97, 0.97, 1)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = Theme.Anim.snappyTimingFunction
            backdrop.animator().alphaValue = 1
            panel.animator().alphaValue = 1
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        CATransaction.setAnimationTimingFunction(Theme.Anim.snappyTimingFunction)
        panel.layer?.transform = CATransform3DIdentity
        CATransaction.commit()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard self?.isVisible == true else { return }
            window.makeFirstResponder(panel.searchField)
        }
    }

    func dismiss() {
        guard isVisible else { return }
        isVisible = false

        // Clear searches on all panes
        paneManager?.panes.forEach { ($0 as? TerminalPane)?.terminalView.clearSearch() }

        let backdrop = self.backdropView
        let panel = self.panel

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Theme.Anim.fast
            ctx.timingFunction = Theme.Anim.snappyTimingFunction
            backdrop?.animator().alphaValue = 0
            panel?.animator().alphaValue = 0
        }, completionHandler: {
            backdrop?.removeFromSuperview()
            panel?.removeFromSuperview()
        })
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Anim.fast)
        CATransaction.setAnimationTimingFunction(Theme.Anim.snappyTimingFunction)
        panel?.layer?.transform = CATransform3DMakeScale(0.98, 0.98, 1)
        CATransaction.commit()

        self.backdropView = nil
        self.panel = nil
    }
}

// MARK: - Panel

class GlobalFindPanel: NSView, NSTextFieldDelegate {
    let searchField: CommandSearchField
    private let divider = NSView(frame: .zero)
    private let resultsView: GlobalFindResultsView
    private weak var paneManager: PaneManager?
    var onDismiss: (() -> Void)?

    struct PaneMatch {
        let pane: FlockPane
        let paneIndex: Int
        let name: String
        let hasMatch: Bool
    }
    private var matches: [PaneMatch] = []

    override var isFlipped: Bool { true }

    init(frame: NSRect, paneManager: PaneManager) {
        self.paneManager = paneManager
        self.searchField = CommandSearchField(frame: .zero)
        self.resultsView = GlobalFindResultsView(frame: .zero)
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = Theme.surface.withAlphaComponent(0.97).cgColor
        layer?.cornerRadius = Theme.paneRadius
        layer?.borderWidth = 0.5
        layer?.borderColor = Theme.borderRest.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 24
        layer?.shadowOffset = CGSize(width: 0, height: 10)

        // Search field
        searchField.placeholderString = "Search all panes..."
        searchField.font = Theme.Typo.searchInput
        searchField.textColor = Theme.textPrimary
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.onTextChange = { [weak self] text in self?.performSearch(text) }
        searchField.onEscape = { [weak self] in self?.onDismiss?() }
        searchField.onEnter = { [weak self] in self?.selectCurrent() }
        searchField.onArrowDown = { [weak self] in self?.moveSelection(by: 1) }
        searchField.onArrowUp = { [weak self] in self?.moveSelection(by: -1) }
        addSubview(searchField)

        // Divider
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.divider.cgColor
        addSubview(divider)

        // Results
        resultsView.onSelect = { [weak self] match in
            guard let self, let mgr = self.paneManager else { return }
            mgr.focusPane(at: match.paneIndex)
            self.onDismiss?()
        }
        addSubview(resultsView)

        // Show all panes initially
        updateAllPanes(term: "")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        let w = bounds.width
        let topPad: CGFloat = Theme.Space.xs
        let fieldH: CGFloat = 48
        let divH: CGFloat = 1
        let pad: CGFloat = Theme.Space.lg

        searchField.frame = NSRect(x: pad, y: topPad, width: w - pad * 2, height: fieldH)
        divider.frame = NSRect(x: 0, y: topPad + fieldH, width: w, height: divH)
        resultsView.frame = NSRect(x: 0, y: topPad + fieldH + divH, width: w, height: bounds.height - topPad - fieldH - divH)
    }

    private func performSearch(_ term: String) {
        guard let mgr = paneManager else { return }

        mgr.panes.forEach { ($0 as? TerminalPane)?.terminalView.clearSearch() }

        if term.isEmpty {
            updateAllPanes(term: "")
            return
        }

        var results: [PaneMatch] = []
        for (i, pane) in mgr.panes.enumerated() {
            let found = if let terminalPane = pane as? TerminalPane {
                terminalPane.terminalView.findNext(term)
            } else {
                pane.matchesSearchTerm(term)
            }
            let name = pane.customName ?? pane.processTitle ?? pane.paneType.label
            results.append(PaneMatch(pane: pane, paneIndex: i, name: name, hasMatch: found))
        }

        // Show matching panes first, then non-matching
        matches = results.filter { $0.hasMatch } + results.filter { !$0.hasMatch }
        resultsView.results = matches
        resultsView.selectedIndex = matches.isEmpty ? -1 : 0
        resultsView.needsDisplay = true
    }

    private func updateAllPanes(term: String) {
        guard let mgr = paneManager else { return }
        matches = mgr.panes.enumerated().map { (i, pane) in
            let name = pane.customName ?? pane.processTitle ?? pane.paneType.label
            return PaneMatch(pane: pane, paneIndex: i, name: name, hasMatch: false)
        }
        resultsView.results = matches
        resultsView.selectedIndex = matches.isEmpty ? -1 : 0
        resultsView.needsDisplay = true
    }

    private func moveSelection(by delta: Int) {
        guard !matches.isEmpty else { return }
        var idx = resultsView.selectedIndex + delta
        idx = max(0, min(idx, matches.count - 1))
        resultsView.selectedIndex = idx
        resultsView.needsDisplay = true
    }

    private func selectCurrent() {
        let idx = resultsView.selectedIndex
        guard idx >= 0, idx < matches.count else { return }
        resultsView.onSelect?(matches[idx])
    }
}

// MARK: - Results View

private class GlobalFindResultsView: NSView {
    struct PaneMatch {
        let pane: FlockPane
        let paneIndex: Int
        let name: String
        let hasMatch: Bool
    }

    var results: [GlobalFindPanel.PaneMatch] = [] {
        didSet {
            // Map to our internal type isn't needed — we use the panel's type directly
        }
    }
    var selectedIndex: Int = 0
    var onSelect: ((GlobalFindPanel.PaneMatch) -> Void)?

    private let rowHeight: CGFloat = 40
    private let pad: CGFloat = Theme.Space.lg
    private var hoveredIndex: Int = -1

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(dirtyRect)

        for (i, result) in results.enumerated() {
            let rowRect = NSRect(x: 0, y: CGFloat(i) * rowHeight, width: bounds.width, height: rowHeight)
            guard rowRect.intersects(dirtyRect) else { continue }

            // Selection / hover background
            if i == selectedIndex {
                Theme.hover.setFill()
                NSBezierPath(roundedRect: rowRect.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
                Theme.accent.setFill()
                NSBezierPath(roundedRect: NSRect(x: 4, y: rowRect.minY + 6, width: 3, height: rowRect.height - 12), xRadius: 1.5, yRadius: 1.5).fill()
            } else if i == hoveredIndex {
                Theme.hover.withAlphaComponent(0.5).setFill()
                NSBezierPath(roundedRect: rowRect.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
            }

            // Pane type icon
            let iconName = result.pane.paneType.isAgent ? "brain" : (result.pane.paneType == .markdown ? "doc.text" : "terminal")
            let iconColor = result.hasMatch ? Theme.accent : Theme.textTertiary
            if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                let configured = img.withSymbolConfiguration(config) ?? img
                let iconRect = NSRect(x: pad, y: rowRect.midY - 8, width: 16, height: 16)
                configured.tinted(with: iconColor).draw(in: iconRect)
            }

            // Pane name
            let nameX = pad + 24
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: result.hasMatch ? Theme.textPrimary : Theme.textSecondary,
            ]
            let nameStr = NSAttributedString(string: result.name, attributes: nameAttrs)
            let nameSize = nameStr.size()
            nameStr.draw(at: NSPoint(x: nameX, y: rowRect.midY - nameSize.height / 2))

            // Pane index badge
            let indexStr = "\(result.paneIndex + 1)"
            let indexAttrs: [NSAttributedString.Key: Any] = [
                .font: Theme.Typo.badge,
                .foregroundColor: Theme.textTertiary,
            ]
            let indexSize = indexStr.size(withAttributes: indexAttrs)
            let badgeW = indexSize.width + 10
            let badgeH: CGFloat = 18
            let badgeX = bounds.width - pad - badgeW
            let badgeY = rowRect.midY - badgeH / 2
            let badgeRect = NSRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)
            Theme.chrome.setFill()
            NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4).fill()
            indexStr.draw(at: NSPoint(x: badgeRect.midX - indexSize.width / 2, y: badgeRect.midY - indexSize.height / 2), withAttributes: indexAttrs)

            // Match indicator
            if result.hasMatch {
                let matchAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: Theme.accent,
                ]
                let matchStr = NSAttributedString(string: "Match found", attributes: matchAttrs)
                let matchSize = matchStr.size()
                matchStr.draw(at: NSPoint(x: badgeX - matchSize.width - 8, y: rowRect.midY - matchSize.height / 2))
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let idx = Int(pt.y / rowHeight)
        if idx >= 0, idx < results.count, idx != hoveredIndex {
            hoveredIndex = idx
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = -1
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let idx = Int(pt.y / rowHeight)
        if idx >= 0, idx < results.count {
            onSelect?(results[idx])
        }
    }
}

// MARK: - NSImage tint helper

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let tinted = NSImage(size: size, flipped: false) { [self] rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }
}
