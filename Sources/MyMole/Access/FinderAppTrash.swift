import AppKit
import ApplicationServices

/// Finder performs one confirmed app move, including its own authorization UI.
/// No script, shell command or root helper is sent to another process.
struct FinderAppTrash {
    struct Request: Sendable {
        let source: URL
        let stillCurrent: @Sendable () -> Bool
    }

    struct RestoreRequest: Sendable {
        let source: URL
        let destination: URL
        var reference: Data? = nil
        let stillCurrent: @Sendable (URL) -> Bool
    }

    struct RestoreReply: Sendable {
        let status: Int32
        let location: URL?
        var reference: Data? = nil
    }

    var authorize: @MainActor () async -> Int32
    var move: @MainActor (Request) async -> Int32
    var restore: (@MainActor (RestoreRequest) async -> RestoreReply)? = nil

    static let changed: Int32 = 2400
    static let unverified: Int32 = 2401
    static let automationDenied: Int32 = -1743
    static let consentRequired: Int32 = -1744
    static let cancelled: Int32 = -128

    @MainActor static var live: Self {
        Self(authorize: { await Task.detached(priority: .userInitiated) { permission() }.value },
             move: { request in await Task.detached(priority: .userInitiated) { send(request) }.value },
             restore: { request in await Task.detached(priority: .userInitiated) { putBack(request) }.value })
    }

    nonisolated static func permission() -> Int32 {
        let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        return AEDeterminePermissionToAutomateTarget(finder.aeDesc, AEEventClass(kAECoreSuite), AEEventID(kAEDelete), true)
    }

    nonisolated static func send(_ request: Request) -> Int32 {
        guard request.source.isFileURL, request.source.query == nil, request.source.fragment == nil,
              request.source.pathExtension.lowercased() == "app", request.stillCurrent(),
              let file = NSAppleEventDescriptor(fileURL: request.source).coerce(toDescriptorType: DescType(typeAlias)),
              file.fileURLValue?.standardizedFileURL.path == request.source.standardizedFileURL.path,
              request.stillCurrent() else { return changed }
        let event = event(kAEDelete)
        event.setParam(file, forKeyword: AEKeyword(keyDirectObject))
        return reply(to: event)
    }

    nonisolated static func putBack(_ request: RestoreRequest) -> RestoreReply {
        let source = request.source, destination = request.destination
        guard [source, destination].allSatisfy({ $0.isFileURL && $0.query == nil && $0.fragment == nil && $0.pathExtension.lowercased() == "app" }),
              request.stillCurrent(source),
              let parent = alias(destination.deletingLastPathComponent()) else {
            return .init(status: changed, location: nil)
        }
        var current = source
        var reference = request.reference
        if source.deletingLastPathComponent().path != destination.deletingLastPathComponent().path {
            guard let file = alias(source), request.stillCurrent(source) else { return .init(status: changed, location: nil) }
            let move = event(kAEMove)
            move.setParam(file, forKeyword: AEKeyword(keyDirectObject))
            move.setParam(parent, forKeyword: AEKeyword(keyAEInsertHere))
            // Finder's documented "replacing" parameter, explicitly false.
            move.setParam(NSAppleEventDescriptor(boolean: false), forKeyword: AEKeyword(0x616c7270))
            let result = response(to: move)
            let status = result.status
            reference = result.object?.descriptorType == DescType(typeObjectSpecifier) ? result.object?.data : nil
            current = destination.deletingLastPathComponent().appendingPathComponent(source.lastPathComponent)
            if status != noErr { return .init(status: status, location: current, reference: reference) }
        }
        if current.path == destination.path { return .init(status: noErr, location: current) }
        // Trash may have added a suffix. Move and rename are separate Finder
        // operations; retain the verified intermediate location for a retry.
        guard request.stillCurrent(current),
              let reference, reference.count <= 131_072,
              let file = NSAppleEventDescriptor(descriptorType: DescType(typeObjectSpecifier), data: reference),
              let name = object(want: typeProperty, in: file, form: OSType(formPropertyID),
                                key: NSAppleEventDescriptor(typeCode: DescType(pName))),
              request.stillCurrent(current) else { return .init(status: changed, location: current, reference: reference) }
        let rename = event(kAESetData)
        rename.setParam(name, forKeyword: AEKeyword(keyDirectObject))
        rename.setParam(NSAppleEventDescriptor(string: destination.lastPathComponent), forKeyword: AEKeyword(keyAEData))
        let status = reply(to: rename)
        return .init(status: status, location: status == noErr ? destination : current, reference: reference)
    }

