import Foundation
import ProcexpModel
import ProcexpGraphs

enum MenuBarMetric: String, CaseIterable, Identifiable {
    case cpu, memory, io, disk, network, gpu

    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Physical Memory"
        case .io: return "I/O"
        case .disk: return "Disk"
        case .network: return "Network"
        case .gpu: return "GPU"
        }
    }

    var isPercentage: Bool { self == .cpu || self == .memory || self == .gpu }

    @MainActor func values(in model: AppModel) -> [Double] {
        switch self {
        case .cpu: return model.cpuHistory.values
        case .memory: return model.memoryHistory.values
        case .io: return model.ioHistory.values
        case .disk: return model.diskHistory.values
        case .network: return model.networkHistory.values
        case .gpu: return model.gpuHistory.values
        }
    }

    func maximum(for values: [Double]) -> Double {
        isPercentage ? 100 : max(1, values.filter(\.isFinite).max() ?? 1)
    }

    func readout(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "\(title): Unavailable" }
        let formatted = isPercentage ? String(format: "%.1f%%", value) : GraphUnit.bytesPerSecond.format(value)
        return "\(title): \(formatted)"
    }
}
