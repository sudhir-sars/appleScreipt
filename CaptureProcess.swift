import Foundation
@preconcurrency import AVFoundation
import ScreenCaptureKit
import CoreGraphics
import CoreAudio
import os.log

// MARK: - Logger

class FileLogger {
    static let shared = FileLogger()
    private let logFile: FileHandle?
    private let logURL: URL
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "com.capture.logger", qos: .utility)
    
    init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        
        // Create log file in process directory
        let processPath = FileManager.default.currentDirectoryPath
        let logFileName = "capture_process_\(ProcessInfo.processInfo.processIdentifier)_\(Date().timeIntervalSince1970).log"
        logURL = URL(fileURLWithPath: processPath).appendingPathComponent(logFileName)
        
        // Create log file
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: nil)
        logFile = try? FileHandle(forWritingTo: logURL)
        
        log("=== CAPTURE PROCESS STARTED ===")
        log("Process ID: \(ProcessInfo.processInfo.processIdentifier)")
        log("Log file: \(logURL.path)")
        log("Arguments: \(ProcessInfo.processInfo.arguments)")
    }
    
    func log(_ message: String, level: String = "INFO") {
        queue.async { [weak self] in
            guard let self = self, let logFile = self.logFile else { return }
            
            let timestamp = self.dateFormatter.string(from: Date())
            let logEntry = "[\(timestamp)] [\(level)] \(message)\n"
            
            if let data = logEntry.data(using: .utf8) {
                logFile.write(data)
                logFile.synchronizeFile()
            }
            
            // Also print to console for debugging
            print(logEntry.trimmingCharacters(in: .newlines))
        }
    }
    
    func logError(_ message: String, error: Error? = nil) {
        if let error = error {
            log("\(message): \(error.localizedDescription)", level: "ERROR")
        } else {
            log(message, level: "ERROR")
        }
    }
    
    deinit {
        log("=== CAPTURE PROCESS ENDING ===")
        logFile?.closeFile()
    }
}

// MARK: - Data Models

struct StreamInfo: Codable {
    let id: String
    let name: String
    let deviceId: String?
    let isDefault: Bool
    let type: String
    let status: String
    var filePath: String?
}

struct VideoStreamInfo: Codable {
    let id: String
    let name: String
    let type: String
    let isPrimary: Bool
    let status: String
    var filePaths: FilePaths?
    
    struct FilePaths: Codable {
        let combined: String?
        let video: String?
        let audio: String?
    }
}

struct CaptureResponse: Codable {
    let type: String
    let operation: String
    let timestamp: String
    let success: Bool
    let message: String
    let error: ErrorInfo?
    let data: ResponseData?
    
    struct ErrorInfo: Codable {
        let code: String
        let message: String
        let details: String
    }
    
    struct ResponseData: Codable {
        let streams: StreamsInfo?
        let metadata: Metadata?
        
        struct StreamsInfo: Codable {
            let audio: [StreamInfo]
            let video: [VideoStreamInfo]
        }
        
        struct Metadata: Codable {
            let totalStreams: Int
            let activeStreams: Int
            let testMode: Bool
            let saveDirectory: String?
            let permissions: Permissions
            
            struct Permissions: Codable {
                let microphone: String
                let screenCapture: String
            }
        }
    }
}

// MARK: - Main Capture Process

