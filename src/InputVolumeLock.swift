import AudioToolbox
import CoreAudio
import Foundation

private let targetVolume: Float32 = 1.0
private let volumeTolerance: Float32 = 0.0001
private let heartbeatInterval: TimeInterval = 5.0
private let warningInterval: TimeInterval = 600.0
private let correctionLogInterval: TimeInterval = 60.0

private let logTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
    return formatter
}()

private func timestamp() -> String {
    logTimestampFormatter.string(from: Date())
}

private func log(_ message: String) {
    print("[\(timestamp())] \(message)")
    fflush(stdout)
}

private func inputVolumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: element
    )
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
    guard status == noErr, device != kAudioObjectUnknown else {
        return nil
    }
    return device
}

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

private func volumeElements(_ device: AudioDeviceID) -> [AudioObjectPropertyElement] {
    var candidates: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain]
    let channels = inputChannelCount(device)
    if channels > 0 {
        candidates.append(contentsOf: (1...channels).map(AudioObjectPropertyElement.init))
    }

    var supported: [AudioObjectPropertyElement] = []
    for element in candidates where !supported.contains(element) {
        var address = inputVolumeAddress(element: element)
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

private func readVolume(
    _ device: AudioDeviceID,
    element: AudioObjectPropertyElement
) -> Float32? {
    var address = inputVolumeAddress(element: element)
    var volume: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
    return status == noErr ? volume : nil
}

private struct VolumeReading {
    let element: AudioObjectPropertyElement
    let value: Float32
}

private func readingsBelowTarget(_ readings: [VolumeReading]) -> [VolumeReading] {
    readings.filter { $0.value < targetVolume - volumeTolerance }
}

private func writeVolume(
    _ device: AudioDeviceID,
    element: AudioObjectPropertyElement,
    value: Float32
) -> OSStatus {
    var address = inputVolumeAddress(element: element)
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

private func isBuiltInInput(_ device: AudioDeviceID) -> Bool {
    inputChannelCount(device) > 0 &&
        transportType(device) == kAudioDeviceTransportTypeBuiltIn
}

private final class InputVolumeGuard {
    private let queue = DispatchQueue(label: "io.github.input-volume-lock.audio")
    private var heartbeat: DispatchSourceTimer?
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var deviceListeners:
        [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var currentDevice = AudioDeviceID(kAudioObjectUnknown)
    private var lastIneligibleDevice: AudioDeviceID = kAudioObjectUnknown
    private var lastNoDeviceWarning: Date?
    private var lastReadWarning: Date?
    private var lastRestoreWarning: Date?
    private var lastCorrectionLog: Date?
    private var suppressedCorrections = 0

    func start() {
        queue.async {
            self.installDefaultDeviceListener()
            self.enforce()
            self.startHeartbeat()
        }
    }

    private func installDefaultDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.queue.async {
                self?.attachToDefaultDeviceIfNeeded()
                self?.enforce()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener
        )
        if status == noErr {
            systemListener = listener
        } else {
            log("warning: default-input listener failed with OSStatus \(status); heartbeat remains active")
        }
    }

    private func attachToDefaultDeviceIfNeeded() {
        guard let device = defaultInputDevice(), device != currentDevice else {
            return
        }

        removeDeviceListeners()
        currentDevice = device

        guard isBuiltInInput(device) else { return }

        for element in volumeElements(device) {
            var address = inputVolumeAddress(element: element)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.queue.async { self?.enforce() }
            }
            let status = AudioObjectAddPropertyListenerBlock(
                device,
                &address,
                queue,
                listener
            )
            if status == noErr {
                deviceListeners.append((address, listener))
            }
        }
        log("watching built-in input: \(deviceName(device))")
    }

    private func removeDeviceListeners() {
        guard currentDevice != kAudioObjectUnknown else {
            deviceListeners.removeAll()
            return
        }
        for record in deviceListeners {
            var address = record.address
            AudioObjectRemovePropertyListenerBlock(
                currentDevice,
                &address,
                queue,
                record.block
            )
        }
        deviceListeners.removeAll()
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + heartbeatInterval,
            repeating: heartbeatInterval,
            leeway: .seconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.flushSuppressedCorrectionsIfDue()
            self?.attachToDefaultDeviceIfNeeded()
            self?.enforce()
        }
        timer.resume()
        heartbeat = timer
    }

    private func rateLimitedWarning(_ message: String, lastLogged: inout Date?) {
        let now = Date()
        if let lastLogged,
           now.timeIntervalSince(lastLogged) < warningInterval {
            return
        }
        log(message)
        lastLogged = now
    }

    private func logCorrection(_ message: String) {
        let now = Date()
        if let lastCorrectionLog,
           now.timeIntervalSince(lastCorrectionLog) < correctionLogInterval {
            suppressedCorrections += 1
            return
        }

        let suffix = suppressedCorrections > 0
            ? " (\(suppressedCorrections) similar corrections suppressed)"
            : ""
        log(message + suffix)
        lastCorrectionLog = now
        suppressedCorrections = 0
    }

    private func flushSuppressedCorrectionsIfDue() {
        guard suppressedCorrections > 0,
              let lastCorrectionLog,
              Date().timeIntervalSince(lastCorrectionLog) >= correctionLogInterval else {
            return
        }
        log(
            "summary: \(suppressedCorrections)"
                + " repeated input volume correction(s) were suppressed"
        )
        self.lastCorrectionLog = Date()
        suppressedCorrections = 0
    }

    private func enforce() {
        guard let device = defaultInputDevice() else {
            rateLimitedWarning(
                "warning: no default input device",
                lastLogged: &lastNoDeviceWarning
            )
            return
        }
        lastNoDeviceWarning = nil

        if device != currentDevice {
            attachToDefaultDeviceIfNeeded()
        }

        guard isBuiltInInput(device) else {
            if lastIneligibleDevice != device {
                log("skip: default input is not built-in: \(deviceName(device))")
                lastIneligibleDevice = device
            }
            return
        }
        lastIneligibleDevice = kAudioObjectUnknown

        let elements = volumeElements(device)
        let readings = elements.compactMap { element -> VolumeReading? in
            readVolume(device, element: element).map {
                VolumeReading(element: element, value: $0)
            }
        }
        guard !readings.isEmpty else {
            rateLimitedWarning(
                "warning: could not read built-in input volume",
                lastLogged: &lastReadWarning
            )
            return
        }
        lastReadWarning = nil

        let lowReadings = readingsBelowTarget(readings)
        guard !lowReadings.isEmpty else {
            return
        }

        var failedStatuses: [OSStatus] = []
        for element in elements {
            let status = writeVolume(device, element: element, value: targetVolume)
            if status != noErr {
                failedStatuses.append(status)
            }
        }

        let afterReadings = elements.compactMap { element -> VolumeReading? in
            readVolume(device, element: element).map {
                VolumeReading(element: element, value: $0)
            }
        }
        let remainingLow = readingsBelowTarget(afterReadings)
        if failedStatuses.isEmpty &&
            afterReadings.count == readings.count &&
            remainingLow.isEmpty {
            let lowestBefore = lowReadings.map(\.value).min() ?? 0
            logCorrection(
                String(
                    format: "restored input volume %.1f%% -> %.1f%% on %@ (%d element(s) corrected)",
                    lowestBefore * 100,
                    targetVolume * 100,
                    deviceName(device),
                    lowReadings.count
                )
            )
        } else {
            let remaining = remainingLow
                .map { String(format: "%.1f%%", $0.value * 100) }
                .joined(separator: ", ")
            rateLimitedWarning(
                String(
                    format: "warning: failed to restore %@; read-backs [%@]; write errors [%@]",
                    deviceName(device),
                    remaining.isEmpty ? "none low" : remaining,
                    failedStatuses.map(String.init).joined(separator: ", ")
                ),
                lastLogged: &lastRestoreWarning
            )
        }
    }
}

