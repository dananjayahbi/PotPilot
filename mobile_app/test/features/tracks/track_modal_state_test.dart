import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/features/tracks/audio_sub_modal.dart';

TrackModalState _state({
  int audioIndex = 1,
  int subIndex = 1,
  bool subsOn = false,
  int syncOffsetMs = 0,
  String? fileTitle = 'Interstellar',
}) {
  return TrackModalState(
    audioIndex: audioIndex,
    subIndex: subIndex,
    subsOn: subsOn,
    syncOffsetMs: syncOffsetMs,
    fileTitle: fileTitle,
  );
}

void main() {
  group('apply — optimistic track cycling', () {
    test('cycleAudio advances the 1-based local counter', () {
      final TrackModalState next = _state().apply(TrackAction.cycleAudio);
      expect(next.audioIndex, 2);
      expect(next.subIndex, 1);
      expect(next.subsOn, false);
      expect(next.syncOffsetMs, 0);
      expect(next.fileTitle, 'Interstellar');
    });

    test('cycleSubs advances the sub counter only', () {
      final TrackModalState next = _state().apply(TrackAction.cycleSubs);
      expect(next.audioIndex, 1);
      expect(next.subIndex, 2);
    });

    test('counters wrap to 1 at kMaxOptimisticTracks', () {
      expect(kMaxOptimisticTracks, 8);
      TrackModalState audio = _state(audioIndex: 7);
      audio = audio.apply(TrackAction.cycleAudio);
      expect(audio.audioIndex, 8);
      audio = audio.apply(TrackAction.cycleAudio);
      expect(audio.audioIndex, 1, reason: 'audio wraps at 8 -> 1');

      TrackModalState subs = _state(subIndex: 7);
      subs = subs.apply(TrackAction.cycleSubs);
      expect(subs.subIndex, 8);
      subs = subs.apply(TrackAction.cycleSubs);
      expect(subs.subIndex, 1, reason: 'subs wrap at 8 -> 1');
    });

    test('toggleSubs flips the optimistic boolean', () {
      expect(_state(subsOn: false).apply(TrackAction.toggleSubs).subsOn, true);
      expect(_state(subsOn: true).apply(TrackAction.toggleSubs).subsOn, false);
    });
  });

  group('apply — subtitle sync accumulate/clamp', () {
    test('nudges step by exactly ±500 ms', () {
      expect(
        _state().apply(TrackAction.syncMinus).syncOffsetMs,
        -500,
      );
      expect(_state().apply(TrackAction.syncPlus).syncOffsetMs, 500);
      expect(
        _state(syncOffsetMs: -500).apply(TrackAction.syncPlus).syncOffsetMs,
        0,
      );
    });

    test('clamps at −10000 / +10000 (frozen ±10000 ms bound)', () {
      TrackModalState state = _state();
      for (int i = 0; i < 30; i++) {
        state = state.apply(TrackAction.syncMinus);
      }
      expect(state.syncOffsetMs, -kSyncMaxMs);
      expect(state.atLowerSyncBound, true);
      expect(state.atUpperSyncBound, false);
      // Further nudges never escape the clamp.
      expect(state.apply(TrackAction.syncMinus).syncOffsetMs, -kSyncMaxMs);

      state = _state();
      for (int i = 0; i < 30; i++) {
        state = state.apply(TrackAction.syncPlus);
      }
      expect(state.syncOffsetMs, kSyncMaxMs);
      expect(state.atUpperSyncBound, true);
      expect(state.atLowerSyncBound, false);
      expect(state.apply(TrackAction.syncPlus).syncOffsetMs, kSyncMaxMs);

      // One step back re-opens the bound.
      expect(
        state.apply(TrackAction.syncMinus).atUpperSyncBound,
        false,
      );
    });
  });

  group('syncFile — §4.4 reset boundary', () {
    test('fileTitle change resets counters/offset/toggle to defaults', () {
      final TrackModalState dirty = _state(
        audioIndex: 5,
        subIndex: 3,
        subsOn: true,
        syncOffsetMs: -2500,
        fileTitle: 'Arrival',
      );
      final TrackModalState reset = dirty.syncFile('Blade Runner');
      expect(reset.audioIndex, 1);
      expect(reset.subIndex, 1);
      expect(reset.subsOn, false);
      expect(reset.syncOffsetMs, 0);
      expect(reset.fileTitle, 'Blade Runner');
    });

    test('null → non-null also resets', () {
      final TrackModalState idle = _state(fileTitle: null, subsOn: true);
      final TrackModalState reset = idle.syncFile('Dune');
      expect(reset.fileTitle, 'Dune');
      expect(reset.subsOn, false);
      expect(reset.syncOffsetMs, 0);
    });

    test('identical fileTitle is identity — staleness alone never resets', () {
      final TrackModalState state = _state(
        audioIndex: 4,
        syncOffsetMs: 3000,
        fileTitle: 'Interstellar',
      );
      final TrackModalState same = state.syncFile('Interstellar');
      expect(
        identical(same, state),
        isTrue,
        reason: 'stale (unchanged) telemetry must not touch local state',
      );
      expect(same.audioIndex, 4);
      expect(same.syncOffsetMs, 3000);
      // Null stays null too.
      final TrackModalState idle = _state(fileTitle: null);
      expect(identical(idle.syncFile(null), idle), isTrue);
    });
  });
}
