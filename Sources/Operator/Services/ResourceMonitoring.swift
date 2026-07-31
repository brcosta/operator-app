import Darwin
import Foundation
import Network

enum ResourceNetworkState: String, Equatable {
  case online
  case constrained
  case offline
  case unknown

  var title: String {
    switch self {
    case .online: "Network online"
    case .constrained: "Network constrained"
    case .offline: "Network offline"
    case .unknown: "Network unknown"
    }
  }

  var symbolName: String {
    switch self {
    case .online: "network"
    case .constrained: "wifi.exclamationmark"
    case .offline: "wifi.slash"
    case .unknown: "network.slash"
    }
  }
}

enum HostPowerSource: Equatable {
  case ac
  case battery
  case unknown

  var title: String {
    switch self {
    case .ac: "Power adapter"
    case .battery: "Battery power"
    case .unknown: "Power source unknown"
    }
  }

  static func parse(pmsetOutput: String) -> HostPowerSource {
    let lowercased = pmsetOutput.lowercased()
    if lowercased.contains("battery power") { return .battery }
    if lowercased.contains("ac power") { return .ac }
    return .unknown
  }
}

struct ProcessResourceSnapshot: Equatable {
  var pid: Int32?
  var cpuPercent: Double?
  var memoryBytes: UInt64?
  var network: ResourceNetworkState = .unknown

  static let unavailable = ProcessResourceSnapshot()

  var isRunaway: Bool {
    (cpuPercent ?? 0) >= 90 || (memoryBytes ?? 0) >= 1_500 * 1_024 * 1_024
  }

  var summary: String {
    let cpu = cpuPercent.map { String(format: "CPU %.0f%%", $0) } ?? "CPU —"
    let memory =
      memoryBytes.map {
        ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory)
      } ?? "Memory —"
    return "\(cpu) · \(memory) · \(network.title)"
  }
}

/// Samples only the PID owned by Operator's PTY. No command output, environment values, or
/// network destinations are inspected; the network field is deliberately host reachability.
final class ProcessResourceSampler {
  private var previousCPUTime: [Int32: UInt64] = [:]
  private var previousSampleDate: [Int32: Date] = [:]

  func sample(pid: Int32?, network: ResourceNetworkState) -> ProcessResourceSnapshot {
    guard let pid, pid > 0 else { return ProcessResourceSnapshot(network: network) }
    var taskInfo = proc_taskinfo()
    let result = proc_pidinfo(
      pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))
    guard result == MemoryLayout<proc_taskinfo>.size else {
      previousCPUTime[pid] = nil
      previousSampleDate[pid] = nil
      return ProcessResourceSnapshot(pid: pid, network: network)
    }

    let now = Date()
    let cpuTime = taskInfo.pti_total_user + taskInfo.pti_total_system
    let cpuPercent: Double?
    if let previousTime = previousCPUTime[pid], let previousDate = previousSampleDate[pid] {
      let elapsed = now.timeIntervalSince(previousDate)
      let delta = cpuTime >= previousTime ? cpuTime - previousTime : 0
      cpuPercent = elapsed > 0 ? min(999, (Double(delta) / 1_000_000_000) / elapsed * 100) : nil
    } else {
      cpuPercent = nil
    }
    previousCPUTime[pid] = cpuTime
    previousSampleDate[pid] = now
    return ProcessResourceSnapshot(
      pid: pid, cpuPercent: cpuPercent, memoryBytes: taskInfo.pti_resident_size, network: network)
  }
}

@MainActor
final class OperatorResourceEnvironment: ObservableObject {
  @Published private(set) var network: ResourceNetworkState = .unknown
  @Published private(set) var powerSource: HostPowerSource = .unknown

  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "local.operator.resource-network")
  private var isStarted = false

  func start() {
    guard !isStarted else { return }
    isStarted = true
    monitor.pathUpdateHandler = { [weak self] path in
      let state: ResourceNetworkState
      if path.status != .satisfied {
        state = .offline
      } else if path.isConstrained || path.isExpensive {
        state = .constrained
      } else {
        state = .online
      }
      Task { @MainActor in self?.network = state }
    }
    monitor.start(queue: queue)
    refreshPowerSource()
  }

  deinit { monitor.cancel() }

  func refreshPowerSource() {
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let output = try? BoundedProcessRunner.run(
        executable: "/usr/bin/pmset", arguments: ["-g", "batt"], timeout: 1, outputLimit: 4096)
      let source = output.map { HostPowerSource.parse(pmsetOutput: $0.standardOutput) } ?? .unknown
      Task { @MainActor in self?.powerSource = source }
    }
  }
}
