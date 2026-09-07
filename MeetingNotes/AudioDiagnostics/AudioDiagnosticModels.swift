import Foundation

enum AudioDiagnosticPermissionStatus:
    String,
    Codable,
    Sendable,
    Equatable
{
    case authorized
    case denied
    case notDetermined
    case unavailable

    var isAuthorized: Bool {
        self == .authorized
    }
}

enum AudioDiagnosticStage:
    String,
    Codable,
    Sendable,
    Equatable
{
    case microphone
    case systemAudio
}

enum AudioDiagnosticStageOutcome:
    String,
    Codable,
    Sendable,
    Equatable
{
    case notRun
    case skipped
    case succeeded
    case timedOut
    case failed
}

enum AudioDiagnosticIssueCode:
    String,
    Codable,
    CaseIterable,
    Sendable,
    Equatable
{
    case microphonePermissionDenied
    case screenPermissionDenied
    case inputDeviceUnavailable
    case outputNotAudible
    case microphoneNoFrames
    case microphoneSilent
    case systemAudioNoFrames
    case captureHealthy
    case playbackPipelineSuspected
    case microphoneDiagnosticTimedOut
    case systemAudioDiagnosticTimedOut
    case microphoneDiagnosticFailed
    case systemAudioDiagnosticFailed

    var localIssue: String {
        switch self {
        case .microphonePermissionDenied:
            return "MeetingNotes 没有可用的麦克风权限"
        case .screenPermissionDenied:
            return "MeetingNotes 没有可用的屏幕录制权限"
        case .inputDeviceUnavailable:
            return "所选输入设备当前不可用"
        case .outputNotAudible:
            return "测试音已发送，但没有听到声音"
        case .microphoneNoFrames:
            return "麦克风没有产生音频帧"
        case .microphoneSilent:
            return "麦克风信号持续静音或音量过低"
        case .systemAudioNoFrames:
            return "未检测到有效的系统声音"
        case .captureHealthy:
            return "当前音频采集正常"
        case .playbackPipelineSuspected:
            return "历史无声问题可能出在保存或回放环节"
        case .microphoneDiagnosticTimedOut:
            return "麦克风智能检测超时"
        case .systemAudioDiagnosticTimedOut:
            return "系统音频智能检测超时"
        case .microphoneDiagnosticFailed:
            return "麦克风智能检测失败"
        case .systemAudioDiagnosticFailed:
            return "系统音频智能检测失败"
        }
    }

    var localSolution: String {
        switch self {
        case .microphonePermissionDenied:
            return "请在系统设置的隐私与安全性中允许 MeetingNotes 使用麦克风，然后重新测试。"
        case .screenPermissionDenied:
            return "请在系统设置的隐私与安全性中允许 MeetingNotes 录制屏幕与系统音频，然后重新测试。"
        case .inputDeviceUnavailable:
            return "请重新连接该输入设备，或在 MeetingNotes 设置中选择其他麦克风。"
        case .outputNotAudible:
            return "请检查 MeetingNotes 的输出设备选择、设备音量与物理连接后再次播放测试音。"
        case .microphoneNoFrames:
            return "请重新选择麦克风并关闭可能独占设备的应用，然后再次测试。"
        case .microphoneSilent:
            return "请确认麦克风未静音、输入音量足够，并尝试靠近麦克风说话。"
        case .systemAudioNoFrames:
            return "Core Audio 纯音频检测未收到有效的系统声音。请确认测试音正在播放、输出设备正常，并检查系统音频录制授权；无需共享桌面。"
        case .captureHealthy:
            return "无需修改音频设备；如果会议仍无声，请检查具体录音文件的保存与回放。"
        case .playbackPipelineSuspected:
            return "请用其他播放器检查原始录音文件，并重新打开 MeetingNotes 后再次回放。"
        case .microphoneDiagnosticTimedOut:
            return "麦克风手动测试正常时，可先重新运行智能诊断；若持续超时，可将诊断数据发送给 DeepSeek 分析检测阶段。"
        case .systemAudioDiagnosticTimedOut:
            return "Core Audio 纯音频检测未在时限内完成，不代表设备已断开或缺少屏幕权限。可重试诊断，或在确认预览后发送给 DeepSeek 分析。"
        case .microphoneDiagnosticFailed:
            return "可先重新运行智能诊断；若持续失败，可将诊断数据发送给 DeepSeek 分析麦克风检测阶段。"
        case .systemAudioDiagnosticFailed:
            return "Core Audio 纯音频检测失败，不等同于屏幕权限不足。可重试诊断；若持续失败，可在确认预览后发送给 DeepSeek 分析系统音频阶段。"
        }
    }
}

struct AudioDiagnosticFacts: Sendable, Equatable {
    let microphonePermission: AudioDiagnosticPermissionStatus
    let screenPermission: AudioDiagnosticPermissionStatus?
    let inputDeviceAvailable: Bool
    let outputToneWasScheduled: Bool
    let userHeardOutputTone: Bool?
    let microphoneMetrics: AudioSignalMetrics?
    let systemAudioMetrics: AudioSignalMetrics?
    let historicalPlaybackFailed: Bool
    let microphoneTestOutcome: AudioDiagnosticStageOutcome
    let systemAudioTestOutcome: AudioDiagnosticStageOutcome
}

struct AudioDiagnosticReport: Sendable, Equatable {
    let primaryIssue: AudioDiagnosticIssueCode
    let supportingIssues: [AudioDiagnosticIssueCode]
    let facts: AudioDiagnosticFacts

    var localIssue: String {
        primaryIssue.localIssue
    }

    var localSolution: String {
        primaryIssue.localSolution
    }
}
