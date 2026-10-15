import AVFoundation
import Foundation

enum LocalAudioImportError: Error, LocalizedError {
    case noAudio
    case noSpeech
    case processingFailed
    var errorDescription: String? {
        switch self {
        case .noSpeech: "录音已保存，但未识别到清晰语音。可先回放检查，再尝试重试转录。"
        case .noAudio: "文件中没有可读取的音频，请选择有效的录音文件。"
        case .processingFailed: "录音已保存，但转录未完成。请检查本地模型后重试转录。"
        }
    }
}

protocol LocalAudioFileImporting: Sendable {
    func convert(_ url: URL, meetingID: UUID, fileStore: MeetingFileStore,
                 onProgress: @Sendable (Double) async -> Void) async throws -> AudioSegmentManifest
}

/// Decode in bounded buffers, downmix, and store in the existing playback format.
/// The selected source is read only; no original file is moved or modified.
actor LocalAudioFileImporter: LocalAudioFileImporting {
    func convert(_ url: URL, meetingID: UUID, fileStore: MeetingFileStore,
                 onProgress: @Sendable (Double) async -> Void) async throws -> AudioSegmentManifest {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { file.close() }
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate.isFinite, format.sampleRate > 0,
              format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw LocalAudioImportError.noAudio
        }
        let converter = PCMConverter(outputSampleRate: PCMConverter.playbackSampleRate, amplitudePolicy: .preserveAmplitude)
        try converter.begin(inputSampleRate: format.sampleRate)
        let writer = try SegmentedPCMWriter(meetingID: meetingID, fileStore: fileStore, sampleRate: PCMConverter.playbackSampleRate)
        var written: Int64 = 0
        var lastPercent = -1
        do {
            while file.framePosition < file.length {
                try Task.checkCancellation()
                try file.read(into: buffer, frameCount: 8192)
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { throw LocalAudioImportError.noAudio }
                let mono = (0..<Int(buffer.frameLength)).map { frame in
                    (0..<Int(format.channelCount)).reduce(Float(0)) { $0 + channels[$1][frame] } / Float(format.channelCount)
                }
                try converter.append(samples: mono)
                written = try await drain(converter, writer: writer, startingAt: written)
                let fraction = Double(file.framePosition) / Double(file.length)
                let percent = Int(fraction * 100)
                if percent != lastPercent { lastPercent = percent; await onProgress(fraction) }
            }
            converter.finishInput()
            written = try await drain(converter, writer: writer, startingAt: written)
            guard written > 0 else { throw LocalAudioImportError.noAudio }
            try Task.checkCancellation()
            return try await writer.finish()
        } catch {
            // Close the open CAF before the use case removes this import's staging directory.
            _ = try? await writer.finish()
            throw error
        }
    }

    private func drain(_ converter: PCMConverter, writer: SegmentedPCMWriter, startingAt: Int64) async throws -> Int64 {
        var written = startingAt
        while true {
            try Task.checkCancellation()
            let pull = try converter.pull(maximumOutputSampleCount: 8192)
            if !pull.samples.isEmpty {
                try await writer.append(CapturedAudioFrame(timestamp: Double(written) / PCMConverter.playbackSampleRate,
                    sampleRate: PCMConverter.playbackSampleRate, samples: pull.samples))
                written += Int64(pull.samples.count)
            }
            if pull.needsInput || pull.isEndOfStream { return written }
        }
    }
}