// Replace lines 110–687 with this
actor AudioVideoCaptureProcess {
    private let logger = FileLogger.shared
    private var isTestMode = false
    private var saveDirectory: String?
    private var activeStreams: [String: Any] = [:]
    private var audioEngines: [String: AVAudioEngine] = [:]
    private var screenStreams: [String: SCStream] = [:]
    private var audioFiles: [String: AVAudioFile] = [:]
    private var videoWriters: [String: AVAssetWriter] = [:]
    private var streamToPathMapping: [SCStream: String] = [:]
    private var screenRecordingAuthorized = false
    private var microphoneAuthorized = false
    private let ipcQueue = DispatchQueue(label: "com.capture.ipc", qos: .userInteractive)
    private let captureQueue = DispatchQueue(label: "com.capture.main", qos: .userInitiated)
    private var inputHandler: FileHandle?

    // Singleton replacement for actor
    static let shared = AudioVideoCaptureProcess()

    init() {
        logger.log("AudioVideoCaptureProcess initializing...")
        
        // Setup signal handlers for graceful shutdown
        signal(SIGINT) { _ in
            FileLogger.shared.log("Received SIGINT signal")
            exit(0)
        }
        
        signal(SIGTERM) { _ in
            FileLogger.shared.log("Received SIGTERM signal")
            exit(0)
        }
        
        Task {
            await processCommandLineArguments()
            await checkInitialPermissions()
            await setupIPC()
        }
    }
    
    private func processCommandLineArguments() {
        logger.log("Processing command line arguments...")
        let arguments = CommandLine.arguments
        if arguments.contains("--testmode") {
            isTestMode = true
            logger.log("Test mode enabled")
            createTestModeDirectory()
        }
    }
    
    private func checkInitialPermissions() async {
        logger.log("Checking initial permissions...")
        
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneAuthorized = (audioStatus == .authorized)
        logger.log("Initial microphone permission: \(audioStatus.rawValue) (authorized: \(microphoneAuthorized))")
        
        await checkScreenRecordingPermission()
    }
    
    @MainActor
    private func checkScreenRecordingPermission() async {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            screenRecordingAuthorized = true
            logger.log("Screen recording permission: granted")
        } catch {
            screenRecordingAuthorized = false
            logger.log("Screen recording permission: denied or not determined - \(error)")
        }
    }
    
    private func createTestModeDirectory() {
        logger.log("Creating test mode directory...")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss_EEEE"
        let folderName = formatter.string(from: Date())
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let testDirectory = documentsPath.appendingPathComponent("CaptureTests").appendingPathComponent(folderName)
        
        do {
            try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: testDirectory.appendingPathComponent("audio"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: testDirectory.appendingPathComponent("video"), withIntermediateDirectories: true)
            saveDirectory = testDirectory.path
            logger.log("Test directory created: \(saveDirectory!)")
        } catch {
            logger.logError("Failed to create test directory", error: error)
        }
    }
    
    private func setupIPC() async {
        logger.log("Setting up IPC communication...")
        
        inputHandler = FileHandle.standardInput
        inputHandler?.readabilityHandler = { [weak self] fileHandle in
            guard let self = self else { return }
            
            let data = fileHandle.availableData
            guard !data.isEmpty,
                  let commandString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !commandString.isEmpty else {
                return
            }
            
            logger.log("Received command: \(commandString)")
            Task {
                await self.handleCommand(commandString)
            }
        }
        
        logger.log("IPC setup complete, waiting for commands...")
    }
    
    private func handleCommand(_ command: String) async {
        logger.log("Processing command: \(command)")
        
        switch command {
        case "check_input_audio_access":
            await checkInputAudioAccess()
        case "check_screen_capture_access":
            await checkScreenCaptureAccess()
        case "start_capture_default":
            await startCaptureDefault()
        case "start_capture_all":
            await startCaptureAll()
        case "stop_stream":
            await stopAllStreams()
        case "pause_stream":
            await pauseAllStreams()
        default:
            logger.logError("Unknown command: \(command)")
            await sendErrorResponse(operation: "unknown", code: "UNKNOWN_COMMAND", message: "Unknown command: \(command)")
        }
    }
    
    private func checkInputAudioAccess() async {
        logger.log("Checking input audio access...")
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        
        switch status {
        case .notDetermined:
            logger.log("Audio permission not determined, requesting...")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphoneAuthorized = granted
            logger.log("Audio permission request result: \(granted)")
            await sendPermissionResponse(operation: "check_input_audio_access", type: "microphone", granted: granted)
        case .authorized:
            microphoneAuthorized = true
            logger.log("Audio permission already authorized")
            await sendPermissionResponse(operation: "check_input_audio_access", type: "microphone", granted: true)
        default:
            microphoneAuthorized = false
            logger.log("Audio permission denied or restricted")
            await sendPermissionResponse(operation: "check_input_audio_access", type: "microphone", granted: false)
        }
    }
    
    private func checkScreenCaptureAccess() async {
        logger.log("Checking screen capture access...")
        
        var granted = false
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            granted = true
            screenRecordingAuthorized = true
            logger.log("Screen capture permission check: granted")
        } catch {
            granted = false
            screenRecordingAuthorized = false
            logger.log("Screen capture permission check: denied - \(error)")
            
            if !screenRecordingAuthorized {
                logger.log("Prompting user to grant screen capture access...")
                CGRequestScreenCaptureAccess()
            }
        }
        
        await sendPermissionResponse(operation: "check_screen_capture_access", type: "screenCapture", granted: granted)
    }
    
    private func startCaptureDefault() async {
        logger.log("Starting default capture...")
        
        guard microphoneAuthorized else {
            logger.logError("Microphone permission not authorized")
            
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                if granted {
                    microphoneAuthorized = true
                    await startCaptureDefault()
                } else {
                    await sendErrorResponse(
                        operation: "start_capture_default",
                        code: "PERMISSION_DENIED",
                        message: "Microphone permission not granted",
                        details: "User denied microphone access"
                    )
                }
                return
            }
            
            await sendErrorResponse(
                operation: "start_capture_default",
                code: "PERMISSION_DENIED",
                message: "Microphone permission not granted",
                details: "Please grant microphone permission in System Preferences"
            )
            return
        }
        
        guard screenRecordingAuthorized else {
            logger.logError("Screen recording permission not authorized")
            await sendErrorResponse(
                operation: "start_capture_default",
                code: "PERMISSION_DENIED",
                message: "Screen recording permission not granted",
                details: "Please grant screen recording permission in System Preferences"
            )
            return
        }
        
        await captureDefaultDevices()
    }
    
    private func startCaptureAll() async {
        logger.log("Starting capture all...")
        
        guard microphoneAuthorized && screenRecordingAuthorized else {
            logger.logError("Permissions not granted - Audio: \(microphoneAuthorized), Screen: \(screenRecordingAuthorized)")
            await sendErrorResponse(
                operation: "start_capture_all",
                code: "PERMISSION_DENIED",
                message: "Required permissions not granted",
                details: "Audio: \(microphoneAuthorized ? "granted" : "denied"), Screen: \(screenRecordingAuthorized ? "granted" : "denied")"
            )
            return
        }
        
        await captureAllDevices()
    }
    
    private func captureDefaultDevices() async {
        logger.log("Capturing default devices...")
        var audioStreams: [StreamInfo] = []
        let videoStreams: [VideoStreamInfo] = []
        
        if let defaultInput = await getDefaultInputDevice() {
            logger.log("Found default input device: \(defaultInput.localizedName)")
            let streamId = UUID().uuidString
            if await startAudioCapture(device: defaultInput, streamId: streamId) {
                audioStreams.append(StreamInfo(
                    id: streamId,
                    name: defaultInput.localizedName,
                    deviceId: defaultInput.uniqueID,
                    isDefault: true,
                    type: "input",
                    status: "active",
                    filePath: isTestMode ? await getAudioFilePath(deviceName: "input_\(defaultInput.localizedName)") : nil
                ))
            }
        } else {
            logger.log("No AVCaptureDevice found, trying default audio engine...")
            let streamId = UUID().uuidString
            if await startDefaultAudioEngine(streamId: streamId) {
                audioStreams.append(StreamInfo(
                    id: streamId,
                    name: "Default Audio Input",
                    deviceId: "default",
                    isDefault: true,
                    type: "input",
                    status: "active",
                    filePath: isTestMode ? await getAudioFilePath(deviceName: "input_DefaultAudioInput") : nil
                ))
            }
        }
        
        if let systemAudioStream = await captureSystemAudio() {
            audioStreams.append(systemAudioStream)
        }
        
        await sendSuccessResponse(
            operation: "start_capture_default",
            audioStreams: audioStreams,
            videoStreams: videoStreams
        )
    }
    
    private func captureAllDevices() async {
        logger.log("Capturing all devices...")
        var audioStreams: [StreamInfo] = []
        var videoStreams: [VideoStreamInfo] = []
        
        listAllAudioDevices()
        
        let devices = await getAllAudioDevices()
        logger.log("AVCaptureDevice found \(devices.count) audio input devices")
        
        if devices.isEmpty {
            logger.log("No devices found via AVCaptureDevice, trying default audio engine...")
            let streamId = UUID().uuidString
            if await startDefaultAudioEngine(streamId: streamId) {
                audioStreams.append(StreamInfo(
                    id: streamId,
                    name: "Default Audio Input",
                    deviceId: "default",
                    isDefault: true,
                    type: "input",
                    status: "active",
                    filePath: isTestMode ? await getAudioFilePath(deviceName: "input_DefaultAudioInput") : nil
                ))
            }
        } else {
            for device in devices {
                logger.log("Processing device: \(device.localizedName)")
                let streamId = UUID().uuidString
                if await startAudioCapture(device: device, streamId: streamId) {
                    let defaultDevice = await getDefaultInputDevice()
                    audioStreams.append(StreamInfo(
                        id: streamId,
                        name: device.localizedName,
                        deviceId: device.uniqueID,
                        isDefault: device.uniqueID == defaultDevice?.uniqueID,
                        type: "input",
                        status: "active",
                        filePath: isTestMode ? await getAudioFilePath(deviceName: "input_\(device.localizedName)") : nil
                    ))
                }
            }
        }
        
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            logger.log("Found \(content.displays.count) displays and \(content.windows.count) windows")
            
            for (index, display) in content.displays.enumerated() {
                logger.log("Processing display \(index): \(display.width)x\(display.height)")
                let streamId = UUID().uuidString
                if let videoStream = await captureScreen(display: display, streamId: streamId, isPrimary: index == 0, content: content) {
                    videoStreams.append(videoStream)
                }
            }
            
            for window in content.windows {
                guard let title = window.title, !title.isEmpty else { continue }
                logger.log("Processing window: \(title)")
                let streamId = UUID().uuidString
                if let videoStream = await captureWindow(window: window, streamId: streamId) {
                    videoStreams.append(videoStream)
                }
            }
            
            if let systemAudioStream = await captureSystemAudio() {
                audioStreams.append(systemAudioStream)
            }
            
        } catch {
            logger.logError("Failed to get shareable content", error: error)
            await sendErrorResponse(
                operation: "start_capture_all",
                code: "CAPTURE_FAILED",
                message: "Failed to get shareable content",
                details: error.localizedDescription
            )
            return
        }
        
        await sendSuccessResponse(
            operation: "start_capture_all",
            audioStreams: audioStreams,
            videoStreams: videoStreams
        )
    }
    
    private func getDefaultInputDevice() async -> AVCaptureDevice? {
        guard microphoneAuthorized else {
            logger.log("Cannot get default device without microphone authorization")
            return nil
        }
        
        if let device = AVCaptureDevice.default(for: .audio) {
            logger.log("Found default device via AVCaptureDevice.default: \(device.localizedName)")
            return device
        }
        
        let devices = await getAllAudioDevices()
        
        if let firstDevice = devices.first {
            logger.log("Using first available device as default: \(firstDevice.localizedName)")
            return firstDevice
        }
        
        logger.logError("No audio input devices found")
        return nil
    }
    
    private func getAllAudioDevices() async -> [AVCaptureDevice] {
        guard microphoneAuthorized else {
            logger.log("Cannot enumerate devices without microphone authorization")
            return []
        }
        
        let deviceTypes = getAllAudioDeviceTypes()
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        
        let devices = discoverySession.devices
        logger.log("Discovery session found \(devices.count) devices")
        
        for device in devices {
            logger.log("  Device: \(device.localizedName) (ID: \(device.uniqueID))")
        }
        
        return devices
    }
    
    private func getAllAudioDeviceTypes() -> [AVCaptureDevice.DeviceType] {
        if #available(macOS 14.0, *) {
            return [.microphone, .external]
        } else {
            return [.builtInMicrophone, .external]
        }
    }
    
    private func listAllAudioDevices() {
        logger.log("Listing all Core Audio devices...")
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        
        if status != noErr {
            logger.logError("Failed to get audio devices size, status: \(status)")
            return
        }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var audioDevices = [AudioDeviceID](repeating: 0, count: deviceCount)
        
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &audioDevices
        )
        
        if status != noErr {
            logger.logError("Failed to get audio devices, status: \(status)")
            return
        }
        
        logger.log("Core Audio found \(deviceCount) total audio devices")
        
        for deviceID in audioDevices {
            var namePropertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            var deviceName: CFString?
            dataSize = UInt32(MemoryLayout<CFString?>.size)
            
            withUnsafeMutablePointer(to: &deviceName) { ptr in
                status = AudioObjectGetPropertyData(
                    deviceID,
                    &namePropertyAddress,
                    0,
                    nil,
                    &dataSize,
                    ptr
                )
            }
            
            if status == noErr, let deviceName = deviceName {
                let name = deviceName as String
                
                var inputPropertyAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyStreamConfiguration,
                    mScope: kAudioDevicePropertyScopeInput,
                    mElement: kAudioObjectPropertyElementMain
                )
                
                status = AudioObjectGetPropertyDataSize(
                    deviceID,
                    &inputPropertyAddress,
                    0,
                    nil,
                    &dataSize
                )
                
                if status == noErr && dataSize > 0 {
                    logger.log("  Input Device: \(name) (ID: \(deviceID))")
                }
            }
        }
    }
    
    func startAudioCapture(device: AVCaptureDevice, streamId: String) async -> Bool {
        logger.log("Starting audio capture for device: \(device.localizedName)")
        let result = startAudioCaptureSync(device: device, streamId: streamId)
        return result
    }
    
    private func startAudioCaptureSync(device: AVCaptureDevice, streamId: String) -> Bool {
        let engine = AVAudioEngine()
        
        do {
            guard let audioUnit = engine.inputNode.audioUnit else {
                logger.logError("Failed to get audio unit from engine")
                return false
            }
            
            var deviceID: AudioDeviceID = 0
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDeviceForUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            let deviceUID = device.uniqueID as CFString
            var uidString = deviceUID as NSString
            
            withUnsafeMutablePointer(to: &deviceID) { deviceIDPtr in
                withUnsafePointer(to: &uidString) { uidPtr in
                    var translation = AudioValueTranslation(
                        mInputData: UnsafeMutableRawPointer(mutating: uidPtr),
                        mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                        mOutputData: UnsafeMutableRawPointer(deviceIDPtr),
                        mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                    )
                    
                    var dataSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
                    let status = AudioObjectGetPropertyData(
                        AudioObjectID(kAudioObjectSystemObject),
                        &propertyAddress,
                        0,
                        nil,
                        &dataSize,
                        &translation
                    )
                    
                    if status == noErr {
                        deviceID = deviceIDPtr.pointee
                    }
                }
            }
            
            if deviceID != 0 {
                let propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
                let setStatus = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &deviceID,
                    propertySize
                )
                
                if setStatus != noErr {
                    logger.log("Warning: Failed to set specific audio device (status: \(setStatus)), using default")
                } else {
                    logger.log("Successfully set audio device ID: \(deviceID)")
                }
            } else {
                logger.log("Could not get Core Audio device ID for \(device.uniqueID), using default")
            }
            
            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            
            guard format.sampleRate > 0 && format.channelCount > 0 else {
                logger.logError("Invalid audio format: \(format)")
                return false
            }
            
            logger.log("Audio format: \(format.sampleRate) Hz, \(format.channelCount) channels")
            
            if isTestMode {
                guard let saveDirectory = saveDirectory else {
                    logger.logError("Save directory not set in test mode")
                    return false
                }
                let filePath = "\(saveDirectory)/audio/\(device.localizedName.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: " ", with: "_"))_\(Int(Date().timeIntervalSince1970)).wav"
                let fileURL = URL(fileURLWithPath: filePath)
                
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
                
                let audioFile = try AVAudioFile(forWriting: fileURL, settings: settings)
                audioFiles[streamId] = audioFile
                
                logger.log("Audio file created: \(filePath)")
                
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                    Task {
                        do {
                            try await self.audioFiles[streamId]?.write(from: buffer)
                        } catch {
                            await self.logger.logError("Failed to write audio buffer", error: error)
                        }
                    }
                }
            } else {
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in
                    // Just monitoring, not saving
                }
            }
            
            try engine.start()
            audioEngines[streamId] = engine
            activeStreams[streamId] = engine
            
            logger.log("Audio engine started successfully for device: \(device.localizedName)")
            return true
        } catch {
            logger.logError("Failed to start audio capture for device: \(device.localizedName)", error: error)
            return false
        }
    }
    
    private func startDefaultAudioEngine(streamId: String) async -> Bool {
        logger.log("Starting default audio engine...")
        
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        
        do {
            let format = inputNode.outputFormat(forBus: 0)
            
            guard format.sampleRate > 0 && format.channelCount > 0 else {
                logger.logError("Invalid default audio format")
                return false
            }
            
            logger.log("Default audio format: \(format.sampleRate) Hz, \(format.channelCount) channels")
            
            if isTestMode {
                guard let saveDirectory = saveDirectory else {
                    logger.logError("Save directory not set in test mode")
                    return false
                }
                let filePath = "\(saveDirectory)/audio/DefaultAudioInput_\(Int(Date().timeIntervalSince1970)).wav"
                let fileURL = URL(fileURLWithPath: filePath)
                
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
                
                let audioFile = try AVAudioFile(forWriting: fileURL, settings: settings)
                audioFiles[streamId] = audioFile
                
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                    Task {
                        do {
                            try await self.audioFiles[streamId]?.write(from: buffer)
                        } catch {
                            await self.logger.logError("Failed to write audio buffer", error: error)
                        }
                    }
                }
            }
            
            try engine.start()
            audioEngines[streamId] = engine
            activeStreams[streamId] = engine
            
            logger.log("Default audio engine started successfully")
            return true
        } catch {
            logger.logError("Failed to start default audio engine", error: error)
            return false
        }
    }
    
    private func captureSystemAudio() async -> StreamInfo? {
        logger.log("Starting system audio capture...")
        let streamId = UUID().uuidString
        
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                logger.logError("No display found for system audio capture")
                return nil
            }
            
            let excludedApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            
            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.showsCursor = false
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48000
            configuration.channelCount = 2
            
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            
            if isTestMode {
                guard let saveDirectory = saveDirectory else {
                    logger.logError("Save directory not set in test mode")
                    return nil
                }
                let audioFilePath = "\(saveDirectory)/audio/system_SystemAudio_\(Int(Date().timeIntervalSince1970)).wav"
                await setupSystemAudioRecording(stream: stream, filePath: audioFilePath)
            }
            
            do {
                try await stream.startCapture()
                screenStreams[streamId] = stream
                activeStreams[streamId] = stream
                
                logger.log("System audio capture started successfully")
                
                return StreamInfo(
                    id: streamId,
                    name: "System Audio",
                    deviceId: nil,
                    isDefault: false,
                    type: "system",
                    status: "active",
                    filePath: isTestMode ? await getAudioFilePath(deviceName: "system_SystemAudio") : nil
                )
            } catch {
                logger.logError("Failed to start system audio capture", error: error)
                return nil
            }
        } catch {
            logger.logError("Failed to setup system audio capture", error: error)
            return nil
        }
    }
    
    private func captureScreen(display: SCDisplay, streamId: String, isPrimary: Bool, content: SCShareableContent) async -> VideoStreamInfo? {
        logger.log("Capturing screen: \(display.displayID), primary: \(isPrimary)")
        
        let excludedApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        
        return await captureContent(
            filter: filter,
            streamId: streamId,
            name: isPrimary ? "Main Display" : "Display \(display.displayID)",
            type: "screen",
            isPrimary: isPrimary
        )
    }
    
    private func captureWindow(window: SCWindow, streamId: String) async -> VideoStreamInfo? {
        logger.log("Capturing window: \(window.title ?? "Untitled")")
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return await captureContent(
            filter: filter,
            streamId: streamId,
            name: window.title ?? "Untitled Window",
            type: "window",
            isPrimary: false
        )
    }
    
    private func captureContent(filter: SCContentFilter, streamId: String, name: String, type: String, isPrimary: Bool) async -> VideoStreamInfo? {
        logger.log("Setting up content capture: \(name)")
        
        let configuration = SCStreamConfiguration()
        configuration.width = 1920
        configuration.height = 1080
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        
        var filePaths: VideoStreamInfo.FilePaths?
        if isTestMode {
            guard let saveDirectory = saveDirectory else {
                logger.logError("Save directory not set in test mode")
                return nil
            }
            filePaths = VideoStreamInfo.FilePaths(
                combined: await getVideoFilePath(type: "combined", name: name),
                video: await getVideoFilePath(type: "video", name: name),
                audio: await getVideoFilePath(type: "audio", name: name)
            )
            await setupVideoRecording(stream: stream, filePaths: filePaths!)
        }
        
        do {
            try await stream.startCapture()
            screenStreams[streamId] = stream
            activeStreams[streamId] = stream
            
            logger.log("Content capture started successfully: \(name)")
            
            return VideoStreamInfo(
                id: streamId,
                name: name,
                type: type,
                isPrimary: isPrimary,
                status: "active",
                filePaths: filePaths
            )
        } catch {
            logger.logError("Failed to start capture: \(name)", error: error)
            return nil
        }
    }
    
    private func setupSystemAudioRecording(stream: SCStream, filePath: String) async {
        logger.log("Setting up system audio recording: \(filePath)")
        
        do {
            streamToPathMapping[stream] = filePath
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
            
            let fileURL = URL(fileURLWithPath: filePath)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            
            let audioFile = try AVAudioFile(forWriting: fileURL, settings: settings)
            audioFiles[filePath] = audioFile
            
            logger.log("System audio recording setup complete")
        } catch {
            logger.logError("Failed to setup system audio recording", error: error)
        }
    }
    
    private func setupVideoRecording(stream: SCStream, filePaths: VideoStreamInfo.FilePaths) async {
        logger.log("Setting up video recording...")
        
        do {
            if let combinedPath = filePaths.combined {
                streamToPathMapping[stream] = combinedPath
            }
            
            if let combinedPath = filePaths.combined {
                let combinedURL = URL(fileURLWithPath: combinedPath)
                let combinedWriter = try AVAssetWriter(outputURL: combinedURL, fileType: .mp4)
                
                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: 1920,
                    AVVideoHeightKey: 1080
                ]
                let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                videoInput.expectsMediaDataInRealTime = true
                
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 2
                ]
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioInput.expectsMediaDataInRealTime = true
                
                combinedWriter.add(videoInput)
                combinedWriter.add(audioInput)
                
                videoWriters[combinedPath] = combinedWriter
                
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
                
                logger.log("Combined video/audio writer setup complete")
            }
            
            if let videoPath = filePaths.video {
                let videoURL = URL(fileURLWithPath: videoPath)
                let videoWriter = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
                
                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: 1920,
                    AVVideoHeightKey: 1080
                ]
                let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                videoInput.expectsMediaDataInRealTime = true
                
                videoWriter.add(videoInput)
                videoWriters[videoPath] = videoWriter
                
                logger.log("Video-only writer setup complete")
            }
            
            if let audioPath = filePaths.audio {
                let audioURL = URL(fileURLWithPath: audioPath)
                
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 2
                ]
                
                let audioFile = try AVAudioFile(forWriting: audioURL, settings: settings)
                audioFiles[audioPath] = audioFile
                
                logger.log("Audio-only file setup complete")
            }
            
            for (path, writer) in videoWriters {
                writer.startWriting()
                writer.startSession(atSourceTime: CMTime.zero)
                logger.log("Started writer for: \(path)")
            }
            
        } catch {
            logger.logError("Failed to setup video recording", error: error)
        }
    }
    
    private func stopAllStreams() async {
        logger.log("Stopping all streams...")
        
        for (streamId, engine) in audioEngines {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            logger.log("Stopped audio engine: \(streamId)")
        }
        
        for (streamId, stream) in screenStreams {
            do {
                try await stream.stopCapture()
                logger.log("Stopped screen stream: \(streamId)")
            } catch {
                logger.logError("Error stopping stream \(streamId)", error: error)
            }
        }
        
        for (path, _) in audioFiles {
            logger.log("Closed audio file: \(path)")
        }
        audioFiles.removeAll()
        
        for (path, writer) in videoWriters {
            await writer.finishWriting {
                await self.logger.log("Finished writing video: \(path)")
            }
        }
        
        audioEngines.removeAll()
        screenStreams.removeAll()
        videoWriters.removeAll()
        activeStreams.removeAll()
        streamToPathMapping.removeAll()
        
        logger.log("All streams stopped")
        
        await sendResponse(CaptureResponse(
            type: "success",
            operation: "stop_stream",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            success: true,
            message: "All streams stopped successfully",
            error: nil,
            data: nil
        ))
    }
    
    private func pauseAllStreams() async {
        logger.log("Pausing all streams...")
        
        for (streamId, engine) in audioEngines {
            engine.pause()
            logger.log("Paused audio engine: \(streamId)")
        }
        
        logger.log("All streams paused")
        
        await sendResponse(CaptureResponse(
            type: "success",
            operation: "pause_stream",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            success: true,
            message: "All streams paused successfully",
            error: nil,
            data: nil
        ))
    }
    
    private func getAudioFilePath(deviceName: String) async -> String {
        guard let saveDirectory = saveDirectory else {
            logger.logError("Save directory not set in test mode")
            return ""
        }
        let timestamp = Date().timeIntervalSince1970
        let sanitizedName = deviceName.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "\(saveDirectory)/audio/\(sanitizedName)_\(Int(timestamp)).wav"
    }
    
    private func getVideoFilePath(type: String, name: String) async -> String {
        guard let saveDirectory = saveDirectory else {
            logger.logError("Save directory not set in test mode")
            return ""
        }
        let timestamp = Date().timeIntervalSince1970
        let sanitizedName = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let fileExtension = type == "audio" ? "m4a" : "mp4"
        return "\(saveDirectory)/video/\(type)_\(sanitizedName)_\(Int(timestamp)).\(fileExtension)"
    }
    
    private func sendPermissionResponse(operation: String, type: String, granted: Bool) async {
        let response = CaptureResponse(
            type: granted ? "success" : "error",
            operation: operation,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            success: granted,
            message: granted ? "\(type) permission granted" : "\(type) permission denied",
            error: granted ? nil : CaptureResponse.ErrorInfo(
                code: "PERMISSION_DENIED",
                message: "\(type) permission not granted",
                details: "User needs to grant permission in System Preferences"
            ),
            data: nil
        )
        await sendResponse(response)
    }
    
    private func sendSuccessResponse(operation: String, audioStreams: [StreamInfo], videoStreams: [VideoStreamInfo]) async {
        let totalStreams = audioStreams.count + videoStreams.count
        let permissions = CaptureResponse.ResponseData.Metadata.Permissions(
            microphone: microphoneAuthorized ? "granted" : "denied",
            screenCapture: screenRecordingAuthorized ? "granted" : "denied"
        )
        
        let response = CaptureResponse(
            type: "success",
            operation: operation,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            success: true,
            message: "Capture started successfully",
            error: nil,
            data: CaptureResponse.ResponseData(
                streams: CaptureResponse.ResponseData.StreamsInfo(
                    audio: audioStreams,
                    video: videoStreams
                ),
                metadata: CaptureResponse.ResponseData.Metadata(
                    totalStreams: totalStreams,
                    activeStreams: totalStreams,
                    testMode: isTestMode,
                    saveDirectory: saveDirectory,
                    permissions: permissions
                )
            )
        )
        await sendResponse(response)
    }
    
    private func sendErrorResponse(operation: String, code: String, message: String, details: String = "") async {
        let response = CaptureResponse(
            type: "error",
            operation: operation,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            success: false,
            message: message,
            error: CaptureResponse.ErrorInfo(
                code: code,
                message: message,
                details: details
            ),
            data: nil
        )
        await sendResponse(response)
    }
    
    private func sendResponse(_ response: CaptureResponse) async {
        do {
            let jsonData = try JSONEncoder().encode(response)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                logger.log("Sending response: \(jsonString)")
                print(jsonString)
                fflush(stdout)
            }
        } catch {
            logger.logError("Failed to encode response", error: error)
            print("{\"type\":\"error\",\"message\":\"Failed to encode response\"}")
            fflush(stdout)
        }
    }
}

