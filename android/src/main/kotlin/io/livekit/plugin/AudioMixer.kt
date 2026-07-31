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

package io.livekit.plugin

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter
import com.cloudwebrtc.webrtc.audio.AudioProcessingController
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

private const val TAG = "LiveKitAudioMixer"
private const val PCM_LIMIT = 32767f

internal enum class MixerTapKind {
    CAPTURE,
    RENDER
}

private data class DecodedAudio(
    val samples: FloatArray,
    val sampleRate: Double,
    val peak: Float,
    val activeRms: Float,
    val normalizationGain: Float
)

private data class Playback(
    val id: String,
    val samples: FloatArray,
    val sampleRate: Double,
    val normalizationGain: Float,
    var volume: Float,
    val loop: Boolean,
    val playLocally: Boolean,
    val sendToRemote: Boolean,
    var captureReadPos: Double = 0.0,
    var renderReadPos: Double = 0.0
)

private class FloatSampleBuffer(initialCapacity: Int = 8192) {
    private var values = FloatArray(initialCapacity)
    var size = 0
        private set

    fun add(value: Float) {
        if (size == values.size) {
            values = values.copyOf(values.size * 2)
        }
        values[size] = value
        size++
    }

    fun isEmpty(): Boolean = size == 0

    fun toFloatArray(): FloatArray = values.copyOf(size)
}

internal sealed class AudioMixerPlayResult {
    data class Success(val playId: String) : AudioMixerPlayResult()
    data class Failure(
        val code: String,
        val message: String,
        val details: Map<String, String?>? = null
    ) : AudioMixerPlayResult()
}

internal class AudioMixerEngine {
    private val playbacks = mutableListOf<Playback>()
    private val lock = Any()

    fun play(
        filePath: String,
        playId: String,
        volume: Float,
        loop: Boolean,
        playLocally: Boolean,
        sendToRemote: Boolean,
        isActive: () -> Boolean = { true }
    ): AudioMixerPlayResult {
        if (!isActive()) {
            return AudioMixerPlayResult.Failure(
                code = "mixer_detached",
                message = "Audio mixer is not started"
            )
        }
        if (!playLocally && !sendToRemote) {
            return AudioMixerPlayResult.Failure(
                code = "invalid_flags",
                message = "playLocally and sendToRemote are both false"
            )
        }
        if (!File(filePath).exists()) {
            return AudioMixerPlayResult.Failure(
                code = "file_not_found",
                message = "Audio file not found",
                details = mapOf("filePath" to filePath)
            )
        }

        val decoded = decodeToMonoFloatS16(filePath) ?: run {
            return AudioMixerPlayResult.Failure(
                code = "decode_failed",
                message = "Failed to decode audio file",
                details = mapOf("filePath" to filePath)
            )
        }

        if (!isActive()) {
            return AudioMixerPlayResult.Failure(
                code = "mixer_detached",
                message = "Audio mixer was stopped before audio decode completed"
            )
        }

        Log.d(
            TAG,
            "loaded ${decoded.samples.size} samples @ ${decoded.sampleRate} Hz, " +
                "peak=${decoded.peak}, activeRms=${decoded.activeRms}, " +
                "normalizationGain=${decoded.normalizationGain}"
        )

        synchronized(lock) {
            playbacks.removeAll { it.id == playId }
            playbacks.add(
                Playback(
                    id = playId,
                    samples = decoded.samples,
                    sampleRate = decoded.sampleRate,
                    normalizationGain = decoded.normalizationGain,
                    volume = max(0f, volume),
                    loop = loop,
                    playLocally = playLocally,
                    sendToRemote = sendToRemote
                )
            )
        }
        return AudioMixerPlayResult.Success(playId)
    }

    fun stop(playId: String?) {
        synchronized(lock) {
            if (playId == null) {
                playbacks.clear()
            } else {
                playbacks.removeAll { it.id == playId }
            }
        }
    }

    fun setVolume(playId: String, volume: Float) {
        synchronized(lock) {
            playbacks.firstOrNull { it.id == playId }?.volume = max(0f, volume)
        }
    }

    fun mix(
        buffer: ByteBuffer,
        kind: MixerTapKind,
        outputSampleRate: Double,
        channels: Int
    ) {
        if (outputSampleRate <= 0.0 || channels <= 0) return

        val view = buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN)
        val start = view.position()
        val sampleCount = view.remaining() / 2
        val frames = sampleCount / channels
        if (frames <= 0) return

