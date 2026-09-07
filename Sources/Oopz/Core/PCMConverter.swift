import Foundation
import CoreMedia
import AudioToolbox
import AVFoundation

/// ScreenCaptureKit 默认吐 float32 PCM；Agora pushExternalAudioFrameRawData 要 16-bit 交错立体声 48kHz。
enum PCMConverter {
    struct Frame {
        let data: Data
        let samplesPerChannel: UInt
    }

    /// Convert supported PCM layouts; unsupported formats fail closed, never relabel raw bytes.
    static func int16Stereo48k(from sampleBuffer: CMSampleBuffer) -> Frame? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let ptr = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return nil }
        let a = ptr.pointee
        let float = a.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let planar = a.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard a.mFormatID == kAudioFormatLinearPCM, a.mSampleRate > 0,
              a.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              (float && a.mBitsPerChannel == 32) || (!float && a.mBitsPerChannel == 16 && a.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0),
              a.mChannelsPerFrame == 1 || a.mChannelsPerFrame == 2 else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, frames < 480_000 else { return nil }
        let channels = Int(a.mChannelsPerFrame)
        var required = 0
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,
            bufferListSizeNeededOut: &required, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard required >= MemoryLayout<AudioBufferList>.size else { return nil }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: required, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        let rc = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,
            bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: required,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard rc == noErr, buffers.count == (planar ? channels : 1) else { return nil }
        let bytesPerSample = Int(a.mBitsPerChannel / 8)
        for buffer in buffers {
            guard buffer.mData != nil, Int(buffer.mDataByteSize) >= frames * bytesPerSample * (planar ? 1 : channels) else { return nil }
        }
        func value(_ frame: Int, _ channel: Int) -> Float {
            let c = min(channel, channels - 1)
            let p = buffers[planar ? c : 0].mData!
            let offset = (planar ? frame : frame * channels + c) * bytesPerSample
            let v = float ? p.loadUnaligned(fromByteOffset: offset, as: Float.self)
                : Float(p.loadUnaligned(fromByteOffset: offset, as: Int16.self)) / 32768
            return v.isFinite ? max(-1, min(1, v)) : 0
        }
        let count = max(1, Int(Double(frames) * 48000 / a.mSampleRate))
        var data = Data(count: count * 4)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let position = min(Double(frames - 1), Double(i) * a.mSampleRate / 48000)
                let lo = Int(position), hi = min(frames - 1, lo + 1)
                for c in 0..<2 {
                    let v = value(lo, c) + (value(hi, c) - value(lo, c)) * Float(position - Double(lo))
                    out[i * 2 + c] = Int16(max(-32768, min(32767, v * 32768)))
                }
            }
        }
        return Frame(data: data, samplesPerChannel: UInt(count))
    }

    /// Known values in interleaved, planar and mono buffers, with CoreMedia-owned storage.
    static func selfTest() -> Bool {
        func test(_ bytes: Data, channels: UInt32, flags: UInt32, bits: UInt32,
                  frames: Int, expected: [Int16]) -> Bool {
            let planar = flags & kAudioFormatFlagIsNonInterleaved != 0
            let frameBytes = bits / 8 * (planar ? 1 : channels)
            var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: flags, mBytesPerPacket: frameBytes, mFramesPerPacket: 1,
                mBytesPerFrame: frameBytes, mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0)
            var format: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
            guard let format else { return false }
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block)
            guard let block else { return false }
            let copied = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!,
                blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
            guard copied == noErr else { return false }
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
                presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleCount: frames,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
            guard let sample, let result = int16Stereo48k(from: sample) else { return false }
            return result.samplesPerChannel == UInt(frames) && result.data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) } == expected
        }
        let interleaved: [Float] = [0.5, -0.5, 1, -1]
        let planar: [Float] = [0.5, 1, -0.5, -1]
        let mono: [Int16] = [16384, -16384]
        let expected: [Int16] = [16384, -16384, 32767, -32768]
        return test(interleaved.withUnsafeBytes { Data($0) }, channels: 2,
            flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, bits: 32, frames: 2, expected: expected)
            && test(planar.withUnsafeBytes { Data($0) }, channels: 2,
                flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                bits: 32, frames: 2, expected: expected)
            && test(mono.withUnsafeBytes { Data($0) }, channels: 1,
                flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                bits: 16, frames: 2, expected: [16384, 16384, -16384, -16384])
    }
}
