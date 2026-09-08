import CMach
import Darwin
import Foundation

/// Память процесса для отчётов о прогонах и диагностики (SPEC.md §4: пик ≤ 12 GB).
public enum ProcessMemory {
  public struct Snapshot: Hashable, Sendable {
    /// Текущий физический след (то, что показывает Activity Monitor как «Память»).
    public var footprintBytes: UInt64
    /// Пиковый резидентный размер с начала процесса.
    public var peakResidentBytes: UInt64
  }

  public static func snapshot() -> Snapshot? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(cmach_task_self(), task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return Snapshot(
      footprintBytes: UInt64(info.phys_footprint),
      peakResidentBytes: UInt64(info.resident_size_peak))
  }

  /// «2.45 GB», «512 MB».
  public static func format(_ bytes: UInt64) -> String {
    let megabytes = Double(bytes) / 1_048_576
    if megabytes >= 1024 {
      return String(format: "%.2f GB", megabytes / 1024)
    }
    return String(format: "%.0f MB", megabytes)
  }
}