        synchronized(lock) {
            val finishedIds = mutableSetOf<String>()

            for (index in playbacks.indices) {
                val playback = playbacks[index]
                if (kind == MixerTapKind.CAPTURE && !playback.sendToRemote) continue
                if (kind == MixerTapKind.RENDER && !playback.playLocally) continue
                if (playback.samples.isEmpty() || playback.sampleRate <= 0.0) {
                    finishedIds.add(playback.id)
                    continue
                }

                val sourceCount = playback.samples.size.toDouble()
                var readPos = when (kind) {
                    MixerTapKind.CAPTURE -> playback.captureReadPos
                    MixerTapKind.RENDER -> playback.renderReadPos
                }

                if (!playback.loop && readPos >= sourceCount - 1.0) {
                    finishedIds.add(playback.id)
                    continue
                }

                val sourceStep = playback.sampleRate / outputSampleRate
                var frame = 0
                while (frame < frames) {
                    if (playback.loop) {
                        if (readPos >= sourceCount) {
                            readPos %= sourceCount
                        }
                        if (readPos < 0.0) readPos += sourceCount
                    } else if (readPos >= sourceCount - 1.0) {
                        break
                    }

                    val mixedSample = interpolate(playback.samples, readPos) *
                        playback.normalizationGain *
                        playback.volume

                    for (channel in 0 until channels) {
                        val byteIndex = start + ((frame * channels + channel) * 2)
                        val existing = view.getShort(byteIndex).toFloat()
                        view.putShort(byteIndex, saturateOverload(existing + mixedSample).toInt().toShort())
                    }

                    frame++
                    readPos += sourceStep
                }

                if (!playback.loop && readPos >= sourceCount - 1.0) {
                    finishedIds.add(playback.id)
                }

                when (kind) {
                    MixerTapKind.CAPTURE -> playback.captureReadPos = readPos
                    MixerTapKind.RENDER -> playback.renderReadPos = readPos
                }
            }

            if (finishedIds.isNotEmpty()) {
                playbacks.removeAll { finishedIds.contains(it.id) }
            }
        }
    }

    private fun interpolate(samples: FloatArray, position: Double): Float {
        if (samples.isEmpty()) return 0f
        if (position <= 0.0) return samples[0]
        val maxIndex = samples.size - 1
        if (position >= maxIndex.toDouble()) return samples[maxIndex]

        val i0 = position.toInt()
        val i1 = min(i0 + 1, maxIndex)
        val frac = (position - i0.toDouble()).toFloat()
        return samples[i0] + (samples[i1] - samples[i0]) * frac
    }

    private fun saturateOverload(value: Float): Float {
        val knee = PCM_LIMIT * 0.85f
        val magnitude = abs(value)
        if (magnitude <= knee) return value

        val range = PCM_LIMIT - knee
        val normalizedExcess = (magnitude - knee) / range
        val compressed = knee + range * (normalizedExcess / (1f + normalizedExcess))
        return if (value < 0f) -compressed else compressed
    }

    private fun decodeToMonoFloatS16(filePath: String): DecodedAudio? {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null

        return try {
            extractor.setDataSource(filePath)
            val trackIndex = findAudioTrack(extractor)
            if (trackIndex < 0) return null
            extractor.selectTrack(trackIndex)

            val inputFormat = extractor.getTrackFormat(trackIndex)
            val mime = inputFormat.getString(MediaFormat.KEY_MIME) ?: return null
            val sourceSampleRate = inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(inputFormat, null, null, 0)
            codec.start()

            val info = MediaCodec.BufferInfo()
            val pcm = FloatSampleBuffer()
            var sawInputEos = false
            var sawOutputEos = false
            var outputFormat = codec.outputFormat
            var outputSampleRate = sourceSampleRate
            var guard = 0

            while (!sawOutputEos && guard++ < 100000) {
                if (!sawInputEos) {
                    val inputIndex = codec.dequeueInputBuffer(10_000)
                    if (inputIndex >= 0) {
                        val inputBuffer = codec.getInputBuffer(inputIndex)
                        val sampleSize = if (inputBuffer == null) {
                            -1
                        } else {
                            extractor.readSampleData(inputBuffer, 0)
                        }

                        if (sampleSize < 0) {
                            codec.queueInputBuffer(
                                inputIndex,
                                0,
                                0,
                                0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM
                            )
                            sawInputEos = true
                        } else {
                            codec.queueInputBuffer(
                                inputIndex,
                                0,
                                sampleSize,
                                extractor.sampleTime,
                                0
                            )
                            extractor.advance()
                        }
                    }
                }

                when (val outputIndex = codec.dequeueOutputBuffer(info, 10_000)) {
                    MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        outputFormat = codec.outputFormat
                        if (outputFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                            outputSampleRate = outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        }
                    }
                    else -> if (outputIndex >= 0) {
                        val outputBuffer = codec.getOutputBuffer(outputIndex)
                        if (outputBuffer != null && info.size > 0) {
                            outputBuffer.position(info.offset)
                            outputBuffer.limit(info.offset + info.size)
                            appendMonoFloatS16(pcm, outputBuffer.slice(), outputFormat)
                        }

                        sawOutputEos =
                            (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                        codec.releaseOutputBuffer(outputIndex, false)
                    }
                }
            }

            if (pcm.isEmpty()) return null

            val samples = pcm.toFloatArray()
            applyEdgeFade(samples, outputSampleRate.toDouble())
            val peak = samples.fold(0f) { current, sample -> max(current, abs(sample)) }
            val activeRms = activeRms(samples, outputSampleRate.toDouble())

            DecodedAudio(
                samples = samples,
                sampleRate = outputSampleRate.toDouble(),
                peak = peak,
                activeRms = activeRms,
                normalizationGain = normalizationGain(activeRms, peak)
            )
        } catch (error: Throwable) {
            Log.w(TAG, "decode error", error)
            null
        } finally {
            try {
                codec?.stop()
            } catch (_: Throwable) {
            }
            codec?.release()
            extractor.release()
        }
    }

    private fun findAudioTrack(extractor: MediaExtractor): Int {
        for (index in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(index)
            val mime = format.getString(MediaFormat.KEY_MIME)
            if (mime?.startsWith("audio/") == true) return index
        }
        return -1
    }

    private fun appendMonoFloatS16(
        destination: FloatSampleBuffer,
        buffer: ByteBuffer,
        format: MediaFormat
    ) {
        val channels = if (format.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
            max(1, format.getInteger(MediaFormat.KEY_CHANNEL_COUNT))
        } else {
            1
        }
        val encoding = if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
            format.containsKey(MediaFormat.KEY_PCM_ENCODING)
        ) {
            format.getInteger(MediaFormat.KEY_PCM_ENCODING)
        } else {
            android.media.AudioFormat.ENCODING_PCM_16BIT
        }

        val view = buffer.order(ByteOrder.LITTLE_ENDIAN)
        when (encoding) {
            android.media.AudioFormat.ENCODING_PCM_FLOAT -> {
                val frames = view.remaining() / (channels * 4)
                for (frame in 0 until frames) {
                    var sum = 0f
                    for (channel in 0 until channels) {
                        sum += view.getFloat()
                    }
                    destination.add((sum / channels.toFloat()) * PCM_LIMIT)
                }
            }
            android.media.AudioFormat.ENCODING_PCM_8BIT -> {
                val frames = view.remaining() / channels
                for (frame in 0 until frames) {
                    var sum = 0f
                    for (channel in 0 until channels) {
                        sum += ((view.get().toInt() and 0xff) - 128) * 256f
                    }
                    destination.add(sum / channels.toFloat())
                }
            }
            else -> {
                val frames = view.remaining() / (channels * 2)
                for (frame in 0 until frames) {
                    var sum = 0f
                    for (channel in 0 until channels) {
                        sum += view.getShort().toFloat()
                    }
                    destination.add(sum / channels.toFloat())
                }
            }
        }
    }

    private fun applyEdgeFade(samples: FloatArray, sampleRate: Double) {
        val fadeFrames = min(samples.size / 2, max(1, (sampleRate * 0.005).toInt()))
        if (fadeFrames <= 1) return

        for (frame in 0 until fadeFrames) {
            val gain = frame.toFloat() / (fadeFrames - 1).toFloat()
            samples[frame] *= gain
            samples[samples.size - 1 - frame] *= gain
        }
    }

    private fun activeRms(samples: FloatArray, sampleRate: Double): Float {
        if (samples.isEmpty() || sampleRate <= 0.0) return 0f

        val blockFrames = max(1, (sampleRate * 0.05).toInt())
        val gateRms = (PCM_LIMIT * 10.0.pow(-50.0 / 20.0)).toFloat()
        var activeSquareSum = 0.0
        var activeSampleCount = 0
        var offset = 0

        while (offset < samples.size) {
            val end = min(offset + blockFrames, samples.size)
            var blockSquareSum = 0.0
            for (index in offset until end) {
                val value = samples[index].toDouble()
                blockSquareSum += value * value
            }

            val count = end - offset
            val blockRms = sqrt(blockSquareSum / max(count, 1).toDouble()).toFloat()
            if (blockRms >= gateRms) {
                activeSquareSum += blockSquareSum
                activeSampleCount += count
            }
            offset = end
        }

        if (activeSampleCount <= 0) return 0f
        return sqrt(activeSquareSum / activeSampleCount.toDouble()).toFloat()
    }

    private fun normalizationGain(activeRms: Float, peak: Float): Float {
        if (activeRms <= 0f || peak <= 0f) return 1f

        val targetRms = (PCM_LIMIT * 10.0.pow(-20.0 / 20.0)).toFloat()
        val peakCeiling = (PCM_LIMIT * 10.0.pow(-6.0 / 20.0)).toFloat()
        val rmsGain = targetRms / activeRms
        val peakGain = peakCeiling / peak

        return max(0.05f, min(8f, min(rmsGain, peakGain)))
    }
}

