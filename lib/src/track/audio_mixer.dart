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

import 'package:uuid/uuid.dart';

import '../logger.dart';
import '../support/native.dart';
import '../support/platform.dart';
import 'local/audio.dart';

/// iOS-only helper that mixes audio files into the published LiveKit microphone
/// stream (and local render path).
///
/// Use this instead of a separate audio player while in a LiveKit call: session
/// modes like `voiceChat` / `videoChat` duck third-party playback, so remote
/// (and local) listeners hear those sounds quieter. Mixing into the WebRTC
/// graph keeps levels consistent.
///
/// Example:
/// ```dart
/// final mixer = await MixAudio.start(localAudioTrack);
/// final playId = await mixer?.play('/path/to/sound.wav');
/// await mixer?.stop(playId);
/// await mixer?.dispose();
/// ```
class MixAudio {
  MixAudio._(this._trackId);

  static const _uuid = Uuid();

  final String _trackId;
  bool _disposed = false;

  /// Starts the native mixer on [track]. Returns `null` on unsupported
  /// platforms or if the native attach fails.
  ///
  /// Call after the microphone track is created / published.
  static Future<MixAudio?> start(LocalAudioTrack track) async {
    if (!isSupported) {
      logger.warning('MixAudio is only supported on iOS');
      return null;
    }

    final trackId = track.mediaStreamTrack.id;
    if (trackId == null) {
      logger.warning('MixAudio: track has no mediaStreamTrack.id');
      return null;
    }

    final ok = await Native.startAudioMixer(trackId);
    if (!ok) {
      return null;
    }
    return MixAudio._(trackId);
  }

  /// Whether the current platform supports [MixAudio].
  static bool get isSupported => lkPlatformIs(PlatformType.iOS);

  /// Plays an audio file from a local filesystem [filePath].
  ///
  /// Returns a [playId] that can be passed to [stop] / [setVolume], or `null`
  /// on failure.
  ///
  /// Flutter asset files must be copied to a temporary path first.
  Future<String?> play(
    String filePath, {
    double volume = 1.0,
    bool loop = false,
    String? playId,
  }) async {
    if (_disposed) {
      logger.warning('MixAudio.play called after dispose');
      return null;
    }
    final id = playId ?? _uuid.v4();
    return Native.playMixedAudio(
      filePath,
      playId: id,
      volume: volume,
      loop: loop,
    );
  }

  /// Stops a single playback ([playId]) or all active playbooks when omitted.
  Future<void> stop([String? playId]) async {
    if (_disposed) return;
    await Native.stopMixedAudio(playId: playId);
  }

  /// Updates volume for an active playback (`1.0` = original file level).
  Future<void> setVolume(String playId, double volume) async {
    if (_disposed) return;
    await Native.setMixedAudioVolume(playId, volume);
  }

  /// Detaches the mixer from the WebRTC audio graph.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await Native.stopAudioMixer();
  }

  /// Track id this mixer was started with.
  String get trackId => _trackId;
}
