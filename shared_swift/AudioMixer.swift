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

/// Mixes local audio files into the LiveKit / WebRTC capture (and render) graph
/// so sounds are heard at full level instead of being ducked by AVAudioSession voice modes.
///
/// Playback position is driven by `CACurrentMediaTime` so the same processor instance can be
/// attached to both capture and render adapters without advancing twice as fast.
final class AudioMixerProcessor: NSObject, ExternalAudioProcessingDelegate {

    private struct Playback {
        let id: String
        let samples: [Int16]
        let startMediaTime: CFTimeInterval
        var volume: Float
        let loop: Bool
    }

    private var lock = os_unfair_lock_s()
    private var playbooks: [Playback] = []
    private var sampleRate: Double = 48_000
    private var channelCount: Int = 1

    var isAttached: Bool = false

    // MARK: - ExternalAudioProcessingDelegate

    func audioProcessingInitialize(withSampleRate sampleRateHz: Int, channels: Int) {
        os_unfair_lock_lock(&lock)
        sampleRate = Double(sampleRateHz)
        channelCount = max(1, channels)
        os_unfair_lock_unlock(&lock)
    }

    func audioProcessingProcess(_ audioBuffer: RTCAudioBuffer) {
        let frames = Int(audioBuffer.frames)
        let channels = Int(audioBuffer.channels)
        guard frames > 0, channels > 0 else { return }

        let inferredRate = Double(frames * 100)
        let now = CACurrentMediaTime()

        os_unfair_lock_lock(&lock)
        if abs(inferredRate - sampleRate) > 1 || channels != channelCount {
            sampleRate = inferredRate
            channelCount = channels
        }

        let rate = sampleRate
        var finishedIds: [String] = []

        for playback in playbooks {
            guard !playback.samples.isEmpty else {
                finishedIds.append(playback.id)
                continue
            }

            let elapsedFrames = Int((now - playback.startMediaTime) * rate)
            if elapsedFrames < 0 { continue }

            var sourceFrame = elapsedFrames
            if playback.loop {
                sourceFrame = sourceFrame % playback.samples.count
            } else if sourceFrame >= playback.samples.count {
                finishedIds.append(playback.id)
                continue
            }

            for frame in 0 ..< frames {
                var idx = sourceFrame + frame
                if playback.loop {
                    idx = idx % playback.samples.count
                } else if idx >= playback.samples.count {
                    break
                }

                let sample = Float(playback.samples[idx]) * playback.volume
                for ch in 0 ..< channels {
                    let buffer = audioBuffer.rawBuffer(forChannel: ch)
                    let mixed = buffer[frame] + sample
                    buffer[frame] = max(Float(Int16.min), min(Float(Int16.max), mixed))
                }
            }
        }

        if !finishedIds.isEmpty {
            let unique = Set(finishedIds)
            playbooks.removeAll { unique.contains($0.id) }
        }
        os_unfair_lock_unlock(&lock)
    }

    func audioProcessingRelease() {
        os_unfair_lock_lock(&lock)
        playbooks.removeAll()
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Control

    @discardableResult
    func play(filePath: String, playId: String, volume: Float, loop: Bool) -> Bool {
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("[LiveKit] AudioMixer: file not found: \(filePath)")
            return false
        }

        os_unfair_lock_lock(&lock)
        let rate = sampleRate
        os_unfair_lock_unlock(&lock)

        let url = URL(fileURLWithPath: filePath)
        guard let samples = Self.loadMonoInt16(url: url, sampleRate: rate) else {
            print("[LiveKit] AudioMixer: failed to decode: \(filePath)")
            return false
        }

        os_unfair_lock_lock(&lock)
        playbooks.removeAll { $0.id == playId }
        playbooks.append(Playback(
            id: playId,
            samples: samples,
            startMediaTime: CACurrentMediaTime(),
            volume: max(0, volume),
            loop: loop
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

    // MARK: - Decoding

    private static func loadMonoInt16(url: URL, sampleRate: Double) -> [Int16]? {
        do {
            let file = try AVAudioFile(forReading: url)
            let inputFormat = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard frameCount > 0,
                  let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount)
            else { return nil }

            try file.read(into: inputBuffer)

            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: true
            ) else { return nil }

            if inputFormat.sampleRate == sampleRate,
               inputFormat.commonFormat == .pcmFormatInt16,
               inputFormat.channelCount == 1,
               let data = inputBuffer.int16ChannelData
            {
                let length = Int(inputBuffer.frameLength)
                return Array(UnsafeBufferPointer(start: data[0], count: length))
            }

            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                return nil
            }

            let ratio = sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 64
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: capacity
            ) else { return nil }

            var inputConsumed = false
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
            if let error {
                print("[LiveKit] AudioMixer convert error: \(error)")
                return nil
            }

            guard let channelData = outputBuffer.int16ChannelData else { return nil }
            let length = Int(outputBuffer.frameLength)
            return Array(UnsafeBufferPointer(start: channelData[0], count: length))
        } catch {
            print("[LiveKit] AudioMixer decode error: \(error)")
            return nil
        }
    }
}

#endif
