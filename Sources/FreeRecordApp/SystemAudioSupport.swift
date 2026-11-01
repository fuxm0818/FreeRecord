import AVFoundation
import CoreAudio
import FreeRecordCore
import Foundation

enum SystemAudioSupportError: LocalizedError {
    case blackHoleNotInstalled
    case noOutputDevice
    case createFailed(OSStatus)
    case switchOutputFailed

    var errorDescription: String? {
        switch self {
        case .blackHoleNotInstalled: return "没有检测到 BlackHole 虚拟声卡"
        case .noOutputDevice: return "没有找到系统输出设备"
        case .createFailed(let status): return "创建多输出设备失败（错误码 \(status)）"
        case .switchOutputFailed: return "无法把系统输出切换到多输出设备"
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

    private static let multiOutputUID = "com.fuxiangming.freerec.multioutput.v3"
    /// 1.0.8 及更早版本没给聚合设备标 stacked，macOS 12 上只有主设备能出声
    private static let legacyMultiOutputUIDs = [
        "com.fuxiangming.freerec.multioutput.v2",
        "com.fuxiangming.freerec.multioutput",
    ]

    /// 创建"扬声器 + BlackHole"多输出聚合设备：既出声又能被录制。
    ///
    /// 关键是显式标 stacked（多输出）。缺这个标记时 macOS 12 只把声音送给主设备：
    /// 1.0.4 之前扬声器当主设备，喇叭有声但 BlackHole 收到静音；1.0.5 之后换成
    /// BlackHole 当主设备，录到了系统声、喇叭却从此没声音。主设备仍应是真实输出
    /// 设备（它同时是时钟源），BlackHole 作为副设备开漂移补偿跟随其时钟。
    static func createMultiOutputAggregate() throws -> AggregateResult {
        guard let blackHole = findBlackHole() else { throw SystemAudioSupportError.blackHoleNotInstalled }
        // 系统输出已经切在我们的聚合设备上（上次录完没切回）：沿用，别再重建
        if let current = defaultOutputDevice(), current.uid == multiOutputUID,
           let existing = deviceID(forUID: multiOutputUID),
           isUsableAggregate(existing, blackHole: blackHole) {
            return AggregateResult(deviceID: existing, alreadyExisted: true)
        }
        guard let output = defaultOutputDevice(), output.uid != multiOutputUID, output.uid != blackHole.uid else {
            throw SystemAudioSupportError.noOutputDevice
        }
        if let existing = deviceID(forUID: multiOutputUID) {
            // 输出设备变了（插耳机、外接屏）或组成不对都要重建，否则声音去了旧设备
            if isUsableAggregate(existing, blackHole: blackHole, output: output) {
                return AggregateResult(deviceID: existing, alreadyExisted: true)
            }
            if defaultOutputDevice()?.deviceID == existing {
                _ = setDefaultOutput(to: output.deviceID)
            }
            AudioHardwareDestroyAggregateDevice(existing)
        }
        for uid in legacyMultiOutputUIDs {
            guard let legacy = deviceID(forUID: uid), defaultOutputDevice()?.deviceID != legacy else { continue }
            AudioHardwareDestroyAggregateDevice(legacy)
        }

        if let reusable = findExistingAggregate(blackHole: blackHole, output: output) {
            return AggregateResult(deviceID: reusable, alreadyExisted: true)
        }

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "自由录屏多输出",
            kAudioAggregateDeviceUIDKey: multiOutputUID,
            kAudioAggregateDeviceIsPrivateKey: false,
            kAudioAggregateDeviceIsStackedKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: output.uid],
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

    /// 录制期间的临时路由：开始前切到多输出设备，收尾时切回用户原来的输出。
    struct Routing {
        let aggregateID: AudioObjectID
        let previous: VirtualDevice?
        var didChange: Bool { previous != nil }
    }

    /// macOS 12 录系统声音的前提：默认输出必须是「扬声器 + BlackHole」的聚合设备。
    /// 只建设备不切输出的话，声音还是从扬声器直出，BlackHole 收到的是静音。
    static func routeSystemAudio() throws -> Routing {
        let result = try createMultiOutputAggregate()
        if let current = defaultOutputDevice(), current.deviceID == result.deviceID {
            return Routing(aggregateID: result.deviceID, previous: nil)
        }
        let previous = defaultOutputDevice()
        guard setDefaultOutput(to: result.deviceID) else {
            throw SystemAudioSupportError.switchOutputFailed
        }
        return Routing(aggregateID: result.deviceID, previous: previous)
    }

    static func restoreOutput(_ routing: Routing) {
        guard let previous = routing.previous else { return }
        // 录制期间用户自己换了输出就别抢回来
        guard let current = defaultOutputDevice(), current.deviceID == routing.aggregateID else { return }
        let target = deviceID(forUID: previous.uid) ?? previous.deviceID
        _ = setDefaultOutput(to: target)
    }

    private static func isUsableAggregate(_ deviceID: AudioObjectID, blackHole: VirtualDevice) -> Bool {
        guard let composition = aggregateComposition(deviceID),
              composition.subDeviceUIDs.contains(blackHole.uid),
              let main = aggregateMainSubDeviceUID(deviceID),
              main != blackHole.uid,
              aggregateIsStacked(deviceID) else {
            return false
        }
        return true
    }

    private static func isUsableAggregate(_ deviceID: AudioObjectID, blackHole: VirtualDevice, output: VirtualDevice) -> Bool {
        guard let composition = aggregateComposition(deviceID),
              composition.subDeviceUIDs.contains(blackHole.uid),
              composition.subDeviceUIDs.contains(output.uid),
              aggregateMainSubDeviceUID(deviceID) == output.uid,
              aggregateIsStacked(deviceID) else {
            return false
        }
        return true
    }

    /// stacked = 多输出：所有子设备收到同一路声音。缺了它 macOS 12 只喂主设备。
    private static func aggregateIsStacked(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFDictionary?
        var size = UInt32(MemoryLayout<CFDictionary?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let dictionary = value as? [String: Any] else { return false }
        return (dictionary[kAudioAggregateDeviceIsStackedKey] as? NSNumber)?.boolValue == true
    }

    private static func aggregateMainSubDeviceUID(_ deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyMainSubDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let string = value as String? else { return nil }
        return string
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

    private static func findExistingAggregate(blackHole: VirtualDevice, output: VirtualDevice) -> AudioObjectID? {
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
               transportType == kAudioDeviceTransportTypeAggregate,
               isUsableAggregate(deviceID, blackHole: blackHole, output: output) {
                return deviceID
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
