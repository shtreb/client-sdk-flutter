// Copyright 2025 LiveKit, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import WebRTC
import flutter_webrtc

#if os(macOS)
import Cocoa
import FlutterMacOS
#else
import Flutter
import UIKit
import Combine
#endif

@available(iOS 13.0, *)
public class LiveKitPlugin: NSObject, FlutterPlugin {

    var processors: Dictionary<String, Visualizer> = [:]
    var tracks: Dictionary<String, Track> = [:]

    var binaryMessenger: FlutterBinaryMessenger?

    #if os(iOS)
    var cancellable = Set<AnyCancellable>()
    var audioMixer: AudioMixerProcessor?
    var audioMixerTrackId: String?
    #endif

    public static func register(with registrar: FlutterPluginRegistrar) {

        #if os(macOS)
        let messenger = registrar.messenger
        #else
        let messenger = registrar.messenger()
        #endif

        let channel = FlutterMethodChannel(name: "livekit_client", binaryMessenger: messenger)
        let instance = LiveKitPlugin()
        instance.binaryMessenger = messenger
        registrar.addMethodCallDelegate(instance, channel: channel)

        #if os(iOS)
        BroadcastManager.shared.isBroadcastingPublisher
            .sink { isBroadcasting in
                channel.invokeMethod("broadcastStateChanged", arguments: isBroadcasting)
            }
            .store(in: &instance.cancellable)
        #endif
    }

    #if !os(macOS)
    // https://developer.apple.com/documentation/avfaudio/avaudiosession/category
    let categoryMap: [String: AVAudioSession.Category] = [
        "ambient": .ambient,
        "multiRoute": .multiRoute,
        "playAndRecord": .playAndRecord,
        "playback": .playback,
        "record": .record,
        "soloAmbient": .soloAmbient
    ]

    // https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions
    let categoryOptionsMap: [String: AVAudioSession.CategoryOptions] = [
        "mixWithOthers": .mixWithOthers,
        "duckOthers": .duckOthers,
        "interruptSpokenAudioAndMixWithOthers": .interruptSpokenAudioAndMixWithOthers,
        "allowBluetooth": .allowBluetooth,
        "allowBluetoothA2DP": .allowBluetoothA2DP,
        "allowAirPlay": .allowAirPlay,
        "defaultToSpeaker": .defaultToSpeaker
        //        @available(iOS 14.5, *)
        //        "overrideMutedMicrophoneInterruption": .overrideMutedMicrophoneInterruption,
    ]

    // https://developer.apple.com/documentation/avfaudio/avaudiosession/mode
    let modeMap: [String: AVAudioSession.Mode] = [
        "default": .default,
        "gameChat": .gameChat,
        "measurement": .measurement,
        "moviePlayback": .moviePlayback,
        "spokenAudio": .spokenAudio,
        "videoChat": .videoChat,
        "videoRecording": .videoRecording,
        "voiceChat": .voiceChat,
        "voicePrompt": .voicePrompt
    ]

    private func categoryOptions(fromFlutter options: [String]) -> AVAudioSession.CategoryOptions {
        var result: AVAudioSession.CategoryOptions = []
        for option in categoryOptionsMap {
            if options.contains(option.key) {
                result.insert(option.value)
            }
        }
        return result
    }
    #endif

    public func handleStartAudioVisualizer(args: [String: Any?], result: @escaping FlutterResult) {
        let webrtc = FlutterWebRTCPlugin.sharedSingleton()

        let trackId = args["trackId"] as? String
        let visualizerId = args["visualizerId"] as? String 
        let barCount = args["barCount"] as? Int ?? 7
        let isCentered = args["isCentered"] as? Bool ?? true
        let smoothTransition = args["smoothTransition"] as? Bool ?? true

        if visualizerId == nil {
            result(FlutterError(code: "visualizerId", message: "visualizerId is required", details: nil))
            return
        }

        if let unwrappedTrackId = trackId { 
            let unwrappedVisualizerId = visualizerId!

            let localTrack = webrtc?.localTracks![unwrappedTrackId]
            if let audioTrack = localTrack as? LocalAudioTrack {
                let lkLocalTrack = LKLocalAudioTrack(name: unwrappedTrackId, track: audioTrack);
                let processor = Visualizer(track: lkLocalTrack,
                                               binaryMessenger: self.binaryMessenger!,
                                               bandCount: barCount,
                                               isCentered: isCentered,
                                               smoothTransition: smoothTransition,
                                               visualizerId: unwrappedVisualizerId)    
                
                tracks[unwrappedTrackId] = lkLocalTrack
                processors[unwrappedVisualizerId] = processor
                
            }

            let track = webrtc?.remoteTrack(forId: unwrappedTrackId)
            if let audioTrack = track as? RTCAudioTrack {
                let lkRemoteTrack = LKRemoteAudioTrack(name: unwrappedTrackId, track: audioTrack);
                let processor = Visualizer(track: lkRemoteTrack,
                                               binaryMessenger: self.binaryMessenger!,
                                               bandCount: barCount,
                                               isCentered: isCentered,
                                               smoothTransition: smoothTransition,
                                               visualizerId: unwrappedVisualizerId)
                tracks[unwrappedTrackId] = lkRemoteTrack
                processors[unwrappedVisualizerId] = processor
            }
        }


        result(true)
    }

