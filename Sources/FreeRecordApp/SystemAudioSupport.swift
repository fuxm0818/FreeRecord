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

    private static let multiOutputUID = "com.fuxiangming.freerec.multioutput.v2"
    /// 1.0.4 及更早版本用扬声器当主设备，macOS 12 上黑声卡收不到声音
    private static let legacyMultiOutputUID = "com.fuxiangming.freerec.multioutput"

    /// 创建"扬声器 + BlackHole"多输出聚合设备：既出声又能被录制。
    ///
    /// 必须让 BlackHole 当主设备（时钟源）：在 macOS 12 上反向配置时扬声器有声音，
    /// 但 BlackHole 子设备一直收到静音。扬声器作为副设备并开启漂移补偿跟随其时钟。
    static func createMultiOutputAggregate() throws -> AggregateResult {
        guard let blackHole = findBlackHole() else { throw SystemAudioSupportError.blackHoleNotInstalled }
        if let existing = deviceID(forUID: multiOutputUID) {
            return AggregateResult(deviceID: existing, alreadyExisted: true)
        }
        if let legacy = deviceID(forUID: legacyMultiOutputUID) {
            AudioHardwareDestroyAggregateDevice(legacy)
        }
        guard let output = defaultOutputDevice(), output.uid != multiOutputUID else {
            throw SystemAudioSupportError.noOutputDevice
        }

        let existing = findExistingAggregate(composedOf: [blackHole.uid, output.uid])
        if let existing { return AggregateResult(deviceID: existing, alreadyExisted: true) }

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "自由录屏多输出",
            kAudioAggregateDeviceUIDKey: multiOutputUID,
            kAudioAggregateDeviceIsPrivateKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: blackHole.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: blackHole.uid],
                [kAudioSubDeviceUIDKey: output.uid, kAudioSubDeviceDriftCompensationKey: 1],
            ],
        ]
        var aggregateID = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID)
        guard status == noErr else {
            throw SystemAudioSupportError.createFailed(status)
        }
        return AggregateResult(deviceID: aggregateID, alreadyExisted: false)
    }

    private static func deviceID(forUID target: String) -> AudioObjectID? {
        for deviceID in allDeviceIDs() where deviceUID(deviceID) == target {
            return deviceID
        }
        return nil
    }

    private static func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        var deviceIDs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs) == noErr else {
            return []
        }
        return deviceIDs
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
        // 系统返回的是 CFString UID 数组；创建时用的字典数组只出现在写入路径
        guard status == noErr, let array = list as? [Any] else { return nil }
        let uids: [String] = array.compactMap { item in
            if let uid = item as? String { return uid }
            if let dict = item as? [String: Any] { return dict[kAudioSubDeviceUIDKey] as? String }
            return nil
        }
        guard !uids.isEmpty else { return nil }
        return AggregateComposition(subDeviceUIDs: uids)
    }
}
