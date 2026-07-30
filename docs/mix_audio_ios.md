# MixAudio native handoff

## Problem

During a LiveKit call, native voice-call audio modes can duck or isolate audio
played through a separate player. The result is that local sounds may be quiet
for the user and may not be sent to remote participants.

## Solution

Use `MixAudio` to decode a local audio file and mix its PCM samples into the
LiveKit WebRTC audio graph instead of playing it through a separate player.

Supported platforms:

- iOS
- Android

Unsupported platforms return `null` from `MixAudio.start`.

## Architecture

```text
Flutter MixAudio
    -> MethodChannel "livekit_client"
        -> LiveKitPlugin
            -> AudioMixerController
                -> AudioMixerEngine
                -> capture tap
                -> render tap
```

| Path | iOS adapter | Android adapter | Plays when |
| --- | --- | --- | --- |
| Capture | `LocalAudioTrack.addProcessing` | `AudioProcessingController.capturePostProcessing` | `sendToRemote: true` |
| Render | `renderPreProcessingAdapter` | `AudioProcessingController.renderPreProcessing` | `playLocally: true` |

On iOS, the capture tap is attached to the selected `LocalAudioTrack`. On
Android, `flutter_webrtc` exposes audio processing through a single global
`AudioProcessingController`, so `trackId` validates that a local audio track
exists and anchors the mixer lifecycle, but the processing tap itself is global
to the WebRTC audio pipeline. Apps using multiple simultaneous local audio
tracks should treat Android mixing as pipeline-scoped, not strictly track-scoped.

## MethodChannel API

Channel: `livekit_client`

| Method | Args | Result |
| --- | --- | --- |
| `startAudioMixer` | `trackId` | `bool` |
| `playMixedAudio` | `filePath`, `playId`, `volume`, `loop`, `playLocally`, `sendToRemote` | `playId` |
| `stopMixedAudio` | `playId?` | `true` |
| `setMixedAudioVolume` | `playId`, `volume` | `true` |
| `stopAudioMixer` | `{}` | `true` |

Defaults: `playLocally: true`, `sendToRemote: true`.

## Dart API

```dart
final mixer = await MixAudio.start(localAudioTrack);

await mixer?.play(
  path,
  playLocally: true,
  sendToRemote: false,
);

await mixer?.play(
  path,
  playLocally: false,
  sendToRemote: true,
);

await mixer?.play(path);
await mixer?.dispose();
```

## Audio Quality

- Files are decoded at their native output rate and resampled to the WebRTC
  callback rate with linear interpolation.
- Each tap has an independent frame cursor (`captureReadPos` and
  `renderReadPos`) so local playback and remote send can be enabled separately.
- Files are normalized by active RMS with peak headroom, then overload is
  compressed with a soft knee instead of hard clipping.
- A short fade is applied to file edges to avoid clicks, especially with loops.

## Android Notes

- Decode runs on a background single-thread executor so `playMixedAudio` does
  not block the Flutter platform thread.
- Android decoding uses `MediaExtractor` and `MediaCodec`; supported formats are
  device/OS dependent. Commonly supported formats include WAV, MP3, AAC/M4A,
  and many container/codec combinations supported by Android media codecs.
- Decoded audio is currently loaded into memory before playback. This matches
  the current iOS implementation and is best suited for short sounds or bounded
  music clips. Very long tracks can use significant memory; streaming decode
  would require a larger native playback pipeline.
- `flutter_webrtc` currently provides 16-bit PCM buffers to
  `AudioProcessingAdapter`. The Android mixer validates the buffer shape and
  skips unexpected layouts instead of writing into a buffer it does not
  understand.

## Lifecycle

1. Call `MixAudio.start` after the microphone track is created or published.
2. If the microphone track is restarted, call `dispose`, then `start` again with
   the new track.
3. `playLocally: false` and `sendToRemote: false` is rejected.
4. `stop(playId)` stops one playback; `stop()` stops all active playbacks.
5. `dispose()` detaches capture/render taps and clears active playbacks.

## Quick Check

1. Publish a mic track.
2. `play(..., playLocally: true, sendToRemote: false)` should be heard locally
   only.
3. `play(..., playLocally: false, sendToRemote: true)` should be heard by remote
   participants only.
4. Pitch should stay close to the original file, without obvious clicks or
   clipping.
