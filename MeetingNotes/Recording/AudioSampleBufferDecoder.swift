import AVFoundation
import CoreMedia
import Foundation

enum AudioSampleBufferDecoderError: Error, Equatable, Sendable {
    case invalidSample
    case unableToAllocateOwnedBuffer
}

struct DecodedAudioSampleBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let sampleTime: AVAudioFramePosition
    let sampleRate: Double
    let timestamp: TimeInterval
}

protocol AudioSampleBufferDecoding: Sendable {
    func decode(
        _ sampleBuffer: CMSampleBuffer
    ) throws -> DecodedAudioSampleBuffer
}

final class AudioSampleBufferDecoder:
    AudioSampleBufferDecoding,
    @unchecked Sendable {
    func decode(
        _ sampleBuffer: CMSampleBuffer
    ) throws -> DecodedAudioSampleBuffer {
        guard sampleBuffer.isValid,
              let streamDescription = sampleBuffer.formatDescription?
                .audioStreamBasicDescription,
              streamDescription.mSampleRate.isFinite,
              streamDescription.mSampleRate > 0,
              streamDescription.mChannelsPerFrame > 0 else {
            throw AudioSampleBufferDecoderError.invalidSample
        }
        let presentationTime =
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestamp = CMTimeGetSeconds(presentationTime)
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard timestamp.isFinite,
              sampleCount > 0,
              let frameCount = AVAudioFrameCount(exactly: sampleCount) else {
            throw AudioSampleBufferDecoderError.invalidSample
        }

        var description = streamDescription
        guard let format = AVAudioFormat(
            streamDescription: &description
        ) else {
            throw AudioSampleBufferDecoderError.invalidSample
        }

        let ownedBuffer = try sampleBuffer.withAudioBufferList {
            audioBufferList,
            _ -> AVAudioPCMBuffer in
            guard let owned = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
            ) else {
                throw AudioSampleBufferDecoderError
                    .unableToAllocateOwnedBuffer
            }
            owned.frameLength = frameCount

            let sourcePointer = UnsafeMutablePointer<AudioBufferList>(
                mutating: audioBufferList.unsafePointer
            )
            let sourceBuffers = UnsafeMutableAudioBufferListPointer(
                sourcePointer
            )
            let destinationBuffers = UnsafeMutableAudioBufferListPointer(
                owned.mutableAudioBufferList
            )
            guard sourceBuffers.count == destinationBuffers.count else {
                throw AudioSampleBufferDecoderError.invalidSample
            }
            for index in sourceBuffers.indices {
                let source = sourceBuffers[index]
                let destination = destinationBuffers[index]
                guard source.mDataByteSize <= destination.mDataByteSize,
                      let sourceData = source.mData,
                      let destinationData = destination.mData else {
                    throw AudioSampleBufferDecoderError.invalidSample
                }
                memcpy(
                    destinationData,
                    sourceData,
                    Int(source.mDataByteSize)
                )
                destinationBuffers[index].mDataByteSize =
                    source.mDataByteSize
            }
            return owned
        }

        return DecodedAudioSampleBuffer(
            buffer: ownedBuffer,
            sampleTime: AVAudioFramePosition(
                (timestamp * streamDescription.mSampleRate).rounded()
            ),
            sampleRate: streamDescription.mSampleRate,
            timestamp: timestamp
        )
    }
}
