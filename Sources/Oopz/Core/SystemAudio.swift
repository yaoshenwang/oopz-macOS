import AppKit
import ScreenCaptureKit

/// Audio callbacks run on a private queue; lifecycle belongs to the main actor.
@MainActor
final class SystemAudioCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "oopz.sysaudio")
    private let samples = Samples()
    private var generation = UUID()
    var onSampleBuffer: ((CMSampleBuffer) -> Void)? {
        get { samples.lock.withLock { samples.callback } }
        set { samples.lock.withLock { samples.callback = newValue } }
    }
    var running: Bool { samples.lock.withLock { samples.running } }

    private final class Samples: @unchecked Sendable {
        let lock = NSLock()
        var callback: ((CMSampleBuffer) -> Void)?
        var running = false
        func deliver(_ sample: CMSampleBuffer) {
            // Holding the lock also drains any in-flight push before its Agora track is destroyed.
            lock.withLock { if running { callback?(sample) } }
        }
    }

    func start(displayID: CGDirectDisplayID) async throws {
        let callback = onSampleBuffer
        await stopAndWait()
        onSampleBuffer = callback
        let id = UUID(); generation = id
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard id == generation else { throw CancellationError() }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "oopz.sysaudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到对应显示器"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000; cfg.channelCount = 2
        let source = SCStream(filter: filter, configuration: cfg, delegate: self)
        try source.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        stream = source
        try await source.startCapture()
        guard id == generation else { try? await source.stopCapture(); throw CancellationError() }
        samples.lock.withLock { samples.running = true }
    }

    func stopAndWait() async {
        generation = UUID()
        let previous = stream; stream = nil
        samples.lock.withLock { samples.running = false; samples.callback = nil }
        if let previous { try? await previous.stopCapture() }
    }
    func stop() {
        generation = UUID()
        samples.lock.withLock { samples.running = false; samples.callback = nil }
        let previous = stream; stream = nil
        previous?.stopCapture { _ in }
    }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        samples.deliver(sampleBuffer)
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            self.samples.lock.withLock { self.samples.running = false }
        }
    }
}
