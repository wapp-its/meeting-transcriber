#if !APPSTORE
    import Foundation

    extension DebugRPCServer {
        /// `POST /action/openAudioDevices` and `/action/closeAudioDevices`:
        /// open the Audio Devices window or bring it to the front, and close
        /// it, through the scene the menu item uses, as `/action/openSettings`
        /// and `/action/closeSettings` do for Settings. A close while the
        /// window is closed changes nothing.
        static func routeAudioDevicesAction(path: String) -> HTTPResponse {
            let name: Notification.Name = path == "/action/openAudioDevices" ? .showAudioDevices : .closeAudioDevices
            NotificationCenter.default.post(name: name, object: nil)
            return HTTPResponse.ok()
        }
    }
#endif
