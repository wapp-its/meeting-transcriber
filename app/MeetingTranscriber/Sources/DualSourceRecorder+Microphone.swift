import AudioTapLib
import Foundation

/// The recording's microphone, forwarded to the capture session, split out of
/// `DualSourceRecorder.swift` to keep that file under the line cap.
///
/// Between recordings there is no session: no device, no microphone track, and
/// a selection goes nowhere, because the next recording reads the choice when
/// it starts. `tappedPIDs`, which the same callers read, is stored and so
/// stays in the class body.
extension DualSourceRecorder {
    var micInputDevice: MicInputDevice? {
        captureSession?.micInputDevice
    }

    var microphoneTrackActive: Bool {
        captureSession?.microphoneTrackActive ?? false
    }

    func selectMicrophone(deviceUID: String?) {
        captureSession?.selectMicrophone(deviceUID: deviceUID)
    }
}
