import AppKit
import Carbon.HIToolbox

@MainActor
final class HotKeyController: NSObject {
    var onToggleRecord: (() -> Void)?
    var onTogglePause: (() -> Void)?

    private var recordHotKeyRef: EventHotKeyRef?
    private var pauseHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var installed = false

    override init() {
        super.init()
        Self.sharedRef = self
    }

    private enum HotKeyID: UInt32 {
        case toggleRecord = 1
        case togglePause = 2
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            install()
        } else {
            uninstall()
        }
    }

    private func install() {
        guard !installed else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                guard GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                ) == noErr else { return noErr }
                let id = hotKeyID.id
                Task { @MainActor in
                    HotKeyController.sharedRef?.dispatch(id: id)
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
        guard status == noErr else { return }

        var recordRef: EventHotKeyRef?
        var pauseRef: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(cmdKey | optionKey), EventHotKeyID(signature: OSType(0x46524543), id: HotKeyID.toggleRecord.rawValue), GetApplicationEventTarget(), 0, &recordRef)
        RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(cmdKey | optionKey), EventHotKeyID(signature: OSType(0x46524543), id: HotKeyID.togglePause.rawValue), GetApplicationEventTarget(), 0, &pauseRef)
        recordHotKeyRef = recordRef
        pauseHotKeyRef = pauseRef
        installed = true
    }

    private func uninstall() {
        guard installed else { return }
        if let ref = recordHotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = pauseHotKeyRef { UnregisterEventHotKey(ref) }
        recordHotKeyRef = nil
        pauseHotKeyRef = nil
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
        eventHandler = nil
        installed = false
    }

    private func dispatch(id: UInt32) {
        switch id {
        case HotKeyID.toggleRecord.rawValue: onToggleRecord?()
        case HotKeyID.togglePause.rawValue: onTogglePause?()
        default: break
        }
    }

    static weak var sharedRef: HotKeyController?
}
