import AVFoundation
import CoreAudio
import FreeRecordCore
import Foundation

enum SystemAudioSupportError: LocalizedError {
    case blackHoleNotInstalled
    case noOutputDevice
    case createFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .blackHoleNotInstalled: return "没有检测到 BlackHole 虚拟声卡"
        case .noOutputDevice: return "没有找到系统输出设备"
        case .createFailed(let status): return "创建多输出设备失败（错误码 \(status)）"
        }
    }
}

enum SystemAudioSupport {
    struct VirtualDevice {
        let deviceID: AudioObjectID
        let name: String
        let uid: String
    }

    static func findBlackHole() -> VirtualDevice? {
        let candidates = allInputDevices()
        return candidates.first { $0.name.hasPrefix("BlackHole") }
    }

    static func allInputDevices() -> [VirtualDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs) == noErr else {
            return []
        }
        var result: [VirtualDevice] = []
        for deviceID in deviceIDs {
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { continue }
            guard let name = deviceName(deviceID), let uid = deviceUID(deviceID) else { continue }
            result.append(VirtualDevice(deviceID: deviceID, name: name, uid: uid))
        }
        return result
    }

    private static func deviceName(_ deviceID: AudioObjectID) -> String? {
        stringProperty(deviceID, selector: kAudioObjectPropertyName)
    }

    private static func deviceUID(_ deviceID: AudioObjectID) -> String? {
        stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func stringProperty(_ deviceID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value = name as String? else { return nil }
        return value
    }

    static func defaultOutputDevice() -> VirtualDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0,
              let name = deviceName(deviceID),
              let uid = deviceUID(deviceID) else { return nil }
        return VirtualDevice(deviceID: deviceID, name: name, uid: uid)
    }

    struct AggregateResult {
        let deviceID: AudioObjectID
        let alreadyExisted: Bool
    }

    /// 创建"扬声器 + BlackHole"多输出聚合设备：既出声又能被录制。
    static func createMultiOutputAggregate() throws -> AggregateResult {
        guard let blackHole = findBlackHole() else { throw SystemAudioSupportError.blackHoleNotInstalled }
        guard let output = defaultOutputDevice() else { throw SystemAudioSupportError.noOutputDevice }

        let existing = findExistingAggregate(composedOf: [output.uid, blackHole.uid])
        if let existing { return AggregateResult(deviceID: existing, alreadyExisted: true) }

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "自由录屏多输出",
            kAudioAggregateDeviceUIDKey: "com.fuxiangming.freerec.multioutput",
            kAudioAggregateDeviceIsPrivateKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: output.uid, kAudioSubDeviceDriftCompensationKey: 0],
                [kAudioSubDeviceUIDKey: blackHole.uid, kAudioSubDeviceDriftCompensationKey: 1],
            ],
        ]
        var aggregateID = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID)
        guard status == noErr else {
            throw SystemAudioSupportError.createFailed(status)
        }
        return AggregateResult(deviceID: aggregateID, alreadyExisted: false)
    }

    static func setDefaultOutput(to deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id)
        return status == noErr
    }

    private static func findExistingAggregate(composedOf uids: [String]) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs) == noErr else { return nil }

        for deviceID in deviceIDs {
            var transportType: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &transportSize, &transportType) == noErr,
               transportType == kAudioDeviceTransportTypeAggregate {
                if let composition = aggregateComposition(deviceID) {
                    let memberUIDs = composition.subDeviceUIDs
                    if uids.allSatisfy({ memberUIDs.contains($0) }) {
                        return deviceID
                    }
                }
            }
        }
        return nil
    }

    private struct AggregateComposition {
        var subDeviceUIDs: [String]
    }

    private static func aggregateComposition(_ deviceID: AudioObjectID) -> AggregateComposition? {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var list: CFArray?
        var size = UInt32(MemoryLayout<CFArray?>.size)
        let status = withUnsafeMutablePointer(to: &list) { pointer in
            AudioObjectGetPropertyData(deviceID, &listAddress, 0, nil, &size, pointer)
        }
        guard status == noErr, let array = list as? [[String: Any]] else { return nil }
        let uids = array.compactMap { $0[kAudioSubDeviceUIDKey] as? String }
        return AggregateComposition(subDeviceUIDs: uids)
    }
}
