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
/// Samples are stored as mono FloatS16 at the **file native rate**.
/// Each tap advances its own read cursor by `frames` using the sample rate from
/// `audioProcessingInitialize` (NOT `frames * 100`, which breaks when the
/// audio unit buffer is not exactly 10 ms — a common cause of strong distortion).
final class AudioMixerEngine {
    struct Playback {
        let id: String
        /// FloatS16 mono samples at `sampleRate`.
        let samples: [Float]
        let sampleRate: Double
        /// Gain that brings active file RMS close to WebRTC speech level while
        /// preserving peak headroom. `volume` is applied on top of this value.
        let normalizationGain: Float
        var volume: Float
        let loop: Bool
        let playLocally: Bool
        let sendToRemote: Bool
        /// Fractional read heads (in source sample frames) per tap.
        var captureReadPos: Double = 0
        var renderReadPos: Double = 0
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

        print(
            "[LiveKit] AudioMixer: loaded \(decoded.samples.count) samples @ \(decoded.sampleRate) Hz, " +
            "peak=\(decoded.peak), activeRms=\(decoded.activeRms), normalizationGain=\(decoded.normalizationGain)"
        )

        os_unfair_lock_lock(&lock)
        playbooks.removeAll { $0.id == playId }
        playbooks.append(Playback(
            id: playId,
            samples: decoded.samples,
            sampleRate: decoded.sampleRate,
            normalizationGain: decoded.normalizationGain,
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

    /// - Parameter deviceSampleRate: rate from `audioProcessingInitialize` for this tap.
    func mix(into audioBuffer: RTCAudioBuffer, kind: TapKind, deviceSampleRate: Double) {
        let frames = Int(audioBuffer.frames)
        let channels = Int(audioBuffer.channels)
        guard frames > 0, channels > 0 else { return }

        // Prefer the initialized device rate. Only fall back to frames*100 if
        // initialize has not run yet (should be rare).
        let outRate = deviceSampleRate > 0 ? deviceSampleRate : Double(max(frames, 1) * 100)
        guard outRate > 0 else { return }

        os_unfair_lock_lock(&lock)
        var finishedIds: [String] = []

        for i in 0 ..< playbooks.count {
            var playback = playbooks[i]

            switch kind {
            case .capture where !playback.sendToRemote: continue
            case .render where !playback.playLocally: continue
            default: break
            }

            guard !playback.samples.isEmpty, playback.sampleRate > 0 else {
                finishedIds.append(playback.id)
                continue
            }

            // How far to advance in the *source* for one output sample.
            let srcStep = playback.sampleRate / outRate
            var readPos: Double
            switch kind {
            case .capture: readPos = playback.captureReadPos
            case .render: readPos = playback.renderReadPos
            }

            let sourceCount = Double(playback.samples.count)

            if !playback.loop, readPos >= sourceCount - 1 {
                finishedIds.append(playback.id)
                continue
            }

            for ch in 0 ..< channels {
                let buffer = audioBuffer.rawBuffer(forChannel: ch)
                var pos = readPos
                for frame in 0 ..< frames {
                    if playback.loop {
                        if pos >= sourceCount {
                            pos = pos.truncatingRemainder(dividingBy: sourceCount)
                        }
                        if pos < 0 { pos += sourceCount }
                    } else if pos >= sourceCount - 1 {
                        break
                    }

                    let sample = Self.interpolate(playback.samples, at: pos)
                        * playback.normalizationGain
                        * playback.volume
                    let mixed = buffer[frame] + sample
                    buffer[frame] = Self.saturateOverload(mixed)
                    pos += srcStep
                }
            }

            // Advance read head once (same for all channels).
            var newPos = readPos + Double(frames) * srcStep
            if playback.loop {
                if newPos >= sourceCount {
                    newPos = newPos.truncatingRemainder(dividingBy: sourceCount)
                }
            } else if newPos >= sourceCount - 1 {
                finishedIds.append(playback.id)
            }

            switch kind {
            case .capture: playback.captureReadPos = newPos
            case .render: playback.renderReadPos = newPos
            }
            playbooks[i] = playback
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

    /// Leaves the normal signal untouched and smoothly compresses only the
    /// overload region. Unlike the previous `x / (1 + abs(x))` function this
    /// does not add harmonics to every sample, and unlike a hard clamp it has
    /// no sharp corner at full scale.
    private static func saturateOverload(_ value: Float) -> Float {
        let limit: Float = 32767
        let knee = limit * 0.85
        let magnitude = abs(value)
        guard magnitude > knee else { return value }

        let range = limit - knee
        let normalizedExcess = (magnitude - knee) / range
        let compressed = knee + range * (normalizedExcess / (1 + normalizedExcess))
        return value < 0 ? -compressed : compressed
    }

    /// Decode file at its native rate to mono FloatS16.
    private static func loadMonoFloatS16(
        url: URL
    ) -> (
        samples: [Float],
        sampleRate: Double,
        peak: Float,
        activeRms: Float,
        normalizationGain: Float
    )? {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
            else { return nil }

            // Compressed formats may require multiple reads.
            var remaining = frameCount
            var writeOffset = AVAudioFrameCount(0)
            while remaining > 0 {
                guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: remaining) else {
                    return nil
                }
                try file.read(into: chunk)
                let readFrames = chunk.frameLength
                if readFrames == 0 { break }

                if let dst = buffer.floatChannelData, let src = chunk.floatChannelData {
                    let channels = Int(format.channelCount)
                    for ch in 0 ..< channels {
                        memcpy(
                            dst[ch] + Int(writeOffset),
                            src[ch],
                            Int(readFrames) * MemoryLayout<Float>.size
                        )
                    }
                } else if let dst = buffer.int16ChannelData, let src = chunk.int16ChannelData {
                    let channels = Int(format.channelCount)
                    for ch in 0 ..< channels {
                        memcpy(
                            dst[ch] + Int(writeOffset),
                            src[ch],
                            Int(readFrames) * MemoryLayout<Int16>.size
                        )
                    }
                } else {
                    return nil
                }

                writeOffset += readFrames
                remaining -= readFrames
                buffer.frameLength = writeOffset
            }

            let length = Int(buffer.frameLength)
            guard length > 0 else { return nil }

            var mono = [Float](repeating: 0, count: length)
            let channelCount = Int(format.channelCount)
            var peak: Float = 0

            if let floatData = buffer.floatChannelData {
                // AVAudioFile processingFormat is float in [-1, 1].
                for frame in 0 ..< length {
                    var sum: Float = 0
                    for ch in 0 ..< channelCount {
                        sum += floatData[ch][frame]
                    }
                    let sample = (sum / Float(max(channelCount, 1))) * 32767.0
                    mono[frame] = sample
                    peak = max(peak, abs(sample))
                }
            } else if let int16Data = buffer.int16ChannelData {
                for frame in 0 ..< length {
                    var sum: Float = 0
                    for ch in 0 ..< channelCount {
                        sum += Float(int16Data[ch][frame])
                    }
                    let sample = sum / Float(max(channelCount, 1))
                    mono[frame] = sample
                    peak = max(peak, abs(sample))
                }
            } else {
                return nil
            }

            // Remove edge discontinuities which otherwise become clicks,
            // especially when a short sound is looped.
            let fadeFrames = min(length / 2, max(1, Int(format.sampleRate * 0.005)))
            if fadeFrames > 1 {
                for frame in 0 ..< fadeFrames {
                    let gain = Float(frame) / Float(fadeFrames - 1)
                    mono[frame] *= gain
                    mono[length - 1 - frame] *= gain
                }
            }

            let activeRms = Self.activeRms(
                mono,
                sampleRate: format.sampleRate
            )
            let normalizationGain = Self.normalizationGain(
                activeRms: activeRms,
                peak: peak
            )

            return (
                mono,
                format.sampleRate,
                peak,
                activeRms,
                normalizationGain
            )
        } catch {
            print("[LiveKit] AudioMixer decode error: \(error)")
            return nil
        }
    }

    /// RMS over non-silent 50 ms blocks. Ignoring silent blocks prevents files
    /// with long pauses from being boosted far above speech level.
    private static func activeRms(_ samples: [Float], sampleRate: Double) -> Float {
        guard !samples.isEmpty, sampleRate > 0 else { return 0 }

        let blockFrames = max(1, Int(sampleRate * 0.05))
        // -50 dBFS: low enough to keep quiet program material, high enough to
        // reject encoded silence and background noise.
        let gateRms = Float(32767.0 * pow(10.0, -50.0 / 20.0))
        var activeSquareSum: Double = 0
        var activeSampleCount = 0
        var offset = 0

        while offset < samples.count {
            let end = min(offset + blockFrames, samples.count)
            var blockSquareSum: Double = 0
            for index in offset ..< end {
                let value = Double(samples[index])
                blockSquareSum += value * value
            }

            let count = end - offset
            let blockRms = Float(sqrt(blockSquareSum / Double(max(count, 1))))
            if blockRms >= gateRms {
                activeSquareSum += blockSquareSum
                activeSampleCount += count
            }
            offset = end
        }

        guard activeSampleCount > 0 else { return 0 }
        return Float(sqrt(activeSquareSum / Double(activeSampleCount)))
    }

    private static func normalizationGain(activeRms: Float, peak: Float) -> Float {
        guard activeRms > 0, peak > 0 else { return 1 }

        // WebRTC speech with AGC is commonly around this active level. Keep
        // normalized file peaks at or below -6 dBFS to leave mixing headroom.
        let targetRms = Float(32767.0 * pow(10.0, -20.0 / 20.0))
        let peakCeiling = Float(32767.0 * pow(10.0, -6.0 / 20.0))
        let rmsGain = targetRms / activeRms
        let peakGain = peakCeiling / peak

        // Avoid extreme amplification of unusually quiet/noisy files.
        return max(0.05, min(8.0, min(rmsGain, peakGain)))
    }
}

/// Thin tap so capture and render can filter playbooks independently and keep
/// their own device sample rate from initialize.
final class AudioMixerTap: NSObject, ExternalAudioProcessingDelegate {
    private let engine: AudioMixerEngine
    private let kind: AudioMixerEngine.TapKind
    private var deviceSampleRate: Double = 0
    private var loggedFormat = false

    init(engine: AudioMixerEngine, kind: AudioMixerEngine.TapKind) {
        self.engine = engine
        self.kind = kind
        super.init()
    }

    func audioProcessingInitialize(withSampleRate sampleRateHz: Int, channels: Int) {
        deviceSampleRate = Double(sampleRateHz)
        print("[LiveKit] AudioMixer: \(kind) initialize rate=\(sampleRateHz) channels=\(channels)")
    }

    func audioProcessingProcess(_ audioBuffer: RTCAudioBuffer) {
        // If this tap was attached after APM init, initialize may never fire.
        if deviceSampleRate <= 0 {
            deviceSampleRate = Double(audioBuffer.frames * 100)
        }
        if !loggedFormat {
            loggedFormat = true
            print("[LiveKit] AudioMixer: \(kind) process frames=\(audioBuffer.frames) channels=\(audioBuffer.channels) bands=\(audioBuffer.bands) framesPerBand=\(audioBuffer.framesPerBand) deviceRate=\(deviceSampleRate)")
        }
        engine.mix(into: audioBuffer, kind: kind, deviceSampleRate: deviceSampleRate)
    }

    func audioProcessingRelease() {
        deviceSampleRate = 0
        loggedFormat = false
    }
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
