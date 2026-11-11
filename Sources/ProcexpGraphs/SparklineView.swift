//
//  SparklineView.swift
//  ProcexpGraphs — W4
//
//  A compact filled line graph suitable for embedding in a table cell.
//  Draws a single `[Double]` history scaled to `0...maxValue`, oldest → newest
//  (left → right). Redraws whenever any public property changes.
//

import AppKit
import ProcexpModel

@MainActor
public final class SparklineView: NSView {

    /// Sample history, oldest → newest. Redraws on set.
    public var values: [Double] = [] {
        didSet { needsDisplay = true }
    }

    /// Upper bound used to scale samples. Values above are clamped.
    public var maxValue: Double = 100 {
        didSet { needsDisplay = true }
    }

    /// Stroke color of the line.
    public var lineColor: RGBA = RGBA(0, 200, 0) {
        didSet { needsDisplay = true }
    }

    /// Fill color under the line.
    public var fillColor: RGBA = RGBA(0, 200, 0, 0.25) {
        didSet { needsDisplay = true }
    }

    /// Background fill.
    public var graphBackgroundColor: RGBA = RGBA(0, 0, 0) {
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

        GraphPlot(bounds: bounds, maxValue: maxValue)
            .drawSeries(values, line: NSColor(lineColor), fill: NSColor(fillColor))
    }
}
