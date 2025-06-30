import Foundation
@preconcurrency import AVFoundation
import ScreenCaptureKit
import CoreGraphics
import CoreAudio

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

class AudioVideoCaptureProcess: NSObject {
    static let shared = AudioVideoCaptureProcess()
    
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
    
    override init() {
        super.init()
        
        // Setup signal handlers for graceful shutdown
        signal(SIGINT) { _ in exit(0) }
        signal(SIGTERM) { _ in exit(0) }
        
        processCommandLineArguments()
        checkInitialPermissions()
        setupIPC()
    }
    
    private func processCommandLineArguments() {
        let arguments = CommandLine.arguments
        if arguments.contains("--testmode") {
            isTestMode = true
            createTestModeDirectory()
        }
    }
    
    private func checkInitialPermissions() {
        // Check microphone permission
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneAuthorized = (audioStatus == .authorized)
        
        // Check screen recording permission
        Task { await checkScreenRecordingPermission() }
    }
    
    @MainActor
    private func checkScreenRecordingPermission() async {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            screenRecordingAuthorized = true
        } catch {
            screenRecordingAuthorized = false
        }
    }
    
    private func createTestModeDirectory() {
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
        } catch { }
    }
    
    // MARK: - IPC Setup
    
    private func setupIPC() {
        inputHandler = FileHandle.standardInput
        inputHandler?.readabilityHandler = { [weak self] fileHandle in
            guard let self = self else { return }
            
            let data = fileHandle.availableData
            guard !data.isEmpty,
                  let commandString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !commandString.isEmpty else {
                return
            }
            
            self.handleCommand(commandString)
        }
    }
    
    private func handleCommand(_ command: String) {
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            
            switch command {
            case "check_input_audio_access":
                self.checkInputAudioAccess()
            case "check_screen_capture_access":
                self.checkScreenCaptureAccess()
            case "start_capture_default":
                self.startCaptureDefault()
            case "start_capture_all":
                self.startCaptureAll()
            case "stop_stream":
                self.stopAllStreams()
            case "pause_stream":
                self.pauseAllStreams()
            default:
                self.sendErrorResponse(operation: "unknown", code: "UNKNOWN_COMMAND", message: "Unknown command: \(command)")
            }
        }
    }
    
    // MARK: - Permission Checking
    
    private func checkInputAudioAccess() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        
        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                self?.microphoneAuthorized = granted
                self?.sendPermissionResponse(operation: "check_input_audio_access", type: "microphone", granted: granted)
            }
        case .authorized:
            microphoneAuthorized = true
            sendPermissionResponse(operation: "check_input_audio_access", type: "microphone", granted: true)
        default:
            microphoneAuthorized = false
            sendPermissionResponse(operation: "check_input_audio_access", type: "microphone", granted: false)
        }
    }
    
    private func checkScreenCaptureAccess() {
        Task {
            var granted = false
            
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                granted = true
                self.screenRecordingAuthorized = true
            } catch {
                granted = false
                self.screenRecordingAuthorized = false
                CGRequestScreenCaptureAccess()
            }
            
            self.sendPermissionResponse(operation: "check_screen_capture_access", type: "screenCapture", granted: granted)
        }
    }
    
    // MARK: - Capture Operations
    
    private func startCaptureDefault() {
        guard microphoneAuthorized else {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    if granted {
                        self?.microphoneAuthorized = true
                        self?.startCaptureDefault()
                    } else {
                        self?.sendErrorResponse(
                            operation: "start_capture_default",
                            code: "PERMISSION_DENIED",
                            message: "Microphone permission not granted",
                            details: "User denied microphone access"
                        )
                    }
                }
                return
            }
            
            sendErrorResponse(
                operation: "start_capture_default",
                code: "PERMISSION_DENIED",
                message: "Microphone permission not granted",
                details: "Please grant microphone permission in System Preferences"
            )
            return
        }
        
        guard screenRecordingAuthorized else {
            sendErrorResponse(
                operation: "start_capture_default",
                code: "PERMISSION_DENIED",
                message: "Screen recording permission not granted",
                details: "Please grant screen recording permission in System Preferences"
            )
            return
        }
        
        Task { await captureDefaultDevices() }
    }
    
    private func startCaptureAll() {
        guard microphoneAuthorized && screenRecordingAuthorized else {
            sendErrorResponse(
                operation: "start_capture_all",
                code: "PERMISSION_DENIED",
                message: "Required permissions not granted",
                details: "Audio: \(microphoneAuthorized ? "granted" : "denied"), Screen: \(screenRecordingAuthorized ? "granted" : "denied")"
            )
            return
        }
        
        Task { await captureAllDevices() }
    }
    
    private func captureDefaultDevices() async {
        var audioStreams: [StreamInfo] = []
        let videoStreams: [VideoStreamInfo] = []
        
        if let defaultInput = await getDefaultInputDevice() {
            let streamId = UUID().uuidString
            if await startAudioCapture(device: defaultInput, streamId: streamId) {
                audioStreams.append(StreamInfo(
                    id: streamId,
                    name: defaultInput.localizedName,
                    deviceId: defaultInput.uniqueID,
                    isDefault: true,
                    type: "input",
                    status: "active",
                    filePath: isTestMode ? getAudioFilePath(deviceName: "input_\(defaultInput.localizedName)") : nil
                ))
            }
        } else {
            let streamId = UUID().uuidString
            if startDefaultAudioEngine(streamId: streamId) {
                audioStreams.append(StreamInfo(
                    id: streamId,
                    name: "Default Audio Input",
                    deviceId: "default",
                    isDefault: true,
                    type: "input",
                    status: "active",
                    filePath: isTestMode ? getAudioFilePath(deviceName: "input_DefaultAudioInput") : nil
                ))
            }
        }
        
        sendSuccessResponse(
            operation: "start_capture_default",
            audioStreams: audioStreams,
            videoStreams: videoStreams
        )
    }
    
    private func captureAllDevices() async {
        var audioStreams: [StreamInfo] = []
        var videoStreams: [VideoStreamInfo] = []
        
        let devices = await getAllAudioDevices()
        
        if devices.isEmpty {
            let streamId = UUID().uuidString
            if start

DefaultAudioEngine(streamId: streamId) {
                audioStreams.append(StreamInfo(
                    id: streamId,
                    name: "Default Audio Input",
                    deviceId: "default",
                    isDefault: true,
                    type: "input",
                    status: "active",
                    filePath: isTestMode ? getAudioFilePath(deviceName: "input_DefaultAudioInput") : nil
                ))
            }
        } else {
            for device in devices {
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
                        filePath: isTestMode ? getAudioFilePath(deviceName: "input_\(device.localizedName)") : nil
                    ))
                }
            }
        }
        
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            
            for (index, display) in content.displays.enumerated() {
                let streamId = UUID().uuidString
                if let videoStream = await captureScreen(display: display, streamId: streamId, isPrimary: index == 0, content: content) {
                    videoStreams.append(videoStream)
                }
            }
            
            for window in content.windows {
                guard let title = window.title, !title.isEmpty else { continue }
                let streamId = UUID().uuidString
                if let videoStream = await captureWindow(window: window, streamId: streamId) {
                    videoStreams.append(videoStream)
                }
            }
            
        } catch {
            sendErrorResponse(
                operation: "start_capture_all",
                code: "CAPTURE_FAILED",
                message: "Failed to get shareable content",
                details: error.localizedDescription
            )
            return
        }
        
        sendSuccessResponse(
            operation: "start_capture_all",
            audioStreams: audioStreams,
            videoStreams: videoStreams
        )
    }
    
    // MARK: - Audio Capture
    
    private func getDefaultInputDevice() async -> AVCaptureDevice? {
        guard microphoneAuthorized else { return nil }
        
        if let device = AVCaptureDevice.default(for: .audio) {
            return device
        }
        
        let devices = await getAllAudioDevices()
        return devices.first
    }
    
    private func getAllAudioDevices() async -> [AVCaptureDevice] {
        guard microphoneAuthorized else { return [] }
        
        let deviceTypes = getAllAudioDeviceTypes()
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        
        return discoverySession.devices
    }
    
    private func getAllAudioDeviceTypes() -> [AVCaptureDevice.DeviceType] {
        if #available(macOS 14.0, *) {
            return [.microphone, .external]
        } else {
            return [.builtInMicrophone, .external]
        }
    }
    
    private func startAudioCapture(device: AVCaptureDevice, streamId: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: false)
                    return
                }
                
                let result = self.startAudioCaptureSync(device: device, streamId: streamId)
                continuation.resume(returning: result)
            }
        }
    }
    
    private func startAudioCaptureSync(device: AVCaptureDevice, streamId: String) -> Bool {
        let engine = AVAudioEngine()
        
        do {
            guard let audioUnit = engine.inputNode.audioUnit else { return false }
            
            var deviceID: AudioDeviceID = 0
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDeviceForUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            let deviceUID = device.uniqueID as CFString
            var uidString = deviceUID as NSString
            var localDeviceID = deviceID
            
            withUnsafeMutablePointer(to: &localDeviceID) { deviceIDPtr in
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
                        deviceID = localDeviceID
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
                
                if setStatus != noErr { }
            }
            
            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            
            guard format.sampleRate > 0 && format.channelCount > 0 else { return false }
            
            if isTestMode {
                let filePath = getAudioFilePath(deviceName: device.localizedName)
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
                
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                    do {
                        try self?.audioFiles[streamId]?.write(from: buffer)
                    } catch { }
                }
            } else {
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in }
            }
            
            try engine.start()
            audioEngines[streamId] = engine
            activeStreams[streamId] = engine
            
            return true
        } catch {
            return false
        }
    }
    
    private func startDefaultAudioEngine(streamId: String) -> Bool {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        
        do {
            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0 && format.channelCount > 0 else { return false }
            
            if isTestMode {
                let filePath = getAudioFilePath(deviceName: "DefaultAudioInput")
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
                
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                    do {
                        try self?.audioFiles[streamId]?.write(from: buffer)
                    } catch { }
                }
            }
            
            try engine.start()
            audioEngines[streamId] = engine
            activeStreams[streamId] = engine
            
            return true
        } catch {
            return false
        }
    }
    
    // MARK: - Video Capture
    
    private func captureScreen(display: SCDisplay, streamId: String, isPrimary: Bool, content: SCShareableContent) async -> VideoStreamInfo? {
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
            filePaths = VideoStreamInfo.FilePaths(
                combined: getVideoFilePath(type: "combined", name: name),
                video: getVideoFilePath(type: "video", name: name),
                audio: getVideoFilePath(type: "audio", name: name)
            )
            setupVideoRecording(stream: stream, filePaths: filePaths!)
        }
        
        do {
            try await stream.startCapture()
            screenStreams[streamId] = stream
            activeStreams[streamId] = stream
            
            return VideoStreamInfo(
                id: streamId,
                name: name,
                type: type,
                isPrimary: isPrimary,
                status: "active",
                filePaths: filePaths
            )
        } catch {
            return nil
        }
    }
    
    // MARK: - Recording Setup
    
    private func setupVideoRecording(stream: SCStream, filePaths: VideoStreamInfo.FilePaths) {
        do {
            if let combinedPath = filePaths.combined {
                streamToPathMapping[stream] = combinedPath
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
            }
            
            for (path, writer) in videoWriters {
                writer.startWriting()
                writer.startSession(atSourceTime: CMTime.zero)
            }
            
        } catch { }
    }
    
    // MARK: - Stream Control
    
    private func stopAllStreams() {
        for (streamId, engine) in audioEngines {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        
        for (streamId, stream) in screenStreams {
            Task {
                do {
                    try await stream.stopCapture()
                } catch { }
            }
        }
        
        audioFiles.removeAll()
        
        for (path, writer) in videoWriters {
            writer.finishWriting { }
        }
        
        audioEngines.removeAll()
        screenStreams.removeAll()
        videoWriters.removeAll()
        activeStreams.removeAll()
        streamToPathMapping.removeAll()
        
        sendResponse(CaptureResponse(
            type: "success",
            operation: "stop_stream",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            success: true,
            message: "All streams stopped successfully",
            error: nil,
            data: nil
        ))
    }
    
    private func pauseAllStreams() {
        for (streamId, engine) in audioEngines {
            engine.pause()
        }
        
        sendResponse(CaptureResponse(
            type: "success",
            operation: "pause_stream",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            success: true,
            message: "All streams paused successfully",
            error: nil,
            data: nil
        ))
    }
    
    // MARK: - Helper Methods
    
    private func getAudioFilePath(deviceName: String) -> String {
        let timestamp = Date().timeIntervalSince1970
        let sanitizedName = deviceName.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "\(saveDirectory!)/audio/\(sanitizedName)_\(Int(timestamp)).wav"
    }
    
    private func getVideoFilePath(type: String, name: String) -> String {
        let timestamp = Date().timeIntervalSince1970
        let sanitizedName = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let fileExtension = type == "audio" ? "m4a" : "mp4"
        return "\(saveDirectory!)/video/\(type)_\(sanitizedName)_\(Int(timestamp)).\(fileExtension)"
    }
    
    // MARK: - Response Handling
    
    private func sendPermissionResponse(operation: String, type: String, granted: Bool) {
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
        sendResponse(response)
    }
    
    private func sendSuccessResponse(operation: String, audioStreams: [StreamInfo], videoStreams: [VideoStreamInfo]) {
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
        sendResponse(response)
    }
    
    private func sendErrorResponse(operation: String, code: String, message: String, details: String = "") {
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
        sendResponse(response)
    }
    
    private func sendResponse(_ response: CaptureResponse) {
        do {
            let jsonData = try JSONEncoder().encode(response)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                print(jsonString)
                fflush(stdout)
            }
        } catch {
            print("{\"type\":\"error\",\"message\":\"Failed to encode response\"}")
            fflush(stdout)
        }
    }
}

