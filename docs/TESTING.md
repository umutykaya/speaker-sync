# Testing

## Automated

```sh
swift test                       # validation, device matching, token compare, LAN filter
(cd web && npm run check)        # strict TypeScript type-check of the UI
```

Audio, Bluetooth and iPhone behaviour can only be tested by hand on the real hardware. The procedures and recorded results are below.

## Results so far

| Date | Test | Result |
|---|---|---|
| 2026-11-06 | Both JBLs open in one aggregate (CLI) | Pass: 4 channels at 44.1 kHz |
| 2026-11-06 | Concurrent playback, click track, about 9 min (CLI) | Pass: 0 overloads, no audible dropouts |
| 2026-11-06 | Go 4 played only the accented clicks | Fixed: all clicks at equal level; then all clicks audible |
| 2026-11-06 | Relative timing at 0 ms delay | Go 4 slightly late; "not very significant" by ear |
| 2026-11-06 | Drift over about 9 min | None audible |
| 2026-11-06 | Go 4 switched off during playback (CLI) | Pass: playback stopped, no sound from the Mac speaker |
| 2026-11-06 | Service with both JBLs, disconnect, Reconnect, iPhone reaching `/api/health` | Pass |
| 2026-11-06 | LaunchAgent: start, crash restart (`kill -9`), LAN health check | Pass (restarted within 12 s) |
| 2026-11-06 | Web UI on iPhone Safari | **Pending** |
| — | 30+ minute drift test | **Pending** |
| — | Saved delay still aligned after 3 speaker reconnects | **Pending** |

## Long-run drift test (acceptance)

1. Calibrate with the click until you hear one click. Note both delays and save a profile.
2. Play a long track or playlist-length file for **at least 30 minutes**.
3. Every 10 minutes, listen close to the midpoint between the speakers. Note: aligned / slight echo / clear echo.
4. At the end, switch to the calibration click (same delays). If it flams, nudge until aligned and note **how many ms** you had to change.
5. Record the result in the table above: duration, drift in ms (0 if none), any dropouts.

Interpretation: a growing offset means drift compensation is not keeping the Go 4 locked to the Charge 5 clock. A constant offset that was fine at the start is not drift.

## Reconnect test (acceptance)

Repeat 3 times:
1. Turn the Go 4 off; the UI shows the red banner.
2. Turn it on, wait for macOS to reconnect it, tap **Reconnect**.
3. Play the click with the saved profile. Is it still one click? If not, note the ms you had to nudge.

If the needed delay changes after reconnects, saved offsets are only a starting point and quick re-calibration is required after each reconnect.

## Restart test (acceptance)

1. `scripts/ssync.sh restart` (or reboot and log in).
2. Reload the page. Outputs, delays, gains, source and profiles must be restored, and the status must be **Paused**.

## Phase 1 (milestone 1): feasibility tests on your hardware

These tests need your speakers. I cannot run them.

#### Prerequisites

1. Turn off PartyBoost / Auracast linking on both speakers. Disconnect them from your phone.
2. System Settings → Bluetooth: connect **JBL Go 4** and **JBL Charge 5** to the Mac. Both must show "Connected".

#### Test A: Audio MIDI Setup (no code)

1. Open `/System/Applications/Utilities/Audio MIDI Setup.app`.
2. Select each JBL device in the left list. Write down its **Format** (for example `2 ch 48 000 Hz` or `44 100 Hz`). If either shows a low rate such as 16 000 Hz or 24 000 Hz, it is in the headset (HFP) profile. Note that.
3. Click **+** → **Create Multi-Output Device**. Tick both JBLs. Set **Clock Source / Primary Device** to the Charge 5. Tick **Drift Correction** on the Go 4 only.
4. System Settings → Sound → Output → select the Multi-Output Device. Play music (Music app) for at least 5 minutes.
5. Observe and record:
   - Do both speakers play? Any dropouts or stutter on either?
   - Is there an audible offset (echo/flam)? Roughly how large?
   - Does the offset stay the same over 5 minutes, or grow?
6. Untick Drift Correction on the Go 4 and repeat for 5–10 minutes. A slowly growing offset here shows that drift compensation is needed.
7. Optional: click **+** → **Create Aggregate Device**, tick both. It should show 4 output channels.
8. While playing through the Multi-Output Device, turn one speaker off. Record what happens: does the other keep playing, does sound move to the Mac speaker, does everything stop?
9. Reset System Settings → Sound → Output to your normal device afterwards.

**Expected (not guaranteed):** both play, with a constant offset of tens to a few hundred ms. If both cannot play at once without stutter, the Bluetooth radio cannot sustain two A2DP streams in your setup. That is a blocker for this design. Tell me before we build anything else.

#### Test B: the proof of concept

```sh
swift build -c release
.build/release/ssync-poc list                     # copy the uid= lines of both JBLs
```

Click track at low volume, Charge 5 as clock:

```sh
.build/release/ssync-poc play --out '<CHARGE5_UID>' --out '<GO4_UID>' --click --master 0.3
```

Put the speakers side by side, about 1 m from your ears. Then, typing one command per line:

1. `g 2 0` — hear speaker 1 only. `g 2 1` then `g 1 0` — hear speaker 2 only. This confirms channel routing.
2. `g 1 1` — both. If you hear a double click (flam), find out which speaker is early by muting each in turn.
3. Delay the **early** one: `d 1 +20` or `d 2 +20` until the flam flips sides, then go back with `-5`, then `-1`/`+1`, until you hear one click.
4. Write down both delays.

Long-run drift test with your own file, using the delays you found:

```sh
.build/release/ssync-poc play --out '<CHARGE5_UID>' --out '<GO4_UID>' --file ~/Music/song.m4a --delay1 <ms> --delay2 <ms> --master 0.3
```

Every 10 seconds a status line prints position, delays and the HAL overload counter. After 30 minutes, run the click track again with the same delays. If the alignment has moved, report how far (the number of ms you had to nudge).

Reconnect test: quit, turn the Go 4 off and on, reconnect, run the click with the saved delays. Record whether they still align. Repeat 3 times.

Disconnect test: during playback, turn one speaker off. **Expected:** `DEVICE LOST … playback stopped` and exit code 3. Sound must **not** come out of the Mac's own speaker.

#### What to send back

- `ssync-poc list` output with both speakers connected.
- Answers from Test A, steps 2, 5, 6 and 8.
- From Test B: delays found, overload count, drift after 30 min, reconnect results, disconnect behaviour.

### PoC command reference

```
ssync-poc list
ssync-poc play --out <UID> [--out <UID>] (--file <path> | --click)
               [--delay1 ms] [--delay2 ms] [--master 0..1]

Interactive:  d <n> <ms> | d <n> +<ms> | d <n> -<ms>   delay of output n (1|2), 0..2000 ms
              g <n> <0..1>   output gain    m <0..1>   master gain
              p  pause/resume   s <sec>  seek   i  device info   q  quit
```

### Known PoC limitations

- The whole file is decoded into memory (about 23 MB per minute at 48 kHz stereo float).
- Speakers must be selected by UID on the command line.
- On device loss the PoC exits. The service instead stops, reports, and waits for Reconnect.
- The render callback reaches a Swift class through an unretained pointer. It reads only atomics and preallocated buffers. It has not yet been profiled for real-time safety.