private func runFocusedOnce() -> Never {
    guard let device = defaultInputDevice() else {
        log("error: no default input device")
        exit(2)
    }
    guard isBuiltInInput(device) else {
        log("skip: default input is not built-in: \(deviceName(device))")
        exit(0)
    }
    let elements = volumeElements(device)
    let beforeReadings = elements.compactMap { element -> VolumeReading? in
        readVolume(device, element: element).map {
            VolumeReading(element: element, value: $0)
        }
    }
    guard !beforeReadings.isEmpty else {
        log("error: could not read built-in input volume")
        exit(3)
    }

    var failedStatuses: [OSStatus] = []
    for element in elements {
        let status = writeVolume(device, element: element, value: targetVolume)
        if status != noErr {
            failedStatuses.append(status)
        }
    }

    let afterReadings = elements.compactMap { element -> VolumeReading? in
        readVolume(device, element: element).map {
            VolumeReading(element: element, value: $0)
        }
    }
    let remainingLow = readingsBelowTarget(afterReadings)
    guard failedStatuses.isEmpty,
          afterReadings.count == beforeReadings.count,
          remainingLow.isEmpty else {
        let remaining = remainingLow
            .map { String(format: "%.1f%%", $0.value * 100) }
            .joined(separator: ", ")
        log(
            "error: input volume did not reach 100%;"
                + " read-backs [\(remaining.isEmpty ? "none low" : remaining)];"
                + " write errors [\(failedStatuses.map(String.init).joined(separator: ", "))]"
        )
        exit(5)
    }

    let lowestBefore = beforeReadings.map(\.value).min() ?? 0
    log(
        String(
            format: "locked input volume %.1f%% -> %.1f%% on %@ (%d element(s))",
            lowestBefore * 100,
            targetVolume * 100,
            deviceName(device),
            beforeReadings.count
        )
    )
    exit(0)
}

