import CoreAudio
import Foundation

/// Process-aware microphone activity detection.
///
/// The default signal — `kAudioDevicePropertyDeviceIsRunningSomewhere` on the
/// system input device — is true if *any* process is holding the mic open,
/// including always-on listeners like Superwhisper, dictation, or Voice
/// Control. That makes the device-level signal useless for detecting whether
/// the user is actually on a call when one of those listeners runs.
///
/// macOS 14 added a process audio API that lets us enumerate which processes
/// are currently consuming input, so we can ignore the always-on listeners
/// and report mic-active only when a "real" app (Zoom, Teams, browser, etc.)
/// has the mic. We also skip our own pid so future features that open the
/// mic from this app don't pin the light to busy.
enum AudioProcessMonitor {
    /// Default ignore list — bundle IDs of well-known always-on mic listeners.
    /// Users can extend via the `busyLightIgnoredAudioBundleIDs` UserDefaults key.
    static let defaultIgnoredBundleIDs: Set<String> = [
        "com.superduper.superwhisper",   // Superwhisper
        "com.apple.SpeechRecognitionCore.speechrecognitiond",
        "com.apple.assistantd",          // Siri / dictation
        "com.apple.VoiceOver"
    ]

    /// Returns true if any process other than self and the ignored set is
    /// currently holding the input device open. Returns nil on macOS 13 or
    /// when the process audio API is unavailable — callers should fall back
    /// to the device-level signal.
    static func isAnyOtherProcessUsingInput(ignoredBundleIDs: Set<String>) -> Bool? {
        guard #available(macOS 14.0, *) else { return nil }
        return Impl.isAnyOtherProcessUsingInput(ignoredBundleIDs: ignoredBundleIDs)
    }

    /// Bundle IDs of every process currently consuming input, excluding self.
    /// Useful for surfacing "these apps are holding the mic" in settings.
    /// Returns nil on macOS 13.
    static func activeInputBundleIDs() -> [String]? {
        guard #available(macOS 14.0, *) else { return nil }
        return Impl.activeInputBundleIDs()
    }

    @available(macOS 14.0, *)
    private enum Impl {
        static func isAnyOtherProcessUsingInput(ignoredBundleIDs: Set<String>) -> Bool? {
            guard let ids = processList() else { return nil }
            let selfPID = ProcessInfo.processInfo.processIdentifier

            for processID in ids {
                if !isRunningInput(processID) { continue }
                if let p = pid(of: processID), p == selfPID { continue }
                if let bid = bundleID(of: processID), ignoredBundleIDs.contains(bid) { continue }
                return true
            }
            return false
        }

        static func activeInputBundleIDs() -> [String]? {
            guard let ids = processList() else { return nil }
            let selfPID = ProcessInfo.processInfo.processIdentifier
            var result: [String] = []
            for processID in ids {
                if !isRunningInput(processID) { continue }
                if let p = pid(of: processID), p == selfPID { continue }
                if let bid = bundleID(of: processID) { result.append(bid) }
            }
            return result
        }

        private static func processList() -> [AudioObjectID]? {
            var size: UInt32 = 0
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let sz = AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
            )
            guard sz == noErr, size > 0 else { return nil }
            let count = Int(size) / MemoryLayout<AudioObjectID>.size
            var ids = [AudioObjectID](repeating: 0, count: count)
            let status = ids.withUnsafeMutableBufferPointer { buf -> OSStatus in
                var s = size
                return AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &addr, 0, nil, &s, buf.baseAddress!
                )
            }
            return status == noErr ? ids : nil
        }

        private static func isRunningInput(_ processID: AudioObjectID) -> Bool {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value: UInt32 = 0
            var sz = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(processID, &addr, 0, nil, &sz, &value) == noErr && value != 0
        }

        private static func pid(of processID: AudioObjectID) -> pid_t? {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value: pid_t = 0
            var sz = UInt32(MemoryLayout<pid_t>.size)
            return AudioObjectGetPropertyData(processID, &addr, 0, nil, &sz, &value) == noErr ? value : nil
        }

        private static func bundleID(of processID: AudioObjectID) -> String? {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value: CFString?
            var sz = UInt32(MemoryLayout<CFString?>.size)
            let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
                AudioObjectGetPropertyData(processID, &addr, 0, nil, &sz, ptr)
            }
            guard status == noErr, let cf = value else { return nil }
            return cf as String
        }
    }
}
