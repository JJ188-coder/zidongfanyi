# Lecture development handoff

Updated: 2026-09-01

This branch is a work-in-progress snapshot for continuing development of the
local macOS lecture assistant. The UI direction has been accepted; prioritize
runtime reliability rather than redesigning it.

## Implemented in this snapshot

- Local Whisper CLI transcription for live English and post-class review.
- Local 16 kHz mono PCM conversion and temporary WAV handling.
- Apple offline English-to-Chinese translation, including a clear language-pack
  installation path when the system assets are missing.
- DeepSeek text correction, summaries, and referenced Q&A. Audio must never be
  sent to DeepSeek.
- Local web UI, history, recordings, timeline, markers, export, and menu-bar
  reopening.
- Stable application/helper bundle identifiers and packaged Whisper runtime
  libraries.
- Cleanup for repeated AVAudioEngine tap installation and low-sample-rate AAC
  bitrate configuration.
- A deadlock fix in `LiveSpeechTranscriber.finish()` that resumes continuations
  after releasing its state lock.

## Known unfinished issues

1. Real microphone capture still needs hardware verification and may currently
   fail or produce no usable samples on the active input device.
2. The microphone level indicator appears static. Its dB mapping, smoothing,
   decay, and zero-on-stop behavior need end-to-end verification.
3. Rapid/repeated start and stop requests are not yet fully idempotent. They can
   report that a lecture is already recording or that the runtime is switching
   state. The coordinator should coalesce duplicate requests and return the same
   lecture instead of throwing.
4. The most recent transcriber finish/deadlock change has not completed a full
   build, install, and real-microphone regression pass.
5. Do not merge this branch into `main` until the complete acceptance and
   security checks pass.

## Operating constraints

- Drive validation through Lecture's local `/api/*` endpoints instead of
  simulated mouse clicks.
- The DeepSeek API key belongs only in macOS Keychain. Never print, read back,
  log, or commit it.
- Do not print or commit the local web authentication token.
- Preserve existing user lecture data, especially lecture ID
  `68DD858E-19AE-46B3-822B-3F334F256E83`.
- Keep the feature branch after eventual merge.

## Suggested next steps

1. Fix and verify real microphone capture.
2. Make the audio meter visibly respond to silence and known playback.
3. Make start/stop API operations idempotent under rapid and concurrent calls.
4. Run the Swift tests, JavaScript syntax check, application packaging, API-only
   end-to-end checks, overwrite-install permission check, and security scan.
5. Only after all evidence passes, merge to `main`, retest, and push.
