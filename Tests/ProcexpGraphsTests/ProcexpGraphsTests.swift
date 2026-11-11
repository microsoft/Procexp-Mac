import AppKit
import Testing
import ProcexpModel
@testable import ProcexpGraphs

@Suite("W4 Graphs + SystemStats")
struct ProcexpGraphsTests {

    @Test("Reads real system memory and per-core CPU")
    func systemStats() async {
        let provider = SystemStatsProvider()
        _ = await provider.stats()                     // prime CPU deltas
        try? await Task.sleep(nanoseconds: 150_000_000)
        let stats = await provider.stats()
        #expect(stats.memoryTotal > 0)
        #expect(!stats.perCoreCPUPercent.isEmpty)
        #expect(stats.diskBytesPerSec >= 0)
        for core in stats.perCoreCPUPercent { #expect(core >= 0 && core <= 100) }
    }

    @MainActor
    @Test("Sparkline view can be constructed and accepts data")
    func sparklineConstructs() {
        let view = SparklineView(frame: .init(x: 0, y: 0, width: 100, height: 20))
        view.values = [0, 25, 50, 75, 100]
        view.maxValue = 100
        #expect(view.values.count == 5)
    }
}

// MARK: - Graph rendering bounds

/// Every graph view must draw only inside its own bounds.
///
/// Each case renders a graph off-screen with clipping disabled into a bitmap
/// with a transparent margin around it, then requires that no pixel in the
/// margin was touched. Clipping would otherwise hide geometry that overflows,
/// such as a miter join overshooting a sharp peak or half a stroke spilling
/// past an edge.
@Suite("Graph rendering stays inside bounds")
struct GraphBoundsTests {

    /// A named way to build a configured graph view.
    struct Graph: CustomTestStringConvertible, Sendable {
        let name: String
        let make: @MainActor @Sendable () -> NSView
        var testDescription: String { name }
    }

    /// Mostly idle with sudden full-scale peaks (the I/O pattern that exposed
    /// the overshoot), plus out-of-range values and a gap of missing samples.
    static let spikes: [Double] = (0..<60).map { i in
        switch i {
        case 20...22: .nan
        case _ where i % 7 == 3: 100
        case _ where i % 11 == 5: 90
        case 41: 250
        case 47: -30
        default: 0
        }
    }

    /// Always at the maximum, so the line runs along the top edge.
    static let saturated = [Double](repeating: 100, count: 30)

    static let graphs: [Graph] = [
        Graph(name: "Sparkline (toolbar)") {
            let view = SparklineView(frame: NSRect(x: 0, y: 0, width: 130, height: 16))
            view.values = spikes
            return view
        },
        Graph(name: "Sparkline, saturated") {
            let view = SparklineView(frame: NSRect(x: 0, y: 0, width: 130, height: 16))
            view.values = saturated
            return view
        },
        Graph(name: "History graph, one series with grid") {
            let view = HistoryGraphView(frame: NSRect(x: 0, y: 0, width: 320, height: 110))
            view.series = [spikes]
            return view
        },
        Graph(name: "History graph, two series with grid") {
            let view = HistoryGraphView(frame: NSRect(x: 0, y: 0, width: 320, height: 110))
            view.series = [spikes, spikes.map { $0 / 2 }]
            return view
        },
        Graph(name: "History graph, saturated without grid") {
            let view = HistoryGraphView(frame: NSRect(x: 0, y: 0, width: 320, height: 110))
            view.series = [saturated]
            view.showGrid = false
            return view
        },
        Graph(name: "History graph, grid only") {
            HistoryGraphView(frame: NSRect(x: 0, y: 0, width: 320, height: 110))
        },
    ]

    @MainActor
    @Test("Graph views clip to their bounds")
    func clipsToBounds() {
        #expect(SparklineView(frame: .zero).clipsToBounds)
        #expect(HistoryGraphView(frame: .zero).clipsToBounds)
    }

    @MainActor
    @Test("Nothing is drawn outside the graph", arguments: graphs, [CGFloat(1), 2])
    func staysInBounds(graph: Graph, scale: CGFloat) throws {
        let view = graph.make()
        let outside = try pixelsOutside(view, scale: scale)
        #expect(outside == 0, "\(outside) pixel(s) drawn outside the graph at \(scale)x")
    }

    /// Draws `view` unclipped, inset by a margin, and counts the non-transparent
    /// pixels that landed in that margin.
    @MainActor
    private func pixelsOutside(_ view: NSView, scale: CGFloat, margin: CGFloat = 8) throws -> Int {
        let canvas = view.bounds.insetBy(dx: -margin, dy: -margin).size
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = canvas

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let offset = NSAffineTransform()
        offset.translateX(by: margin, yBy: margin)
        offset.concat()
        view.draw(view.bounds)
        NSGraphicsContext.current?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let inset = Int(margin * scale)
        let inside = (x: inset..<(bitmap.pixelsWide - inset), y: inset..<(bitmap.pixelsHigh - inset))
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where !(inside.x.contains(x) && inside.y.contains(y)) {
                if let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent, alpha > 0 { count += 1 }
            }
        }
        return count
    }
}