private class AudioMixerTap(
    private val engine: AudioMixerEngine,
    private val kind: MixerTapKind
) : AudioProcessingAdapter.ExternalAudioFrameProcessing {
    private var sampleRate = 0
    private var channels = 0
    private var loggedFormat = false
    private var loggedUnexpectedBuffer = false

    override fun initialize(sampleRateHz: Int, numChannels: Int) {
        sampleRate = sampleRateHz
        channels = numChannels
        Log.d(TAG, "$kind initialize rate=$sampleRateHz channels=$numChannels")
    }

    override fun reset(newRate: Int) {
        sampleRate = newRate
        loggedFormat = false
    }

    override fun process(numBands: Int, numFrames: Int, buffer: ByteBuffer) {
        if (channels <= 0 || buffer.remaining() % (channels * 2) != 0) {
            if (!loggedUnexpectedBuffer) {
                loggedUnexpectedBuffer = true
                Log.w(
                    TAG,
                    "$kind unexpected audio buffer shape: bytes=${buffer.remaining()} channels=$channels"
                )
            }
            return
        }

        val totalFrames = buffer.remaining() / (channels * 2)
        val outputSampleRate = fullBandSampleRate(sampleRate, totalFrames, numBands, numFrames)
        if (!loggedFormat) {
            loggedFormat = true
            Log.d(
                TAG,
                "$kind process frames=$numFrames totalFrames=$totalFrames channels=$channels " +
                    "bands=$numBands initializedRate=$sampleRate fullBandRate=$outputSampleRate"
            )
        }
        engine.mix(buffer, kind, outputSampleRate, channels)
    }

    private fun fullBandSampleRate(
        initializedRate: Int,
        totalFrames: Int,
        numBands: Int,
        framesPerBand: Int
    ): Double {
        if (totalFrames > 0) {
            return (totalFrames * 100).toDouble()
        }

        if (initializedRate <= 0) {
            return (max(framesPerBand, 1) * max(numBands, 1) * 100).toDouble()
        }

        if (numBands > 1 && framesPerBand > 0) {
            val perBandDerivedRate = framesPerBand * 100
            if (ratesApproximatelyEqual(initializedRate.toDouble(), perBandDerivedRate.toDouble())) {
                return initializedRate.toDouble() * numBands.toDouble()
            }
        }

        return initializedRate.toDouble()
    }

    private fun ratesApproximatelyEqual(lhs: Double, rhs: Double): Boolean {
        if (lhs <= 0.0 || rhs <= 0.0) return false
        return abs(lhs - rhs) <= max(lhs, rhs) * 0.05
    }
}

