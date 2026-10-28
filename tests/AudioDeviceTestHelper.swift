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

private func settableInputElements(_ device: AudioDeviceID) -> [AudioObjectPropertyElement] {
    guard inputChannelCount(device) > 0 else { return [] }
    var candidates: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain]
    let channels = inputChannelCount(device)
    if channels > 0 {
        candidates.append(contentsOf: (1...channels).map(AudioObjectPropertyElement.init))
    }
    var supported: [AudioObjectPropertyElement] = []
    for element in candidates where !supported.contains(element) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: element
        )
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else {
            continue
        }
        supported.append(element)
    }
    return supported
}

private func readScalar(
    _ device: AudioDeviceID,
    element: AudioObjectPropertyElement
) -> Float32? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: element
    )
    var volume: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
    return status == noErr ? volume : nil
}

private func writeScalar(
    _ device: AudioDeviceID,
    element: AudioObjectPropertyElement,
    value: Float32
) -> OSStatus {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: element
    )
    var newValue = value
    return AudioObjectSetPropertyData(
        device,
        &address,
        0,
        nil,
        UInt32(MemoryLayout<Float32>.size),
        &newValue
    )
}

private func usage() -> Never {
    fputs(
        "usage: audio-device-test-helper {list|current|builtin|nonbuiltin|scalar|set-scalar PERCENT|select ID|other-lockable|other-unlockable}\n",
        stderr
    )
    exit(64)
}

private let arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else { usage() }

switch arguments[0] {
case "list" where arguments.count == 1:
    for device in inputDevices() {
        let kind = isBuiltInInput(device) ? "builtin" : "external"
        print("\(device)\t\(kind)\t\(deviceName(device))")
    }
case "current" where arguments.count == 1:
    guard let device = defaultInputDevice() else {
        fputs("no default input device\n", stderr)
        exit(2)
    }
    print("\(device)\t\(deviceName(device))")
case "scalar" where arguments.count == 1:
    guard let device = defaultInputDevice() else {
        fputs("no default input device\n", stderr)
        exit(2)
    }
    let values = settableInputElements(device).compactMap { readScalar(device, element: $0) }
    guard let lowest = values.min() else {
        fputs("none\n", stderr)
        exit(3)
    }
    print(Int((lowest * 100).rounded()))
case "set-scalar" where arguments.count == 2:
    guard let percent = Int(arguments[1]), (0...100).contains(percent) else {
        fputs("percent must be 0...100\n", stderr)
        exit(64)
    }
    guard let device = defaultInputDevice() else {
        fputs("no default input device\n", stderr)
        exit(2)
    }
    let elements = settableInputElements(device)
    guard !elements.isEmpty else {
        fputs("no settable input volume\n", stderr)
        exit(3)
    }
    let value = Float32(percent) / 100
    for element in elements where writeScalar(device, element: element, value: value) != noErr {
        fputs("failed to write input volume\n", stderr)
        exit(5)
    }
    print(percent)
case "select" where arguments.count == 2:
    guard let id = UInt32(arguments[1]) else {
        fputs("device id must be an integer\n", stderr)
        exit(64)
    }
    guard setDefaultInputDevice(id) else {
        fputs("failed to select input device\n", stderr)
        exit(4)
    }
    print("\(id)\t\(deviceName(id))")
case "other-lockable" where arguments.count == 1:
    guard let current = defaultInputDevice() else {
        fputs("no default input device\n", stderr)
        exit(2)
    }
    guard let device = inputDevices().first(where: {
        $0 != current && !settableInputElements($0).isEmpty
    }) else {
        fputs("no other input with a settable volume\n", stderr)
        exit(3)
    }
    print("\(device)\t\(deviceName(device))")
case "other-unlockable" where arguments.count == 1:
    guard let current = defaultInputDevice() else {
        fputs("no default input device\n", stderr)
        exit(2)
    }
    guard let device = inputDevices().first(where: {
        $0 != current && settableInputElements($0).isEmpty
    }) else {
        fputs("no other input without a settable volume\n", stderr)
        exit(3)
    }
    print("\(device)\t\(deviceName(device))")
case "builtin" where arguments.count == 1:
    guard let device = inputDevices().first(where: isBuiltInInput) else {
        fputs("no built-in input device found\n", stderr)
        exit(3)
    }
    guard setDefaultInputDevice(device) else {
        fputs("failed to select built-in input device\n", stderr)
        exit(4)
    }
    print("\(device)\t\(deviceName(device))")
case "nonbuiltin" where arguments.count == 1:
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
    usage()
}
