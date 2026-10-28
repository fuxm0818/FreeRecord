import Foundation

public final class CaptureCounters {
    public struct Snapshot: Codable {
        public let captured: Int
        public let written: Int
        public let droppedBusy: Int
        public let droppedInvalid: Int
        public let audioBuffers: Int

        public var droppedTotal: Int { droppedBusy + droppedInvalid }
    }

    private let lock = NSLock()
    private var captured = 0
    private var written = 0
    private var droppedBusy = 0
    private var droppedInvalid = 0
    private var audio = 0

    public init() {}

    public func frameCaptured() {
        lock.lock(); defer { lock.unlock() }
        captured += 1
    }

    public func frameWritten() {
        lock.lock(); defer { lock.unlock() }
        written += 1
    }

    public func frameDroppedBusy() {
        lock.lock(); defer { lock.unlock() }
        droppedBusy += 1
    }

    public func frameDroppedInvalid() {
        lock.lock(); defer { lock.unlock() }
        droppedInvalid += 1
    }

    public func audioBuffer() {
        lock.lock(); defer { lock.unlock() }
        audio += 1
    }

    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(captured: captured, written: written, droppedBusy: droppedBusy, droppedInvalid: droppedInvalid, audioBuffers: audio)
    }
}
