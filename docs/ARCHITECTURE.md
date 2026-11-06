# Architecture

```
iPhone Safari ──HTTP JSON + 1 s polling (LAN, token)──► Swift service (single process)
                                                  ├─ HTTP server (Hummingbird 2)
                                                  ├─ transport state, profiles (JSON on disk)
                                                  └─ audio engine
                                                       ├─ private aggregate device
                                                       │    sub 1 = clock device
                                                       │    sub 2 = drift-compensated
                                                       └─ one AUHAL output unit
                                                            render callback:
                                                            out n = source[playhead − delay_n] × gain_n × master
```

- **One process.** The API server lives in the Swift service. A separate Node process would add IPC and a second thing to supervise, and buys nothing.
- **Polling, not WebSocket.** The browser polls `GET /api/state` about once per second while visible, and every command returns the full state. Each poll is a fresh read of the Mac's authoritative state, so an iPhone that locks or drops off Wi-Fi resyncs on its next request with no reconnect logic. A WebSocket or SSE push can be added later if 1 s position updates feel too coarse.
- **One render callback, one timeline.** Both speakers read the same decoded buffer, so the app-side relationship between them is exact. Each speaker reads at its own delay offset.
- **Clock mismatch:** the HAL's aggregate drift compensation resamples the non-clock sub-device to follow the clock device. The app does no resampling of its own.
- **Fixed latency:** Bluetooth stacks and speaker DSP add a fixed delay, different per speaker, that the HAL does not report fully. The user corrects it by ear, by delaying the earlier speaker. Drift compensation does nothing for this.

## Terms

- **Multi-output device** (Audio MIDI Setup): a "stacked" aggregate. The same signal goes to every sub-device. No per-device delay or gain.
- **Aggregate device**: sub-device channels are concatenated (for example 2 + 2 = 4 output channels). An app can write different signals to each channel range. This is what the engine uses, created privately in code.
- **Drift correction / compensation**: the HAL resamples a sub-device so its long-term rate follows the clock device. It prevents a slowly growing offset. It does not remove a fixed offset.
- **Fixed output latency**: time from the app writing a sample to sound leaving a speaker. For Bluetooth this includes codec buffering and speaker DSP, typically far more than the HAL reports. Only listening (or a microphone) reveals it.

## What app-side scheduling does not guarantee

The app knows exactly which sample it hands to each channel range. It does not know when each speaker emits it. The delay controls only shift the app-side relationship. Bluetooth latency can also change after a reconnect, a codec change, or a speaker firmware buffer adjustment. **Sample-accurate synchronisation across these speakers is not promised.**

## Delay changes during playback

A delay change of Δ ms means one speaker must either repeat or skip Δ ms of audio. The engine crossfades over 30 ms between the old and new read positions. This avoids a click; you may hear a brief smear. Pause and seek ramp the master gain to silence over about 10 ms before stopping or jumping.

## Storage

`~/Library/Application Support/SpeakerSync/` (override with `SSYNC_HOME`):
- `config.json`: token, selected outputs with delay/gain, master, profiles, current source.
- `tracks.json` + `library/<uuid>.<ext>`: uploaded files. Each file stays until deleted through the API. Limits: 500 MB per file, 5 GB total. Accepted types: mp3, m4a, aac, wav, aif/aiff, caf, flac. Each upload is checked by opening it as audio; anything else is deleted and rejected. Partial uploads are removed at the next start.

## Device identity

Outputs are stored by CoreAudio UID (the Bluetooth MAC address for these speakers) plus the display name. At start or Reconnect, outputs are matched by UID first. If a UID is missing, the service uses a present device with the same name, but only if exactly one has it. It then updates the UID and reports a notice. If neither works, it reports that the speaker is not connected and stays stopped.

## Sleep

While audio is playing, `ssyncd` holds a `PreventUserIdleSystemSleep` power assertion (visible in `pmset -g assertions` as "Speaker Sync is playing"). It releases the assertion on pause, stop, end of track or speaker loss, so the Mac can idle-sleep normally otherwise. Closing the lid or choosing Sleep manually still sleeps the Mac.

## Process model

`ssyncd` runs as a per-user LaunchAgent (`~/Library/LaunchAgents/local.speakersync.ssyncd.plist`), not a system daemon. Bluetooth audio devices belong to the logged-in user's session, so the service only runs while you are logged in. With FileVault on, the Mac must be unlocked once after boot.
