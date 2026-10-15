import Foundation

public struct VolumeStepper {
    private var latest: VolumeInfo?
    private var target: Int?
    private var waitingFrom: Int?

    public init() {}

    public mutating func receive(_ info: VolumeInfo) -> KeyCode? {
        guard info.max > 0, info.max <= 1000, info.level >= 0, info.level <= info.max else { return nil }
        if latest?.max != info.max { target = nil; waitingFrom = nil }
        latest = info
        if let waitingFrom, info.level != waitingFrom { self.waitingFrom = nil }
        return next()
    }

    public mutating func setTarget(_ fraction: Double) -> KeyCode? {
        guard fraction.isFinite, let latest else { return nil }
        target = Int((min(1, max(0, fraction)) * Double(latest.max)).rounded())
        return next()
    }

    public mutating func cancel() {
        target = nil
        waitingFrom = nil
    }

    private mutating func next() -> KeyCode? {
        guard waitingFrom == nil, let target, let latest, target != latest.level else { return nil }
        waitingFrom = latest.level
        return target > latest.level ? .volumeUp : .volumeDown
    }
}
