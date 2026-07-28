/*
 * Copyright 2025 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#if os(iOS)
import AVFoundation
import Foundation
import WebRTC
import flutter_webrtc
import os.lock

/// Shared playback state for capture/render taps.
///
/// Samples are kept in the file's native sample rate as FloatS16
/// (`[-32768, 32767]`). Mixing resamples with linear interpolation to the
/// buffer rate so pitch/speed stay correct even when capture and render rates
/// differ from the file (or from each other).
final class AudioMixerEngine {
    struct Playback {
        let id: String
        /// FloatS16 mono samples at `sampleRate`.
        let samples: [Float]
        let sampleRate: Double
        let startMediaTime: CFTimeInterval
        var volume: Float
        let loop: Bool
        let playLocally: Bool
        let sendToRemote: Bool
    }

    private var lock = os_unfair_lock_s()
    private var playbooks: [Playback] = []

    enum TapKind {
        case capture
        case render
    }

    @discardableResult
    func play(
        filePath: String,
        playId: String,
        volume: Float,
        loop: Bool,
        playLocally: Bool,
        sendToRemote: Bool
    ) -> Bool {
        guard playLocally || sendToRemote else {
            print("[LiveKit] AudioMixer: playLocally and sendToRemote are both false")
            return false
        }
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("[LiveKit] AudioMixer: file not found: \(filePath)")
            return false
        }

        let url = URL(fileURLWithPath: filePath)
        guard let decoded = Self.loadMonoFloatS16(url: url) else {
            print("[LiveKit] AudioMixer: failed to decode: \(filePath)")
            return false
        }

        os_unfair_lock_lock(&lock)
        playbooks.removeAll { $0.id == playId }
        playbooks.append(Playback(
            id: playId,
            samples: decoded.samples,
            sampleRate: decoded.sampleRate,
            startMediaTime: CACurrentMediaTime(),
            volume: max(0, volume),
            loop: loop,
            playLocally: playLocally,
            sendToRemote: sendToRemote
        ))
        os_unfair_lock_unlock(&lock)
        return true
    }

    func stop(playId: String?) {
        os_unfair_lock_lock(&lock)
        if let playId {
            playbooks.removeAll { $0.id == playId }
        } else {
            playbooks.removeAll()
        }
        os_unfair_lock_unlock(&lock)
    }

    func setVolume(playId: String, volume: Float) {
        os_unfair_lock_lock(&lock)
        if let index = playbooks.firstIndex(where: { $0.id == playId }) {
            playbooks[index].volume = max(0, volume)
        }
        os_unfair_lock_unlock(&lock)
    }

    func mix(into audioBuffer: RTCAudioBuffer, kind: TapKind) {
        let frames = Int(audioBuffer.frames)
        let channels = Int(audioBuffer.channels)
        guard frames > 0, channels > 0 else { return }

        // ~10 ms WebRTC buffers.
        let bufferRate = Double(frames * 100)
        let now = CACurrentMediaTime()

        os_unfair_lock_lock(&lock)
        var finishedIds: [String] = []

        for playback in playbooks {
            switch kind {
            case .capture where !playback.sendToRemote: continue
            case .render where !playback.playLocally: continue
            default: break
            }

            guard !playback.samples.isEmpty, playback.sampleRate > 0 else {
                finishedIds.append(playback.id)
                continue
            }

            let elapsedSec = now - playback.startMediaTime
            if elapsedSec < 0 { continue }

            let srcStart = elapsedSec * playback.sampleRate
            let durationSec = Double(playback.samples.count) / playback.sampleRate

            if !playback.loop, elapsedSec >= durationSec {
                finishedIds.append(playback.id)
                continue
            }

            for ch in 0 ..< channels {
                let buffer = audioBuffer.rawBuffer(forChannel: ch)
                for frame in 0 ..< frames {
                    var srcPos = srcStart + Double(frame) * (playback.sampleRate / bufferRate)
                    if playback.loop {
                        let count = Double(playback.samples.count)
                        srcPos = srcPos.truncatingRemainder(dividingBy: count)
                        if srcPos < 0 { srcPos += count }
                    } else if srcPos >= Double(playback.samples.count - 1) {
                        break
                    }

                    let sample = Self.interpolate(playback.samples, at: srcPos) * playback.volume
                    // Soft clip to reduce harsh distortion vs hard Int16 clamp.
                    buffer[frame] = Self.softClip(buffer[frame] + sample)
                }
            }
        }

        if !finishedIds.isEmpty {
            let unique = Set(finishedIds)
            playbooks.removeAll { unique.contains($0.id) }
        }
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Helpers

    private static func interpolate(_ samples: [Float], at position: Double) -> Float {
        if samples.isEmpty { return 0 }
        if position <= 0 { return samples[0] }
        let maxIndex = samples.count - 1
        if position >= Double(maxIndex) { return samples[maxIndex] }

        let i0 = Int(position)
        let i1 = min(i0 + 1, maxIndex)
        let frac = Float(position - Double(i0))
        return samples[i0] + (samples[i1] - samples[i0]) * frac
    }

    /// Soft clip toward ±32767 (FloatS16 range used by WebRTC AudioBuffer).
    private static func softClip(_ value: Float) -> Float {
        let limit: Float = 32767
        let x = value / limit
        // tanh-ish soft clip, then scale back
        let y = x / (1 + abs(x))
        return y * limit
    }

    /// Decode file at its native rate to mono FloatS16 (no upfront resample).
    private static func loadMonoFloatS16(url: URL) -> (samples: [Float], sampleRate: Double)? {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
            else { return nil }

            try file.read(into: buffer)
            let length = Int(buffer.frameLength)
            guard length > 0 else { return nil }

            var mono = [Float](repeating: 0, count: length)
            let channelCount = Int(format.channelCount)

            if let floatData = buffer.floatChannelData {
                for frame in 0 ..< length {
                    var sum: Float = 0
                    for ch in 0 ..< channelCount {
                        sum += floatData[ch][frame]
                    }
                    // processingFormat float is typically [-1, 1] → FloatS16
                    mono[frame] = (sum / Float(channelCount)) * 32767.0
                }
            } else if let int16Data = buffer.int16ChannelData {
                for frame in 0 ..< length {
                    var sum: Float = 0
                    for ch in 0 ..< channelCount {
                        sum += Float(int16Data[ch][frame])
                    }
                    mono[frame] = sum / Float(channelCount)
                }
            } else {
                return nil
            }

            return (mono, format.sampleRate)
        } catch {
            print("[LiveKit] AudioMixer decode error: \(error)")
            return nil
        }
    }
}

/// Thin tap so capture and render can filter playbooks independently.
final class AudioMixerTap: NSObject, ExternalAudioProcessingDelegate {
    private let engine: AudioMixerEngine
    private let kind: AudioMixerEngine.TapKind

    init(engine: AudioMixerEngine, kind: AudioMixerEngine.TapKind) {
        self.engine = engine
        self.kind = kind
        super.init()
    }

    func audioProcessingInitialize(withSampleRate sampleRateHz: Int, channels: Int) {
        // Rate is taken from each buffer in process(); nothing to store.
    }

    func audioProcessingProcess(_ audioBuffer: RTCAudioBuffer) {
        engine.mix(into: audioBuffer, kind: kind)
    }

    func audioProcessingRelease() {}
}

/// Owns engine + taps attached to WebRTC capture/render adapters.
final class AudioMixerController {
    let engine = AudioMixerEngine()
    let captureTap: AudioMixerTap
    let renderTap: AudioMixerTap
    var isAttached = false
    var trackId: String?

    init() {
        captureTap = AudioMixerTap(engine: engine, kind: .capture)
        renderTap = AudioMixerTap(engine: engine, kind: .render)
    }

    func attach(to localTrack: LocalAudioTrack, trackId: String) {
        localTrack.addProcessing(captureTap)
        AudioManager.sharedInstance().renderPreProcessingAdapter.addProcessing(renderTap)
        self.trackId = trackId
        isAttached = true
    }

    func detach(from localTrack: LocalAudioTrack?) {
        if let localTrack {
            localTrack.removeProcessing(captureTap)
        }
        AudioManager.sharedInstance().renderPreProcessingAdapter.removeProcessing(renderTap)
        engine.stop(playId: nil)
        trackId = nil
        isAttached = false
    }
}

#endif
