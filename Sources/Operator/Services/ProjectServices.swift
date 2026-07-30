import Darwin
import Foundation

struct BoundedProcessResult: Equatable {
  let exitCode: Int32?
  let standardOutput: String
  let standardError: String
  let timedOut: Bool
  let outputWasTruncated: Bool
}

enum BoundedProcessRunner {
  static func run(
    executable: String, arguments: [String], directory: String? = nil,
    environment: [String: String] = [:], timeout: TimeInterval = 15,
    outputLimit: Int = 1_048_576
  ) throws -> BoundedProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
    process.environment = ProcessInfo.processInfo.environment.merging(
      environment, uniquingKeysWith: { _, override in override })

    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    let accumulator = ProcessOutputAccumulator(limit: max(1, outputLimit))
    output.fileHandleForReading.readabilityHandler = { handle in
      accumulator.append(handle.availableData, isError: false)
    }
    errors.fileHandleForReading.readabilityHandler = { handle in
      accumulator.append(handle.availableData, isError: true)
    }
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }

    do {
      try process.run()
    } catch {
      output.fileHandleForReading.readabilityHandler = nil
      errors.fileHandleForReading.readabilityHandler = nil
      throw error
    }

    let timedOut = finished.wait(timeout: .now() + max(0.1, timeout)) == .timedOut
    if timedOut {
      process.terminate()
      if finished.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        _ = finished.wait(timeout: .now() + 0.5)
      }
    }
    output.fileHandleForReading.readabilityHandler = nil
    errors.fileHandleForReading.readabilityHandler = nil
    if !process.isRunning {
      if let finalOutput = try? output.fileHandleForReading.readToEnd() {
        accumulator.append(finalOutput, isError: false)
      }
      if let finalErrors = try? errors.fileHandleForReading.readToEnd() {
        accumulator.append(finalErrors, isError: true)
      }
    }
    try? output.fileHandleForReading.close()
    try? errors.fileHandleForReading.close()
    let captured = accumulator.snapshot()
    return BoundedProcessResult(
      exitCode: process.isRunning ? nil : process.terminationStatus,
      standardOutput: String(decoding: captured.output, as: UTF8.self),
      standardError: String(decoding: captured.errors, as: UTF8.self), timedOut: timedOut,
      outputWasTruncated: captured.truncated)
  }
}

private final class ProcessOutputAccumulator: @unchecked Sendable {
  private let lock = NSLock()
  private let limit: Int
  private var output = Data()
  private var errors = Data()
  private var truncated = false

  init(limit: Int) { self.limit = limit }

  func append(_ data: Data, isError: Bool) {
    guard !data.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    let remaining = max(0, limit - output.count - errors.count)
    if data.count > remaining { truncated = true }
    guard remaining > 0 else { return }
    if isError {
      errors.append(data.prefix(remaining))
    } else {
      output.append(data.prefix(remaining))
    }
  }

  func snapshot() -> (output: Data, errors: Data, truncated: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (output, errors, truncated)
  }
}
