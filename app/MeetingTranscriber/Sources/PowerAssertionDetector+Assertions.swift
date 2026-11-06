import Foundation
import IOKit.pwr_mgt

/// How `PowerAssertionDetector` reads the machine's power assertions and
/// decides whether one assertion matches one pattern, split out of the
/// detector to keep that file under the length cap.
extension PowerAssertionDetector {
    /// Processes that belong to an app the user can watch in its own right. A
    /// process-open pattern can never take one of these, so a native client is
    /// never also seen as a browser meeting.
    ///
    /// Two sources, because an app can be known to this detector, to
    /// `MicInputDetector`, or to both: the bound assertion patterns here, plus
    /// every `AppMeetingPattern.ownerNames`, which is where the mic-detected
    /// call apps (WeChat, WhatsApp, FaceTime, Tencent Meeting, Slack) are declared.
    /// WhatsApp in particular is Electron and so a plausible holder of the very
    /// assertion the open pattern keys on.
    ///
    /// Always from ALL known apps, never from the watched subset. Otherwise
    /// switching an app's toggle off would hand it to the browser path and
    /// record it anyway, against the user's explicit opt-out, which is the one
    /// thing this exclusion exists to prevent.
    static let claimedProcesses: Set<String> = Set(
        defaultPatterns.flatMap(\.processNames) + AppMeetingPattern.all.flatMap(\.ownerNames),
    )

    /// Whether one assertion matches one pattern.
    ///
    /// Bound patterns check the process first, as before. Process-open patterns
    /// accept any process except one claimed by a bound pattern: Teams is
    /// Electron and plausibly holds the identical WebRTC assertion during a
    /// call, so without the exclusion a native Teams call would fire twice, once
    /// auto-starting under its own pattern and once prompting as a browser
    /// meeting.
    ///
    /// The exclusion is keyed on the process, not the service, which is what
    /// keeps web meetings working: Zoom, Teams or Webex taken in a browser hold
    /// the assertion under the browser, and no native pattern claims a browser.
    static func matches(
        pattern: AssertionPattern,
        processName: String,
        assertName: String,
        assertType: String,
    ) -> Bool {
        if pattern.processNames.isEmpty {
            // The name becomes the identity, the prompt body and the deny-list
            // key, so a blank one would ask "A meeting is active in ." and store
            // an unremovable blank row. The allowlist used to make this
            // unreachable.
            guard !processName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            guard !claimedProcesses.contains(processName) else { return false }
        } else {
            guard pattern.processNames.contains(processName) else { return false }
        }
        if pattern.matchesKeyword(in: assertName) { return true }
        return pattern.assertionTypes.contains(assertType)
    }

    /// Default assertion provider using IOPMCopyAssertionsByProcess.
    ///
    /// The API returns a CFDictionary keyed by PID (CFNumber), not String.
    /// We extract keys/values manually via CFDictionaryGetKeysAndValues.
    static func systemAssertions() -> [Int32: [[String: Any]]] {
        var assertionsByProcess: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsByProcess(&assertionsByProcess)
        guard status == kIOReturnSuccess, let raw = assertionsByProcess else {
            return [:]
        }

        let cfDict = raw.takeRetainedValue()
        let count = CFDictionaryGetCount(cfDict)
        guard count > 0 else { return [:] }

        let keys = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: count)
        let values = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: count)
        defer {
            keys.deallocate()
            values.deallocate()
        }
        CFDictionaryGetKeysAndValues(cfDict, keys, values)

        var result: [Int32: [[String: Any]]] = [:]
        for i in 0 ..< count {
            guard let valPtr = values[i] else { continue }
            guard let keyPtr = keys[i] else { continue }
            let keyObj = Unmanaged<AnyObject>.fromOpaque(keyPtr).takeUnretainedValue()
            let pid = keyObj as? Int32 ?? 0
            let valObj = Unmanaged<AnyObject>.fromOpaque(valPtr).takeUnretainedValue()
            if let assertions = valObj as? [[String: Any]] {
                result[pid] = assertions
            }
        }
        return result
    }
}