    private nonisolated static func alias(_ url: URL) -> NSAppleEventDescriptor? {
        guard let file = NSAppleEventDescriptor(fileURL: url).coerce(toDescriptorType: DescType(typeAlias)),
              file.fileURLValue?.standardizedFileURL.path == url.standardizedFileURL.path else { return nil }
        return file
    }

    private nonisolated static func object(want: OSType, in container: NSAppleEventDescriptor, form: OSType,
                                           key: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(key, forKeyword: AEKeyword(keyAEKeyData))
        return record.coerce(toDescriptorType: DescType(typeObjectSpecifier))
    }

    private nonisolated static func event(_ id: AEEventID) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: id,
                              targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder"),
                              returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    private nonisolated static func reply(to event: NSAppleEventDescriptor) -> Int32 {
        response(to: event).status
    }

    private nonisolated static func response(to event: NSAppleEventDescriptor) -> (status: Int32, object: NSAppleEventDescriptor?) {
        var reply = AppleEvent()
        // Keep ownership of the removal job until Finder finishes or the user
        // cancels. A timeout could leave a later, untracked administrator move.
        let status = AESendMessage(event.aeDesc, &reply,
                                   AESendMode(kAEWaitReply | kAECanInteract | kAECanSwitchLayer), kNoTimeOut)
        guard status == noErr else { AEDisposeDesc(&reply); return (status, nil) }
        let response = NSAppleEventDescriptor(aeDescNoCopy: &reply)
        let object = response.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
        return (response.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? noErr,
                object?.descriptorType == DescType(typeAEList) ? object?.atIndex(1) : object)
    }

    static func restoreFailure(_ code: Int32) -> NSError {
        let text: String
        switch code {
        case automationDenied, consentRequired:
            text = String(localized: "Allow MyMole to control Finder in System Settings → Privacy & Security → Automation, then try Undo again.")
        case cancelled:
            text = String(localized: "Restoring the app was cancelled. Undo can try again.")
        case changed:
            text = String(localized: "The app or its original folder changed, or the original location is occupied. Nothing there will be replaced. Check in Finder before trying Undo again.")
        default:
            text = String(localized: "The app could not be verified at its original location. Undo can retry from its last verified location. Check in Finder before trying again.")
        }
        return NSError(domain: "MyMole.FinderAppRestoreFailure", code: Int(code), userInfo: [NSLocalizedDescriptionKey: text])
    }

    static func failure(_ code: Int32) -> NSError {
        let text: String
        switch code {
        case automationDenied, consentRequired:
            text = String(localized: "Allow MyMole to control Finder in System Settings → Privacy & Security → Automation, then try again. No app data was moved.")
        case cancelled:
            text = String(localized: "The Finder move was cancelled. No app data was moved.")
        case changed:
            text = String(localized: "The app changed before Finder could move it. Refresh the review. No app data was moved.")
        case unverified:
            text = String(localized: "The app's move to the Trash could not be verified. No app data was moved. Check the app in Finder before trying again.")
        default:
            text = String(localized: "Finder couldn't move the app to the Trash. No app data was moved.")
        }
        return NSError(domain: "MyMole.FinderAppTrashFailure", code: Int(code), userInfo: [NSLocalizedDescriptionKey: text])
    }

    @MainActor static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }
}
