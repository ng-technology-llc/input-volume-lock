import CoreAudio
import Foundation

private func deviceName(_ device: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &name) {
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
    }
    guard status == noErr, let name else {
        return "unknown"
    }
    return name.takeRetainedValue() as String
}

private func inputChannelCount(_ device: AudioDeviceID) -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
          size >= UInt32(MemoryLayout<AudioBufferList>.size) else {
        return 0
    }
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else {
        return 0
    }
    let buffers = UnsafeMutableAudioBufferListPointer(
        raw.assumingMemoryBound(to: AudioBufferList.self)
    )
    return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
}

private func transportType(_ device: AudioDeviceID) -> UInt32? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var transport: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
    return status == noErr ? transport : nil
}

private func allDevices() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size
    ) == noErr else {
        return []
    }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    guard count > 0 else { return [] }
    var devices = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size,
        &devices
    ) == noErr else {
        return []
    }
    return devices
}

private func defaultInputDevice() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size,
        &device
    )
    return status == noErr && device != kAudioObjectUnknown ? device : nil
}

private func setDefaultInputDevice(_ device: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var selected = device
    let status = AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        UInt32(MemoryLayout<AudioDeviceID>.size),
        &selected
    )
    return status == noErr
}

private func isBuiltInInput(_ device: AudioDeviceID) -> Bool {
    inputChannelCount(device) > 0 &&
        transportType(device) == kAudioDeviceTransportTypeBuiltIn
}

private func inputDevices() -> [AudioDeviceID] {
    allDevices().filter { inputChannelCount($0) > 0 }
}

private let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1 else {
    fputs("usage: audio-device-test-helper {list|current|builtin|nonbuiltin}\n", stderr)
    exit(64)
}

switch arguments[0] {
case "list":
    for device in inputDevices() {
        let kind = isBuiltInInput(device) ? "builtin" : "external"
        print("\(device)\t\(kind)\t\(deviceName(device))")
    }
case "current":
    guard let device = defaultInputDevice() else {
        fputs("no default input device\n", stderr)
        exit(2)
    }
    print("\(device)\t\(deviceName(device))")
case "builtin":
    guard let device = inputDevices().first(where: isBuiltInInput) else {
        fputs("no built-in input device found\n", stderr)
        exit(3)
    }
    guard setDefaultInputDevice(device) else {
        fputs("failed to select built-in input device\n", stderr)
        exit(4)
    }
    print("\(device)\t\(deviceName(device))")
case "nonbuiltin":
    guard let device = inputDevices().first(where: { !isBuiltInInput($0) }) else {
        fputs("no non-built-in input device found\n", stderr)
        exit(3)
    }
    guard setDefaultInputDevice(device) else {
        fputs("failed to select non-built-in input device\n", stderr)
        exit(4)
    }
    print("\(device)\t\(deviceName(device))")
default:
    fputs("unknown command\n", stderr)
    exit(64)
}