    public func handleStopAudioVisualizer(args: [String: Any?], result: @escaping FlutterResult) {
        let trackId = args["trackId"] as? String
        let visualizerId = args["visualizerId"] as? String
        if let unwrappedTrackId = trackId {
            for key in tracks.keys {
                if key == unwrappedTrackId {
                    tracks.removeValue(forKey: key)
                }
            }
        }
        if let unwrappedVisualizerId = visualizerId {
            processors.removeValue(forKey: unwrappedVisualizerId)
        }
        result(true)
    }

    #if os(iOS)
    public func handleStartAudioMixer(args: [String: Any?], result: @escaping FlutterResult) {
        let webrtc = FlutterWebRTCPlugin.sharedSingleton()
        guard let trackId = args["trackId"] as? String else {
            result(FlutterError(code: "trackId", message: "trackId is required", details: nil))
            return
        }

        guard let localTrack = webrtc?.localTracks![trackId] as? LocalAudioTrack else {
            result(FlutterError(code: "track", message: "LocalAudioTrack not found for trackId", details: nil))
            return
        }

        // Re-attach if already running on another track.
        if let existing = audioMixer, existing.isAttached {
            handleStopAudioMixerInternal()
        }

        let mixer = audioMixer ?? AudioMixerProcessor()
        localTrack.addProcessing(mixer)
        // Also mix into the render path so the local user hears the sound
        // at full level (not ducked by voiceChat / videoChat session mode).
        AudioManager.sharedInstance().renderPreProcessingAdapter.addProcessing(mixer)

        mixer.isAttached = true
        audioMixer = mixer
        audioMixerTrackId = trackId
        result(true)
    }

    public func handlePlayMixedAudio(args: [String: Any?], result: @escaping FlutterResult) {
        guard let mixer = audioMixer, mixer.isAttached else {
            result(FlutterError(code: "mixer", message: "Audio mixer is not started. Call startAudioMixer first.", details: nil))
            return
        }
        guard let filePath = args["filePath"] as? String else {
            result(FlutterError(code: "filePath", message: "filePath is required", details: nil))
            return
        }

        let playId = (args["playId"] as? String) ?? UUID().uuidString
        let volume = Self.floatArg(args["volume"], default: 1.0)
        let loop = (args["loop"] as? Bool) ?? false

        let ok = mixer.play(filePath: filePath, playId: playId, volume: volume, loop: loop)
        if ok {
            result(playId)
        } else {
            result(FlutterError(code: "play", message: "Failed to play audio file", details: nil))
        }
    }

    public func handleStopMixedAudio(args: [String: Any?], result: @escaping FlutterResult) {
        guard let mixer = audioMixer else {
            result(true)
            return
        }
        let playId = args["playId"] as? String
        mixer.stop(playId: playId)
        result(true)
    }

    public func handleSetMixedAudioVolume(args: [String: Any?], result: @escaping FlutterResult) {
        guard let mixer = audioMixer else {
            result(FlutterError(code: "mixer", message: "Audio mixer is not started", details: nil))
            return
        }
        guard let playId = args["playId"] as? String else {
            result(FlutterError(code: "playId", message: "playId is required", details: nil))
            return
        }
        let volume = Self.floatArg(args["volume"], default: 1.0)
        mixer.setVolume(playId: playId, volume: volume)
        result(true)
    }

    public func handleStopAudioMixer(args: [String: Any?], result: @escaping FlutterResult) {
        handleStopAudioMixerInternal()
        result(true)
    }

    private func handleStopAudioMixerInternal() {
        guard let mixer = audioMixer else { return }

        if let trackId = audioMixerTrackId,
           let localTrack = FlutterWebRTCPlugin.sharedSingleton()?.localTracks![trackId] as? LocalAudioTrack {
            localTrack.removeProcessing(mixer)
        }
        AudioManager.sharedInstance().renderPreProcessingAdapter.removeProcessing(mixer)

        mixer.stop(playId: nil)
        mixer.isAttached = false
        audioMixerTrackId = nil
    }

