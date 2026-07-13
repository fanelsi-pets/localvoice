import AppKit
import SwiftUI

struct ModelCardView: View {
    let model: any TranscriptionModel
    let fluidAudioModelManager: FluidAudioModelManager
    let isDownloaded: Bool
    let downloadProgress: [String: Double]
    let modelURL: URL?
    let isWarming: Bool
    var isSelected = false

    // Actions
    var deleteAction: () -> Void
    var downloadAction: () -> Void
    var selectAction: (() -> Void)?
    var editAction: ((CustomCloudModel) -> Void)?
    var body: some View {
        Group {
            switch model.provider {
            case .whisper:
                if let whisperModel = model as? WhisperModel {
                    WhisperModelCardView(
                        model: whisperModel,
                        isDownloaded: isDownloaded,
                        downloadProgress: downloadProgress,
                        modelURL: modelURL,
                        isWarming: isWarming,
                        isSelected: isSelected,
                        deleteAction: deleteAction,
                        downloadAction: downloadAction,
                        selectAction: selectAction
                    )
                } else if let importedModel = model as? ImportedWhisperModel {
                    ImportedWhisperModelCardView(
                        model: importedModel,
                        isDownloaded: isDownloaded,
                        modelURL: modelURL,
                        deleteAction: deleteAction
                    )
                }
            case .fluidAudio:
                if let fluidAudioModel = model as? FluidAudioModel {
                    FluidAudioModelCardView(
                        model: fluidAudioModel,
                        fluidAudioModelManager: fluidAudioModelManager,
                        isSelected: isSelected,
                        selectAction: selectAction
                    )
                }
            case .nativeApple:
                if let nativeAppleModel = model as? NativeAppleModel {
                    NativeAppleModelCardView(
                        model: nativeAppleModel
                    )
                }
            case .custom:
                if let customModel = model as? CustomCloudModel {
                    CustomModelCardView(
                        model: customModel,
                        deleteAction: deleteAction,
                        editAction: editAction ?? { _ in }
                    )
                }
            default:
                if let cloudModel = model as? CloudModel {
                    CloudModelCardView(
                        model: cloudModel
                    )
                }
            }
        }
    }
}
