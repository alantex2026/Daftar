//  SplitContainerView.swift
//  Bridges to a real AppKit NSSplitView so the three column widths - and
//  whether the sidebar is collapsed - persist across relaunches via
//  `autosaveName`. SwiftUI's own HSplitView has no way to do this: there is
//  no SwiftUI modifier for it, only the classic AppKit property.
//
//  The sidebar collapse/expand goes through NSSplitView's own native
//  collapse mechanism (`setPosition(_:ofDividerAt:)` + `canCollapseSubview`)
//  rather than manually toggling `isHidden` - a hand-rolled toggle left
//  stale divider-line ghosting behind after every animated collapse/expand,
//  because it fought with how the split view redraws its own dividers.
//  Driving it the way AppKit expects sidesteps that entirely.

import SwiftUI
import AppKit

struct SplitContainerView<Sidebar: View, Outline: View, Detail: View>: NSViewRepresentable {
    @Binding var isSidebarVisible: Bool
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var outline: () -> Outline
    @ViewBuilder var detail: () -> Detail

    // Lower bounds are sized so the three panes' combined minimum
    // (150+150+320 = 620, plus ~2pt for the two dividers) fits under 640pt -
    // half the width of even a 13" MacBook Air (1280pt) - so tiling the
    // window to half-screen with macOS's own window snapping isn't blocked.
    static var sidebarRange: ClosedRange<CGFloat> { 150...360 }
    static var outlineRange: ClosedRange<CGFloat> { 150...420 }
    static var detailMinWidth: CGFloat { 320 }
    static var defaultSidebarWidth: CGFloat { 225 }

    func makeCoordinator() -> Coordinator { Coordinator(isSidebarVisible: $isSidebarVisible) }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator

        let sidebarHost = NSHostingView(rootView: sidebar())
        let outlineHost = NSHostingView(rootView: outline())
        let detailHost = NSHostingView(rootView: detail())
        for host in [sidebarHost, outlineHost, detailHost] {
            host.translatesAutoresizingMaskIntoConstraints = true
        }
        // Reasonable starting proportions for the very first launch, before
        // any autosave data exists to override them.
        sidebarHost.frame = NSRect(x: 0, y: 0, width: Self.defaultSidebarWidth, height: 0)
        outlineHost.frame = NSRect(x: 0, y: 0, width: 235, height: 0)
        detailHost.frame = NSRect(x: 0, y: 0, width: 480, height: 0)

        context.coordinator.sidebarHost = sidebarHost
        context.coordinator.outlineHost = outlineHost
        context.coordinator.detailHost = detailHost
        context.coordinator.lastSidebarWidth = Self.defaultSidebarWidth

        // NSSplitView lays out arrangedSubviews left-to-right in array order
        // regardless of locale - unlike SwiftUI stacks, it does not mirror
        // itself for RTL. In Arabic, the sidebar belongs on the visual
        // right (the "leading" edge in RTL), so the add order is reversed;
        // the Coordinator's divider-position math below mirrors along with it.
        if NSApp.userInterfaceLayoutDirection == .rightToLeft {
            splitView.addArrangedSubview(detailHost)
            splitView.addArrangedSubview(outlineHost)
            splitView.addArrangedSubview(sidebarHost)
        } else {
            splitView.addArrangedSubview(sidebarHost)
            splitView.addArrangedSubview(outlineHost)
            splitView.addArrangedSubview(detailHost)
        }
        if !isSidebarVisible {
            sidebarHost.isHidden = true
        }

        // Set the autosave name last, once the split view has its subviews -
        // this is what makes AppKit persist and restore divider positions
        // across launches, keyed by this name, entirely on its own.
        splitView.autosaveName = "Daftar.MainSplit"

        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        PerfLog.mark("SplitContainerView.updateNSView called")
        PerfLog.measure("  sidebarHost.rootView =") { context.coordinator.sidebarHost?.rootView = sidebar() }
        PerfLog.measure("  outlineHost.rootView =") { context.coordinator.outlineHost?.rootView = outline() }
        PerfLog.measure("  detailHost.rootView =") { context.coordinator.detailHost?.rootView = detail() }

        guard let sidebarHost = context.coordinator.sidebarHost, !context.coordinator.isApplyingExternalChange,
              sidebarHost.isHidden == isSidebarVisible else { return }

        if !sidebarHost.isHidden {
            // About to collapse - remember the current width so expanding
            // later restores it, instead of always snapping back to default.
            context.coordinator.lastSidebarWidth = max(sidebarHost.frame.width, Self.sidebarRange.lowerBound)
        }
        let targetPosition = isSidebarVisible ? context.coordinator.lastSidebarWidth : 0
        let isRTL = NSApp.userInterfaceLayoutDirection == .rightToLeft
        // In RTL the sidebar is the last arranged subview, so it's bounded
        // by divider 1, not 0, and a given sidebar width lands at a
        // position mirrored from the right edge instead of measured from 0.
        let sidebarDividerIndex = isRTL ? 1 : 0
        let actualTargetPosition = isRTL
            ? splitView.bounds.width - splitView.dividerThickness - targetPosition
            : targetPosition