internal class AudioMixerController {
    private val engine = AudioMixerEngine()
    private val captureTap = AudioMixerTap(engine, MixerTapKind.CAPTURE)
    private val renderTap = AudioMixerTap(engine, MixerTapKind.RENDER)
    private var audioProcessingController: AudioProcessingController? = null

    var isAttached = false
        private set
    var trackId: String? = null
        private set

    fun attach(controller: AudioProcessingController, trackId: String) {
        if (isAttached) return

        // Android flutter_webrtc exposes one global processing controller, not
        // per-track audio processors. trackId validates/anchors lifecycle only.
        controller.capturePostProcessing.addProcessor(captureTap)
        controller.renderPreProcessing.addProcessor(renderTap)
        audioProcessingController = controller
        this.trackId = trackId
        isAttached = true
    }

    fun play(
        filePath: String,
        playId: String,
        volume: Float,
        loop: Boolean,
        playLocally: Boolean,
        sendToRemote: Boolean
    ): AudioMixerPlayResult {
        return engine.play(
            filePath,
            playId,
            volume,
            loop,
            playLocally,
            sendToRemote
        ) { isAttached }
    }

    fun stop(playId: String?) {
        engine.stop(playId)
    }

    fun setVolume(playId: String, volume: Float) {
        engine.setVolume(playId, volume)
    }

    fun detach() {
        val controller = audioProcessingController
        if (controller != null) {
            controller.capturePostProcessing.removeProcessor(captureTap)
            controller.renderPreProcessing.removeProcessor(renderTap)
        }
        engine.stop(null)
        audioProcessingController = null
        trackId = null
        isAttached = false
    }
}
