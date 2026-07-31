import Darwin
import Testing

@testable import Operator

struct ResourceMonitoringTests {
  @Test func powerSourceParserRecognizesBatteryAndAdapterStates() {
    #expect(HostPowerSource.parse(pmsetOutput: "Now drawing from 'Battery Power'") == .battery)
    #expect(HostPowerSource.parse(pmsetOutput: "Now drawing from 'AC Power'") == .ac)
    #expect(HostPowerSource.parse(pmsetOutput: "unavailable") == .unknown)
  }

  @Test func resourceSnapshotFormatsUnavailableAndRunawayProcessesClearly() {
    #expect(ProcessResourceSnapshot.unavailable.summary.contains("CPU —"))
    #expect(!ProcessResourceSnapshot.unavailable.isRunaway)
    let runaway = ProcessResourceSnapshot(
      pid: getpid(), cpuPercent: 91, memoryBytes: 4, network: .online)
    #expect(runaway.isRunaway)
    #expect(runaway.summary.contains("Network online"))
  }

  @Test func processSamplerHandlesCurrentAndUnavailablePIDsWithoutCrashing() {
    let sampler = ProcessResourceSampler()
    let current = sampler.sample(pid: getpid(), network: .online)
    #expect(current.pid == getpid())
    #expect(current.memoryBytes != nil)
    let unavailable = sampler.sample(pid: nil, network: .offline)
    #expect(unavailable.pid == nil)
    #expect(unavailable.network == .offline)
  }
}