        NSAnimationContext.runAnimationGroup { animation in
            animation.duration = 0.22
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            splitView.animator().setPosition(actualTargetPosition, ofDividerAt: sidebarDividerIndex)
        }
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        var sidebarHost: NSHostingView<Sidebar>?
        var outlineHost: NSHostingView<Outline>?
        var detailHost: NSHostingView<Detail>?
        var lastSidebarWidth: CGFloat = SplitContainerView.defaultSidebarWidth
        var isApplyingExternalChange = false

        private let isSidebarVisible: Binding<Bool>

        init(isSidebarVisible: Binding<Bool>) {
            self.isSidebarVisible = isSidebarVisible
        }

        /// Only the sidebar can collapse - this is what lets
        /// `setPosition(0, ofDividerAt: 0)` actually hide it instead of
        /// being clamped to `sidebarRange.lowerBound`, and also what allows
        /// dragging the divider all the way shut by hand.
        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
            subview === sidebarHost
        }

        /// Keeps the SwiftUI binding in sync if the sidebar was collapsed or
        /// expanded by dragging the divider directly, not just via the
        /// toolbar toggle. NSSplitViewDelegate calls this automatically -
        /// no manual NotificationCenter registration needed.
        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let sidebarHost else { return }
            let visible = !sidebarHost.isHidden
            guard visible != isSidebarVisible.wrappedValue else { return }
            isApplyingExternalChange = true
            isSidebarVisible.wrappedValue = visible
            isApplyingExternalChange = false
        }

        // Both constraint methods below are expressed as if the layout were
        // always sidebar-outline-detail left to right, then mirrored for
        // RTL. For a 3-pane, 2-divider split, reversing the pane order maps
        // divider i's real position to `total - thickness - (logical
        // position of divider 1-i)` - so a mirrored min is the logical max
        // of the other divider, and vice versa. This reuses the exact same
        // LTR math for both directions instead of re-deriving it by hand.

        private func logicalMinCoordinate(_ splitView: NSSplitView, dividerIndex: Int) -> CGFloat {
            switch dividerIndex {
            case 0:
                return sidebarRange.lowerBound
            case 1:
                let sidebarWidth = (sidebarHost?.isHidden ?? true) ? 0 : (sidebarHost?.frame.width ?? 0)
                let sidebarSpace = (sidebarHost?.isHidden ?? true) ? 0 : splitView.dividerThickness
                return sidebarWidth + sidebarSpace + outlineRange.lowerBound
            default:
                return 0
            }
        }

        private func logicalMaxCoordinate(_ splitView: NSSplitView, dividerIndex: Int) -> CGFloat {
            switch dividerIndex {
            case 0:
                return sidebarRange.upperBound
            case 1:
                let sidebarWidth = (sidebarHost?.isHidden ?? true) ? 0 : (sidebarHost?.frame.width ?? 0)
                let sidebarSpace = (sidebarHost?.isHidden ?? true) ? 0 : splitView.dividerThickness
                let byOutlineMax = sidebarWidth + sidebarSpace + outlineRange.upperBound
                // Guarded against going negative if this is ever evaluated
                // before the split view has been given a real width.
                let byDetailMin = max(splitView.bounds.width - splitView.dividerThickness - detailMinWidth, outlineRange.lowerBound)
                return min(byOutlineMax, byDetailMin)
            default:
                return splitView.bounds.width
            }
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            guard NSApp.userInterfaceLayoutDirection == .rightToLeft else {
                return logicalMinCoordinate(splitView, dividerIndex: dividerIndex)
            }
            let mirrored = logicalMaxCoordinate(splitView, dividerIndex: 1 - dividerIndex)
            return splitView.bounds.width - splitView.dividerThickness - mirrored
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            guard NSApp.userInterfaceLayoutDirection == .rightToLeft else {
                return logicalMaxCoordinate(splitView, dividerIndex: dividerIndex)
            }
            let mirrored = logicalMinCoordinate(splitView, dividerIndex: 1 - dividerIndex)
            return splitView.bounds.width - splitView.dividerThickness - mirrored
        }

        private var sidebarRange: ClosedRange<CGFloat> { SplitContainerView.sidebarRange }
        private var outlineRange: ClosedRange<CGFloat> { SplitContainerView.outlineRange }
        private var detailMinWidth: CGFloat { SplitContainerView.detailMinWidth }
    }
}
