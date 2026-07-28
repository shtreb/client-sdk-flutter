# MixAudio (iOS) — handoff

## Проблема

Во время LiveKit-звонка `AVAudioSession` в режимах `voiceChat` / `videoChat` приглушает (duck) сторонние плееры (`audioplayers`, `AVAudioPlayer` и т.п.). Звуки вне LiveKit слышны тише локально и часто **не уходят** remote-участникам.

## Решение

Не играть файл отдельным плеером, а **микшировать PCM файла в WebRTC audio graph** через `ExternalAudioProcessingDelegate` из `flutter_webrtc`.

Платформа: **только iOS**. Android / macOS / web — нет реализации.

---

## Архитектура

```
Flutter MixAudio
    → MethodChannel "livekit_client"
        → LiveKitPlugin (iOS)
            → AudioMixerController
                ├─ AudioMixerEngine          // shared playbooks + decode/mix
                ├─ AudioMixerTap(.capture)   // → LocalAudioTrack.addProcessing
                └─ AudioMixerTap(.render)    // → renderPreProcessingAdapter
```

| Путь | Adapter | Когда микшируется |
|------|---------|-------------------|
| **Capture** | `capturePostProcessingAdapter` | `sendToRemote: true` |
| **Render** | `renderPreProcessingAdapter` | `playLocally: true` |

Два отдельных tap'а (не один processor на оба adapter), иначе нельзя независимо фильтровать local/remote. Позиция playback общая и идёт по `CACurrentMediaTime`.

Post-processing идёт **после** AEC/NS/AGC.

---

## Ключевые файлы

| Файл | Роль |
|------|------|
| `shared_swift/AudioMixer.swift` | Engine + taps + controller |
| `shared_swift/LiveKitPlugin.swift` | MethodChannel handlers (`#if os(iOS)`) |
| `shared_swift/LocalAudioTrack.swift` | `add/remove(processing:)` wrappers |
| `ios/Classes/AudioMixer.swift` | symlink → `shared_swift/` |
| `lib/src/track/audio_mixer.dart` | публичный Dart API `MixAudio` |
| `lib/src/support/native.dart` | `invokeMethod` wrappers |
| `lib/livekit_client.dart` | export |
| `docs/mix_audio_ios.md` | этот документ |

---

## MethodChannel API (iOS only)

Channel: `livekit_client`

| Method | Args | Result |
|--------|------|--------|
| `startAudioMixer` | `trackId` | `bool` |
| `playMixedAudio` | `filePath`, `playId`, `volume`, `loop`, **`playLocally`**, **`sendToRemote`** | `playId` |
| `stopMixedAudio` | `playId?` | `true` |
| `setMixedAudioVolume` | `playId`, `volume` | `true` |
| `stopAudioMixer` | `{}` | `true` |

Defaults: `playLocally: true`, `sendToRemote: true`.

---

## Dart API

```dart
final mixer = await MixAudio.start(localAudioTrack);

// Только себе (remote НЕ слышит):
await mixer?.play(
  path,
  playLocally: true,
  sendToRemote: false,
);

// Только remote (локально не играть через render):
await mixer?.play(
  path,
  playLocally: false,
  sendToRemote: true,
);

// И себе, и remote (default):
await mixer?.play(path);

await mixer?.dispose();
```

---

## Качество звука / анти-искажения

Типичные причины «сильного» искажения и что сделано:

1. **Sample rate split-band буфера**
   `audioProcessingInitialize` может сообщить rate одной полосы (например,
   16 kHz), хотя `rawBuffer` содержит full-band кадры 48 kHz. Mixer определяет
   полную частоту по `frames`, `bands` и `framesPerBand`; иначе cursor двигался
   в три раза быстрее.

2. **Wall-clock позиция (`CACurrentMediaTime`)**
   Callbacks не идеально равномерны → skip/repeat кусков.
   → у каждого tap свой **frame cursor** (`captureReadPos` / `renderReadPos`), двигается на `frames * (fileRate/deviceRate)` за callback.

3. **Неправильный soft-clip и перегруз при суммировании**
   Старый soft-clip менял даже тихий сигнал, а hard clamp хрипел на каждом
   перегруженном пике. Теперь файл автоматически нормализуется по active RMS
   примерно к `-20 dBFS`, его пики удерживаются ниже `-6 dBFS`, а зона
   перегруза сжимается плавно. Параметр `volume` работает как относительная
   поправка поверх автоматической нормализации.

4. **MP3 decode** одним `read` иногда неполный.
   → chunked read через `AVAudioFile` до EOF.

5. Файл декодируется в **native rate** (для тестового CDN mp3 это 48 kHz stereo → mono FloatS16), ресемпл в device rate через linear interpolation.

6. На первых и последних 5 ms файла применяется короткий fade, чтобы начало,
   окончание и loop не создавали щелчок из-за разрыва waveform.

Формат WebRTC `RTCAudioBuffer.rawBuffer`: **FloatS16**, не `[-1, 1]`.

В Xcode console при старте/play смотри логи:
`[LiveKit] AudioMixer: render initialize rate=...`
`[LiveKit] AudioMixer: loaded N samples @ RATE Hz, peak=...`

---

## Поддерживаемые аудиоформаты

Декод через **`AVAudioFile`** (AVFoundation).

Обычно OK: **WAV**, **CAF**, **AIFF**, **MP3**, **M4A/AAC**, **ALAC**.

Нужен локальный filesystem path; asset → сначала в temp. Файл целиком в память. Opus/Ogg/FLAC могут не открыться.

Рекомендация для SFX: короткий **WAV** или **M4A**.

---

## Lifecycle / pitfalls

1. `MixAudio.start` **после** publish/create mic (`localTracks[trackId]` должен существовать).
2. Restart mic → `dispose` + `start` на новый track.
3. `playLocally: false` + `sendToRemote: false` → ошибка / `null`.
4. Render tap слышен, когда активен WebRTC audio unit (типичный звонок).
5. Не путать с отдельным published audio track — это mix в mic/render graph.

---

## Быстрая проверка

1. Mic published на iOS.
2. `play(..., playLocally: true, sendToRemote: false)` → слышно локально, remote **не** слышит.
3. `play(..., playLocally: false, sendToRemote: true)` → remote слышит, локально через render нет.
4. Звук без сильного chipmunk/хрипа; pitch близок к оригиналу.
