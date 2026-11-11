//
//  GraphPlot.swift
//  ProcexpGraphs — W4
//
//  Geometry and drawing shared by the graph views (`SparklineView`,
//  `HistoryGraphView`), so every graph maps samples to points and strokes its
//  lines the same way.
//

import AppKit

/// Maps samples onto a view and draws them as a filled line graph.
///
/// Points are laid out in `rect`: the view's bounds inset by half a line
/// width. A stroke centred on a point at an edge (a sample at 0 or at the
/// maximum, the oldest or newest sample, an outer grid line) therefore stays
/// entirely inside the view instead of spilling half its width past it.
struct GraphPlot {

    /// Stroke width of a series line.
    static let lineWidth: CGFloat = 1

    /// Area that sample points (and grid lines) are placed in.
    let rect: NSRect

    /// Value that maps to the top of `rect`. Always finite and positive.
    let maxValue: Double

    init(bounds: NSRect, maxValue: Double) {
        let inset = Self.lineWidth / 2
        self.rect = bounds.insetBy(dx: min(inset, bounds.width / 2),
                                   dy: min(inset, bounds.height / 2))
        self.maxValue = maxValue.isFinite && maxValue > 0 ? maxValue : 1
    }

    /// Vertical position of `value`, clamped to `0...maxValue`.
    func y(for value: Double) -> CGFloat {
        let fraction = min(max(value, 0), maxValue) / maxValue
        return rect.minY + CGFloat(fraction) * rect.height
    }

    /// Draws `samples` oldest → newest (left → right) as a filled area topped
    /// by a line. Non-finite samples keep their time slot but leave a gap.
    func drawSeries(_ samples: [Double], line lineColor: NSColor, fill fillColor: NSColor) {
        guard samples.count > 1 else { return }
        let stepX = rect.width / CGFloat(samples.count - 1)

        func point(at index: Int) -> NSPoint {
            NSPoint(x: rect.minX + CGFloat(index) * stepX, y: y(for: samples[index]))
        }

        for segment in samples.indices.split(whereSeparator: { !samples[$0].isFinite }) {
            guard segment.count > 1 else { continue }
            let points = segment.map(point(at:))

            let area = NSBezierPath()
            area.move(to: NSPoint(x: points[0].x, y: rect.minY))
            points.forEach(area.line(to:))
            area.line(to: NSPoint(x: points[points.count - 1].x, y: rect.minY))
            area.close()
            fillColor.setFill()
            area.fill()

            let line = NSBezierPath()
            line.lineWidth = Self.lineWidth
            // The default miter join extends far past the point on a sharp
            // peak (spiky I/O samples), poking out of the graph. A round join
            // stays within half a line width of the point.
            line.lineJoinStyle = .round
            line.move(to: points[0])
            points.dropFirst().forEach(line.line(to:))
            lineColor.setStroke()
            line.stroke()
        }
    }
}
