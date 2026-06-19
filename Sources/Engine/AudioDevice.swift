import Foundation
import CoreAudio

@available(macOS 14.2, *)
public struct AudioDevice: Identifiable, Hashable {
    public var id: AudioDeviceID { deviceID }
    public let deviceID: AudioDeviceID
    public let name: String
    public let uid: String
    
    public init(deviceID: AudioDeviceID, name: String, uid: String) {
        self.deviceID = deviceID
        self.name = name
        self.uid = uid
    }
}
