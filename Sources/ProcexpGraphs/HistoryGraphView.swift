//
//  HistoryGraphView.swift
//  ProcexpGraphs — W4
//
//  A larger scrolling history graph mirroring Process Explorer's System
//  Information CPU/memory graphs: grid lines, newest sample on the right, and
//  support for a second overlaid series (e.g. kernel time over total CPU).
//
//  Each series is drawn oldest → newest (left → right). Series are expected to
//  share the same `maxValue` scale.
//

import AppKit
import ProcexpModel

@MainActor
public final class HistoryGraphView: NSView {

    /// One or two data series, oldest → newest. Redraws on set.
    public var series: [[Double]] = [] {
        didSet { needsDisplay = true }
    }

    /// Stroke/fill color per series (index-matched to `series`).
    public var seriesColors: [RGBA] = [RGBA(0, 200, 0), RGBA(200, 0, 0)] {
        didSet { needsDisplay = true }
    }

    /// Upper bound used to scale all series. Values above are clamped.
    public var maxValue: Double = 100 {
        didSet { needsDisplay = true }
    }

    /// Grid line color.
    public var gridColor: RGBA = RGBA(0, 80, 0) {
        didSet { needsDisplay = true }
    }

    /// Background fill.
    public var graphBackgroundColor: RGBA = RGBA(0, 0, 0) {
        didSet { needsDisplay = true }
    }

    /// Toggle the grid overlay.
    public var showGrid: Bool = true {
        didSet { needsDisplay = true }
    }

    /// Number of horizontal/vertical grid divisions.
    public var gridDivisions: Int = 4 {
        didSet { needsDisplay = true }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        clipsToBounds = true
    }

    public override var isFlipped: Bool { false }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor(graphBackgroundColor).setFill()
        bounds.fill()

        let plot = GraphPlot(bounds: bounds, maxValue: maxValue)
        if showGrid {
            drawGrid(in: plot.rect)
        }
        for (index, samples) in series.enumerated() {
            let rgba = seriesColors.indices.contains(index) ? seriesColors[index] : RGBA(0, 200, 0)
            let color = NSColor(rgba)
            plot.drawSeries(samples, line: color, fill: color.withAlphaComponent(0.20))
        }
    }

    /// Grid lines span the plot area, so the outer lines coincide with the
    /// 0 and maximum levels of the series and stay inside the view.
    private func drawGrid(in rect: NSRect) {
        guard gridDivisions > 0 else { return }
        let path = NSBezierPath()
        path.lineWidth = 0.5
        for step in 0...gridDivisions {
            let fraction = CGFloat(step) / CGFloat(gridDivisions)
            let y = rect.minY + rect.height * fraction
            let x = rect.minX + rect.width * fraction
            path.move(to: NSPoint(x: rect.minX, y: y))
            path.line(to: NSPoint(x: rect.maxX, y: y))
            path.move(to: NSPoint(x: x, y: rect.minY))
            path.line(to: NSPoint(x: x, y: rect.maxY))
        }
        NSColor(gridColor).setStroke()
        path.stroke()
    }
}
