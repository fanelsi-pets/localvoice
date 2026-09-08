import Core
import Export
import Store
import SwiftUI

/// Кнопка и прогресс распознавания подписей на видео (SPEC.md §3.4 п. d, DESIGN.md §4):
/// определённая полоса по времени видео, пульс, отмена; итог — подписью под кнопкой.
struct NameScanSection: View {
  @Bindable var model: AppModel
  let record: MeetingRecord
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let scan = model.nameScan
    VStack(alignment: .leading, spacing: 6) {
      if scan.isScanning(record.id) {
        ProgressView(value: scan.fraction) {
          Text(
            "Распознавание подписей на видео · \(Int(scan.fraction * 100)) %"
              + (scan.remainingText.map { " · \($0)" } ?? "")
          )
          .font(.callout)
        }
        .progressViewStyle(.linear)
        .animation(reduceMotion ? nil : .default, value: scan.fraction)
        .accessibilityIdentifier("nameScan.progress")
        .accessibilityValue("\(Int(scan.fraction * 100)) %")
        HStack {
          Text((scan.timecode.map { "\(Timecode.hhmmss($0)) · " } ?? "") + scan.pulse)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Spacer()
          Button("Отменить", systemImage: "xmark.circle") { scan.cancel() }
            .controlSize(.small)
            .accessibilityIdentifier("nameScan.cancel")
        }
        if let health = scan.healthText {
          Text(health).font(.caption).foregroundStyle(.orange)
        }
      } else if let videoURL = record.videoURL {
        HStack {
          Button("Найти имена на видео", systemImage: "text.viewfinder") {
            model.scanVideoForNames(meetingID: record.id)
          }
          .disabled(scan.isScanning)
          .help(
            "Кадры видео 1 раз в секунду, подписи участников через Vision — только на этом Mac. Файл: \(videoURL.lastPathComponent)"
          )
          .accessibilityIdentifier("nameScan.start")
          Spacer()
        }
        if let summary = scan.summary, model.nameScanSummaryMeetingID == record.id {
          Text(summary).font(.caption).foregroundStyle(.secondary)
        }
        if let error = scan.errorText, model.nameScanSummaryMeetingID == record.id {
          Text(error).font(.caption).foregroundStyle(.red)
        }
      }
    }
  }
}