// MARK: - SCStream Extensions

// Replace lines 689–767
extension AudioVideoCaptureProcess: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task {
            await logger.logError("Stream stopped with error", error: error)
            
            if error.localizedDescription.contains("interrupted") {
                await logger.log("Stream was interrupted, attempting to recover...")
            }
        }
    }
}

extension AudioVideoCaptureProcess: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        Task {
            guard await isTestMode else { return }
            
            switch outputType {
            case .screen:
                await handleVideoSampleBuffer(sampleBuffer, from: stream)
            case .audio:
                await handleAudioSampleBuffer(sampleBuffer, from: stream)
            case .microphone:
                await handleAudioSampleBuffer(sampleBuffer, from: stream)
            @unknown default:
                await logger.log("Unknown output type received")
            }
        }
    }
    
    private func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, from stream: SCStream) async {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        
        if let path = streamToPathMapping[stream],
           let writer = videoWriters[path],
           writer.status == .writing {
            
            if let videoInput = writer.inputs.first(where: { $0.mediaType == .video }),
               videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }
        }
    }
    
    private func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, from stream: SCStream) async {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        
        if let pcmBuffer = await convertToPCMBuffer(sampleBuffer) {
            if let path = streamToPathMapping[stream],
               let audioFile = audioFiles[path] {
                do {
                    try audioFile.write(from: pcmBuffer)
                } catch {
                    await logger.logError("Failed to write audio buffer", error: error)
                }
            }
        }
        
        if let path = streamToPathMapping[stream],
           let writer = videoWriters[path],
           writer.status == .writing {
            
            if let audioInput = writer.inputs.first(where: { $0.mediaType == .audio }),
               audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }
        }
    }
    
    private func convertToPCMBuffer(_ sampleBuffer: CMSampleBuffer) async -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: asbd.pointee.mSampleRate,
            channels: asbd.pointee.mChannelsPerFrame
        ) else {
            return nil
        }
        
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return nil
        }
        
        buffer.frameLength = AVAudioFrameCount(frameCount)
        
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        
        if status == noErr {
            return buffer
        } else {
            await logger.log("Failed to copy PCM data, status: \(status)")
            return nil
        }
    }
}

// MARK: - Main Entry Point

let captureProcess = AudioVideoCaptureProcess.shared
FileLogger.shared.log("Starting main run loop...")
RunLoop.main.run()