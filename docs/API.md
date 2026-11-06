# Control API

All responses are JSON. Every POST/DELETE returns the full state, so the client never keeps its own copy.

| Method & path | Body | Effect |
|---|---|---|
| `GET /api/health` | | `{"ok":true}`, no token |
| `GET /api/state` | | Full state: status, position, outputs, devices, tracks, profiles |
| `POST /api/outputs` | `{"uids":["…","…"]}` | Select 1–2 present outputs, first = clock. Rebuilds, paused at 0 |
| `POST /api/transport` | `{"action":"play"\|"pause"\|"stop"}` | Stop = pause + seek 0 |
| `POST /api/seek` | `{"seconds":12.5}` | 0…duration |
| `POST /api/master` | `{"gain":0.5}` | 0…1 |
| `POST /api/output` | `{"uid":"…","delayMs":12,"gain":0.8}` | delay 0…2000 ms, gain 0…1, either optional |
| `POST /api/source` | `{"trackId":"…"}` or `{"trackId":null}` | Track or calibration click; paused at 0 |
| `PUT /api/tracks?name=song.mp3` | raw file bytes | Upload; returns the track (201) |
| `DELETE /api/tracks/{id}` | | Delete file; switches to click if it was playing |
| `POST /api/profiles` | `{"name":"Living room"}` | Save outputs + delays + gains + master |
| `POST /api/profiles/{name}/load` | | Apply the profile (devices matched by UID, then name) |
| `DELETE /api/profiles/{name}` | | |
| `POST /api/reconnect` | | Rebuild outputs at the current position, paused |

`status` is one of `noOutputs`, `loading`, `playing`, `paused`, `ended`, `error`. On a speaker loss: `error` plus a message, playback stopped, position kept, and nothing reroutes to the Mac speaker.

Example:

```sh
T=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/Library/Application Support/SpeakerSync/config.json')))['token'])")
curl -s -H "Authorization: Bearer $T" http://127.0.0.1:8095/api/state | python3 -m json.tool
```