// MARK: - SCStream Extensions

extension AudioVideoCaptureProcess: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) { }
}

extension AudioVideoCaptureProcess: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard isTestMode else { return }
        
        switch outputType {
        case .screen:
            handleVideoSampleBuffer(sampleBuffer, from: stream)
        case .audio:
            handleAudioSampleBuffer(sampleBuffer, from: stream)
        case .microphone:
            handleAudioSampleBuffer(sampleBuffer, from: stream)
        @unknown default:
            break
        }
    }
    
    private func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, from stream: SCStream) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        
        if let path = streamToPathMapping[stream],
           let writer = videoWriters[path],
           writer.status == .writing,
           let videoInput = writer.inputs.first(where: { $0.mediaType == .video }),
           videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        }
    }
    
    private func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, from stream: SCStream) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        
        if let pcmBuffer = convertToPCMBuffer(sampleBuffer),
           let path = streamToPathMapping[stream],
           let audioFile = audioFiles[path] {
            do {
                try audioFile.write(from: pcmBuffer)
            } catch { }
        }
        
        if let path = streamToPathMapping[stream],
           let writer = videoWriters[path],
           writer.status == .writing,
           let audioInput = writer.inputs.first(where: { $0.mediaType == .audio }),
           audioInput.isReadyForMoreMediaData {
            audioInput.append(sampleBuffer)
        }
    }
    
    private func convertToPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
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
        
        return status == noErr ? buffer : nil
    }
}

// MARK: - Main Entry Point

let captureProcess = AudioVideoCaptureProcess.shared
RunLoop.main.run()