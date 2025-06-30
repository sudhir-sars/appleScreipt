import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics
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

class AudioVideoCaptureProcess: NSObject {
    static let shared = AudioVideoCaptureProcess()
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
    
    private let ipcQueue = DispatchQueue(label: "com.capture.ipc", qos: .userInteractive)
    private let captureQueue = DispatchQueue(label: "com.capture.main", qos: .userInitiated)
    
    private var inputHandler: FileHandle?
    
    override init() {
        super.init()
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
        
        processCommandLineArguments()
        checkInitialPermissions()
        setupIPC()
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
    
    private func checkInitialPermissions() {
        logger.log("Checking initial permissions...")
        
        // Check microphone permission
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        logger.log("Initial microphone permission: \(audioStatus.rawValue)")
        
        // Check screen recording permission
        if #available(macOS 11.0, *) {
            // For macOS 11.0+, we need to attempt to create content to check permission
            Task {
                do {
                    _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                    screenRecordingAuthorized = true
                    logger.log("Screen recording permission: granted")
                } catch {
                    screenRecordingAuthorized = false
                    logger.log("Screen recording permission: denied or not determined")
                }
            }
        } else {
            screenRecordingAuthorized = CGPreflightScreenCaptureAccess()
            logger.log("Screen recording permission (legacy): \(screenRecordingAuthorized)")
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
    
    // MARK: - IPC Setup
    
    private func setupIPC() {
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
            
            self.logger.log("Received command: \(commandString)")
            self.handleCommand(commandString)
        }
        
        logger.log("IPC setup complete, waiting for commands...")
    }
    
    private func handleCommand(_ command: String) {
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.logger.log("Processing command: \(command)")
            
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
                self.logger.logError("Unknown command: \(command)")
                self.sendErrorResponse(operation: "unknown", code: "UNKNOWN_COMMAND", message: "Unknown command: \(command)")
            }
        }
    }
    
    // MARK: - Permission Checking
    
    private func checkInputAudioAccess() {
        logger.log("Checking input audio access...")
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        
        switch status {
        case .notDetermined:
            logger.log("Audio permission not determined, requesting...")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                self?.logger.log("Audio permission request result: \(granted)")
                self?.sendPermissionResponse(operation: "check_input_audio_access", type: "microphone", granted: granted)
            }
        case .authorized:
            logger.log("Audio permission already authorized")
            sendPermissionResponse(operation: "check_input_audio_access", type: "microphone", granted: true)
        default:
            logger.log("Audio permission denied or restricted")
            sendPermissionResponse(operation: "check_input_audio_access", type: "microphone", granted: false)
        }
    }
    
    private func checkScreenCaptureAccess() {
        logger.log("Checking screen capture access...")
        
        Task {
            var granted = false
            
            if #available(macOS 11.0, *) {
                do {
                    _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                    granted = true
                    logger.log("Screen capture permission check: granted")
                } catch {
                    granted = false
                    logger.log("Screen capture permission check: denied - \(error)")
                    
                    // Request access
                    if !screenRecordingAuthorized {
                        logger.log("Requesting screen capture access...")
                        CGRequestScreenCaptureAccess()
                    }
                }
            } else {
                granted = CGPreflightScreenCaptureAccess()
                if !granted {
                    logger.log("Requesting screen capture access (legacy)...")
                    granted = CGRequestScreenCaptureAccess()
                }
            }
            
            screenRecordingAuthorized = granted
            sendPermissionResponse(operation: "check_screen_capture_access", type: "screenCapture", granted: granted)
        }
    }
    
    // MARK: - Capture Operations
    
    private func startCaptureDefault() {
        logger.log("Starting default capture...")
        
        // First check permissions
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        
        guard audioStatus == .authorized else {
            logger.logError("Audio permission not authorized: \(audioStatus.rawValue)")
            sendErrorResponse(
                operation: "start_capture_default",
                code: "PERMISSION_DENIED",
                message: "Microphone permission not granted",
                details: "Audio permission status: \(audioStatus.rawValue)"
            )
            return
        }
        
        guard screenRecordingAuthorized else {
            logger.logError("Screen recording permission not authorized")
            sendErrorResponse(
                operation: "start_capture_default",
                code: "PERMISSION_DENIED",
                message: "Screen recording permission not granted",
                details: "Please grant screen recording permission in System Preferences"
            )
            return
        }
        
        Task {
            await captureDefaultDevices()
        }
    }
    
    private func startCaptureAll() {
        logger.log("Starting capture all...")
        
        // First check permissions
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        
        guard audioStatus == .authorized && screenRecordingAuthorized else {
            logger.logError("Permissions not granted - Audio: \(audioStatus == .authorized), Screen: \(screenRecordingAuthorized)")
            sendErrorResponse(
                operation: "start_capture_all",
                code: "PERMISSION_DENIED",
                message: "Required permissions not granted",
                details: "Audio: \(audioStatus == .authorized ? "granted" : "denied"), Screen: \(screenRecordingAuthorized ? "granted" : "denied")"
            )
            return
        }
        
        Task {
            await captureAllDevices()
        }
    }
    
    private func captureDefaultDevices() async {
        logger.log("Capturing default devices...")
        var audioStreams: [StreamInfo] = []
        let videoStreams: [VideoStreamInfo] = []
        
        // Capture default input device
        if let defaultInput = getDefaultInputDevice() {
            logger.log("Found default input device: \(defaultInput.localizedName)")
            let streamId = UUID().uuidString
            if startAudioCapture(device: defaultInput, streamId: streamId) {
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
            logger.logError("No default input device found")
        }
        
        // Capture system audio with minimal screen capture
        if let systemAudioStream = await captureSystemAudio() {
            audioStreams.append(systemAudioStream)
        }
        
        sendSuccessResponse(
            operation: "start_capture_default",
            audioStreams: audioStreams,
            videoStreams: videoStreams
        )
    }
    
    private func captureAllDevices() async {
        logger.log("Capturing all devices...")
        var audioStreams: [StreamInfo] = []
        var videoStreams: [VideoStreamInfo] = []
        
        // Capture all input devices
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.builtInMicrophone, .external]
        }
        
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        ).devices
        
        logger.log("Found \(devices.count) audio input devices")
        
        for device in devices {
            logger.log("Processing device: \(device.localizedName)")
            let streamId = UUID().uuidString
            if startAudioCapture(device: device, streamId: streamId) {
                audioStreams.append(StreamInfo(
                    id: streamId,
                    name: device.localizedName,
                    deviceId: device.uniqueID,
                    isDefault: device == getDefaultInputDevice(),
                    type: "input",
                    status: "active",
                    filePath: isTestMode ? getAudioFilePath(deviceName: "input_\(device.localizedName)") : nil
                ))
            }
        }
        
        // Capture all screens and windows
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            logger.log("Found \(content.displays.count) displays and \(content.windows.count) windows")
            
            // Capture screens
            for (index, display) in content.displays.enumerated() {
                logger.log("Processing display \(index): \(display.width)x\(display.height)")
                let streamId = UUID().uuidString
                if let videoStream = await captureScreen(display: display, streamId: streamId, isPrimary: index == 0, content: content) {
                    videoStreams.append(videoStream)
                }
            }
            
            // Capture windows
            for window in content.windows {
                guard let title = window.title, !title.isEmpty else { continue }
                logger.log("Processing window: \(title)")
                let streamId = UUID().uuidString
                if let videoStream = await captureWindow(window: window, streamId: streamId) {
                    videoStreams.append(videoStream)
                }
            }
            
            // Capture system audio
            if let systemAudioStream = await captureSystemAudio() {
                audioStreams.append(systemAudioStream)
            }
            
        } catch {
            logger.logError("Failed to get shareable content", error: error)
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
    
    private func getDefaultInputDevice() -> AVCaptureDevice? {
        return AVCaptureDevice.default(for: .audio)
    }
    
    private func startAudioCapture(device: AVCaptureDevice, streamId: String) -> Bool {
        logger.log("Starting audio capture for device: \(device.localizedName)")
        
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        
        do {
            // Configure format
            let format = inputNode.outputFormat(forBus: 0)
            
            if isTestMode {
                // Create audio file for saving
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
                
                logger.log("Audio file created: \(filePath)")
                
                // Install tap to save audio
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                    do {
                        try self?.audioFiles[streamId]?.write(from: buffer)
                    } catch {
                        self?.logger.logError("Failed to write audio buffer", error: error)
                    }
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
    
    private func captureSystemAudio() async -> StreamInfo? {
        logger.log("Starting system audio capture...")
        let streamId = UUID().uuidString
        
        do {
            // Create minimal screen capture for system audio
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                logger.logError("No display found for system audio capture")
                return nil
            }
            
            // Exclude current app to avoid feedback
            let excludedApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            
            let configuration = SCStreamConfiguration()
            
            // Minimal configuration for audio only
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.showsCursor = false
            configuration.capturesAudio = true
            configuration.sampleRate = 48000
            configuration.channelCount = 2
            
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            
            if isTestMode {
                let audioFilePath = getAudioFilePath(deviceName: "system_SystemAudio")
                setupSystemAudioRecording(stream: stream, filePath: audioFilePath)
            }
            
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
                filePath: isTestMode ? getAudioFilePath(deviceName: "system_SystemAudio") : nil
            )
        } catch {
            logger.logError("Failed to capture system audio", error: error)
            return nil
        }
    }
    
    // MARK: - Video Capture
    
    private func captureScreen(display: SCDisplay, streamId: String, isPrimary: Bool, content: SCShareableContent) async -> VideoStreamInfo? {
        logger.log("Capturing screen: \(display.displayID), primary: \(isPrimary)")
        
        // Exclude current app
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
    
    // MARK: - Recording Setup
    
    private func setupSystemAudioRecording(stream: SCStream, filePath: String) {
        logger.log("Setting up system audio recording: \(filePath)")
        
        do {
            // Map stream to file path
            streamToPathMapping[stream] = filePath
            
            // Add self as stream output delegate to receive audio samples
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
            
            // Create audio file for recording
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
    
    private func setupVideoRecording(stream: SCStream, filePaths: VideoStreamInfo.FilePaths) {
        logger.log("Setting up video recording...")
        
        do {
            // Map stream to file paths
            if let combinedPath = filePaths.combined {
                streamToPathMapping[stream] = combinedPath
            }
            
            // Setup combined stream (video + audio)
            if let combinedPath = filePaths.combined {
                let combinedURL = URL(fileURLWithPath: combinedPath)
                let combinedWriter = try AVAssetWriter(outputURL: combinedURL, fileType: .mp4)
                
                // Video input
                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: 1920,
                    AVVideoHeightKey: 1080
                ]
                let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                videoInput.expectsMediaDataInRealTime = true
                
                // Audio input
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
                
                // Add stream output for combined capture
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
                
                logger.log("Combined video/audio writer setup complete")
            }
            
            // Setup video-only stream
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
            
            // Setup audio-only stream
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
            
            // Start all writers
            for (path, writer) in videoWriters {
                writer.startWriting()
                writer.startSession(atSourceTime: CMTime.zero)
                logger.log("Started writer for: \(path)")
            }
            
        } catch {
            logger.logError("Failed to setup video recording", error: error)
        }
    }
    
    // MARK: - Stream Control
    
    private func stopAllStreams() {
        logger.log("Stopping all streams...")
        
        // Stop audio engines
        for (streamId, engine) in audioEngines {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            logger.log("Stopped audio engine: \(streamId)")
        }
        
        // Stop screen captures
        for (streamId, stream) in screenStreams {
            Task {
                do {
                    try await stream.stopCapture()
                    logger.log("Stopped screen stream: \(streamId)")
                } catch {
                    logger.logError("Error stopping stream \(streamId)", error: error)
                }
            }
        }
        
        // Close audio files
        for (path, _) in audioFiles {
            logger.log("Closed audio file: \(path)")
        }
        audioFiles.removeAll()
        
        // Finalize video writers
        for (path, writer) in videoWriters {
            writer.finishWriting {
                self.logger.log("Finished writing video: \(path)")
            }
        }
        
        // Clear all references
        audioEngines.removeAll()
        screenStreams.removeAll()
        videoWriters.removeAll()
        activeStreams.removeAll()
        streamToPathMapping.removeAll()
        
        logger.log("All streams stopped")
        
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
        logger.log("Pausing all streams...")
        
        // Pause audio engines
        for (streamId, engine) in audioEngines {
            engine.pause()
            logger.log("Paused audio engine: \(streamId)")
        }
        
        logger.log("All streams paused")
        
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
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "granted" : "denied",
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

extension AudioVideoCaptureProcess: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.logError("Stream stopped with error", error: error)
    }
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
            // Handle microphone input if needed
            handleAudioSampleBuffer(sampleBuffer, from: stream)
        @unknown default:
            break
        }
    }
    
    private func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, from stream: SCStream) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        
        // Find the appropriate video writer for this stream
        if let path = streamToPathMapping[stream],
           let writer = videoWriters[path],
           writer.status == .writing {
            
            // Find video input
            if let videoInput = writer.inputs.first(where: { $0.mediaType == .video }),
               videoInput.isReadyForMoreMediaData {
                
                // Append the sample buffer
                videoInput.append(sampleBuffer)
            }
        }
    }
    
    private func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, from stream: SCStream) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        
        // Convert CMSampleBuffer to PCM buffer for audio files
        if let pcmBuffer = convertToPCMBuffer(sampleBuffer) {
            // Write to audio file if we have a mapping
            if let path = streamToPathMapping[stream],
               let audioFile = audioFiles[path] {
                do {
                    try audioFile.write(from: pcmBuffer)
                } catch {
                    logger.logError("Failed to write audio buffer", error: error)
                }
            }
        }
        
        // Also handle audio for video writers
        if let path = streamToPathMapping[stream],
           let writer = videoWriters[path],
           writer.status == .writing {
            
            // Find audio input
            if let audioInput = writer.inputs.first(where: { $0.mediaType == .audio }),
               audioInput.isReadyForMoreMediaData {
                
                // Append the sample buffer
                audioInput.append(sampleBuffer)
            }
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
        
        // Copy audio data
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        
        if status == noErr {
            return buffer
        } else {
            logger.log("Failed to copy PCM data, status: \(status)")
            return nil
        }
    }
}

// MARK: - Main Entry Point

let captureProcess = AudioVideoCaptureProcess.shared
FileLogger.shared.log("Starting main run loop...")
RunLoop.main.run()