private func runSelfTest() -> Never {
    var failures = 0

    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            print("PASS: \(message)")
        } else {
            print("FAIL: \(message)")
            failures += 1
        }
    }

    let mixed = [
        VolumeReading(element: kAudioObjectPropertyElementMain, value: 1.0),
        VolumeReading(element: 1, value: 0.4)
    ]
    expect(
        readingsBelowTarget(mixed).map(\.element) == [1],
        "detects a low channel even when master is 100%"
    )
    expect(
        readingsBelowTarget([
            VolumeReading(element: kAudioObjectPropertyElementMain, value: 1.0)
        ]).isEmpty,
        "does not flag volume at the target"
    )
    expect(
        readingsBelowTarget([
            VolumeReading(element: 1, value: 1.0 - volumeTolerance / 2)
        ]).isEmpty,
        "tolerates floating-point noise near 100%"
    )
    expect(
        readingsBelowTarget([
            VolumeReading(element: 1, value: 0)
        ]).count == 1,
        "detects complete mute"
    )

    if failures > 0 {
        print("\(failures) self-test(s) failed")
        exit(1)
    }
    print("All self-tests passed")
    exit(0)
}

private let arguments = Array(CommandLine.arguments.dropFirst())
private let knownArguments: Set<String> = ["--once", "--watch", "--self-test", "--help"]
let unknownArguments = arguments.filter { !knownArguments.contains($0) }
if !unknownArguments.isEmpty {
    log("error: unknown argument(s): \(unknownArguments.joined(separator: " "))")
    log("usage: input-volume-lock [--watch | --once | --self-test | --help]")
    exit(64)
}

let uniqueArguments = Set(arguments)
let modeCount = uniqueArguments.intersection(["--once", "--watch", "--self-test"]).count
if modeCount > 1 {
    log("error: choose only one of --once, --watch, or --self-test")
    exit(64)
}

if uniqueArguments.contains("--help") {
    print("usage: input-volume-lock [--watch | --once | --self-test | --help]")
    exit(0)
}

if uniqueArguments.contains("--self-test") {
    runSelfTest()
}

if uniqueArguments.contains("--once") {
    runFocusedOnce()
}

private let guardService = InputVolumeGuard()
guardService.start()
log("input volume guard started; target=100%, built-in input only")
dispatchMain()