    private static func floatArg(_ value: Any?, default defaultValue: Float) -> Float {
        if let number = value as? NSNumber {
            return number.floatValue
        }
        if let double = value as? Double {
            return Float(double)
        }
        if let int = value as? Int {
            return Float(int)
        }
        return defaultValue
    }
    #endif

    public func handleConfigureNativeAudio(args: [String: Any?], result: @escaping FlutterResult) {

        #if os(macOS)
        result(FlutterMethodNotImplemented)
        #else

        let configuration = RTCAudioSessionConfiguration.webRTC()

        // Category
        if let string = args["appleAudioCategory"] as? String,
           let category = categoryMap[string] {
            configuration.category = category.rawValue
            print("[LiveKit] Configuring category: ", configuration.category)
        }

        // CategoryOptions
        if let strings = args["appleAudioCategoryOptions"] as? [String] {
            configuration.categoryOptions = categoryOptions(fromFlutter: strings)
            print("[LiveKit] Configuring categoryOptions: ", strings)
        }

        // Mode
        if let string = args["appleAudioMode"] as? String,
           let mode = modeMap[string] {
            configuration.mode = mode.rawValue
            print("[LiveKit] Configuring mode: ", configuration.mode)
        }

        // get `RTCAudioSession` and lock
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.lockForConfiguration()

        var isLocked: Bool = true
        let unlock = {
            guard isLocked else {
                print("[LiveKit] not locked, ignoring unlock")
                return
            }
            rtcSession.unlockForConfiguration()
            isLocked = false
        }

        // always `unlock()` when exiting scope, calling multiple times has no side-effect
        defer {
            unlock()
        }

        do {
            try rtcSession.setConfiguration(configuration, active: true)
            // unlock here before configuring `AVAudioSession`
            // unlock()
            print("[LiveKit] RTCAudioSession Configure success")

            // also configure longFormAudio
            // let avSession = AVAudioSession.sharedInstance()
            // try avSession.setCategory(AVAudioSession.Category(rawValue: configuration.category),
            //                      mode: AVAudioSession.Mode(rawValue: configuration.mode),
            //                      policy: .default,
            //                      options: configuration.categoryOptions)
            // print("[LiveKit] AVAudioSession Configure success")

            // preferSpeakerOutput
            if let preferSpeakerOutput = args["preferSpeakerOutput"] as? Bool {
              try rtcSession.overrideOutputAudioPort(preferSpeakerOutput ? .speaker : .none)
            }
            result(true)
        } catch let error {
            print("[LiveKit] Configure audio error: ", error)
            result(FlutterError(code: "configure", message: error.localizedDescription, details: nil))
        }
        #endif
    }

    private static let processInfo = ProcessInfo()

    /// Returns os version as a string.
    /// format: `12.1`, `15.3.1`, `15.0.1`
    private static func osVersionString() -> String {
        let osVersion = processInfo.operatingSystemVersion
        var versions = [osVersion.majorVersion]
        if osVersion.minorVersion != 0 || osVersion.patchVersion != 0 {
            versions.append(osVersion.minorVersion)
        }
        if osVersion.patchVersion != 0 {
            versions.append(osVersion.patchVersion)
        }
        return versions.map({ String($0) }).joined(separator: ".")
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any?] else {
            print("[LiveKit] arguments must be a dictionary")
            result(FlutterMethodNotImplemented)
            return
        }

        switch call.method {
        case "configureNativeAudio":
            handleConfigureNativeAudio(args: args, result: result)
        case "startVisualizer":
            handleStartAudioVisualizer(args: args, result: result)
        case "stopVisualizer":
            handleStopAudioVisualizer(args: args, result: result)
        case "osVersionString":
            result(LiveKitPlugin.osVersionString())
        #if os(iOS)
        case "broadcastRequestActivation":
            BroadcastManager.shared.requestActivation()
            result(true)
        case "broadcastRequestStop":
            BroadcastManager.shared.requestStop()
            result(true)
        case "startAudioMixer":
            handleStartAudioMixer(args: args, result: result)
        case "playMixedAudio":
            handlePlayMixedAudio(args: args, result: result)
        case "stopMixedAudio":
            handleStopMixedAudio(args: args, result: result)
        case "setMixedAudioVolume":
            handleSetMixedAudioVolume(args: args, result: result)
        case "stopAudioMixer":
            handleStopAudioMixer(args: args, result: result)
        #endif
        default:
            print("[LiveKit] method not found: ", call.method)
            result(FlutterMethodNotImplemented)
        }
    }
}
