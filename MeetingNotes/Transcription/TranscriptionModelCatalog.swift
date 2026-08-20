enum TranscriptionQualityMode:
    String,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable {
    case balanced
    case highAccuracy

    var displayName: String {
        switch self {
        case .balanced: "平衡"
        case .highAccuracy: "高精度"
        }
    }
}

struct TranscriptionModelDescriptor: Equatable, Sendable {
    let mode: TranscriptionQualityMode
    let modelID: String
    let downloadSelector: String
    let directoryName: String
    let detail: String

    init(
        mode: TranscriptionQualityMode,
        modelID: String,
        downloadSelector: String? = nil,
        directoryName: String,
        detail: String
    ) {
        self.mode = mode
        self.modelID = modelID
        self.downloadSelector = downloadSelector ?? modelID
        self.directoryName = directoryName
        self.detail = detail
    }
}

enum TranscriptionModelCatalog {
    static func descriptor(
        for mode: TranscriptionQualityMode
    ) -> TranscriptionModelDescriptor {
        switch mode {
        case .balanced:
            TranscriptionModelDescriptor(
                mode: mode,
                modelID: "openai_whisper-large-v3_turbo_v3_1747_1_10_256Page",
                downloadSelector: "openai_whisper-large-v3-v20240930_turbo",
                directoryName: "balanced",
                detail: "默认，速度和资源占用更均衡"
            )
        case .highAccuracy:
            TranscriptionModelDescriptor(
                mode: mode,
                modelID: "openai_whisper-large-v3",
                downloadSelector: "openai_whisper-large-v3",
                directoryName: "high-accuracy",
                detail: "更高多语言精度，下载和处理时间更长"
            )
        }
    }
}
