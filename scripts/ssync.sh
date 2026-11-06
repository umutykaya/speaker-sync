#!/bin/zsh
# Manage ssyncd as a per-user LaunchAgent (starts at login, restarts on crash).
#   scripts/ssync.sh install    build, copy to the app folder, (re)load the agent
#   scripts/ssync.sh uninstall  stop and remove the agent (keeps settings and music)
#   scripts/ssync.sh status     is it loaded, listening, and reachable?
#   scripts/ssync.sh link       print the pairing link
#   scripts/ssync.sh logs       follow the log
#   scripts/ssync.sh restart    restart the running agent
#   scripts/ssync.sh start      load the installed agent again after stop
#   scripts/ssync.sh stop       stop the agent until start or next login (keeps it installed)
#   scripts/ssync.sh rotate-token  new pairing token (old links stop working)
set -euo pipefail

ROOT=${0:A:h:h}
LABEL=local.speakersync.ssyncd
DOMAIN=gui/$(id -u)
SUPPORT="$HOME/Library/Application Support/SpeakerSync"
APP="$SUPPORT/app"
BUNDLE="$APP/SpeakerSync.app"
BIN="$BUNDLE/Contents/MacOS/ssyncd"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGDIR="$HOME/Library/Logs/SpeakerSync"
LOG="$LOGDIR/ssyncd.log"
PORT=8095

loaded() { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }

lan_ip() {
  for i in en0 en1 en2; do ipconfig getifaddr $i 2>/dev/null && return; done
  return 1
}

link() {
  local token ip
  token=$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["token"])' "$SUPPORT/config.json")
  ip=$(lan_ip) || { echo "no LAN address found (is Wi-Fi/Ethernet up?)" >&2; exit 1; }
  echo "http://$ip:$PORT/#token=$token"
}

install() {
  echo "==> building web UI"
  (cd "$ROOT/web" && npm ci --silent && npm run --silent build)
  echo "==> building ssyncd"
  (cd "$ROOT" && swift build -c release --product ssyncd 2>&1 | tail -1)

  if loaded; then launchctl bootout "$DOMAIN/$LABEL" || true; sleep 1; fi
  if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $PORT is in use by another process (a manual ssyncd?). Stop it first:" >&2
    lsof -nP -iTCP:$PORT -sTCP:LISTEN >&2
    exit 1
  fi

  echo "==> installing to $APP"
  mkdir -p "$APP" "$LOGDIR" "$HOME/Library/LaunchAgents"
  rm -rf "$APP/web" "$APP/ssyncd"
  cp -R "$ROOT/web/dist" "$APP/web"
  # A minimal app bundle: macOS ties the System Audio Recording permission
  # (needed for live Spotify / Mac audio) to a bundle identity.
  mkdir -p "$BUNDLE/Contents/MacOS"
  cp "$ROOT/.build/release/ssyncd" "$BIN.new" && mv -f "$BIN.new" "$BIN"
  cat > "$BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>SpeakerSync</string>
  <key>CFBundleExecutable</key><string>ssyncd</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>SpeakerSync plays your Mac's audio (for example Spotify) on your Bluetooth speakers.</string>
</dict>
</plist>
EOF
  plutil -lint "$BUNDLE/Contents/Info.plist" >/dev/null
  # Ad-hoc signature gives the bundle an identity. A rebuild changes it, so
  # macOS may ask for the audio permission again after reinstalling.
  codesign --force --sign - --identifier "$LABEL" "$BUNDLE"

  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>EnvironmentVariables</key><dict><key>SSYNC_WEB</key><string>$APP/web</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
  plutil -lint "$PLIST" >/dev/null
  launchctl bootstrap "$DOMAIN" "$PLIST"
  sleep 2
  status
  cat <<EOF

Firewall: the installed binary is a new path. If the iPhone cannot connect, allow it (asks for your password):
  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "$BIN"
  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp "$BIN"

Live audio (Spotify / all Mac audio): the first time you pick a live source, macOS should ask
to allow SpeakerSync to record system audio. If it doesn't, or the source stays silent:
  System Settings → Privacy & Security → Screen & System Audio Recording →
  System Audio Recording Only → + → choose $BUNDLE
EOF
}

uninstall() {
  if loaded; then launchctl bootout "$DOMAIN/$LABEL"; fi
  rm -f "$PLIST"
  rm -rf "$APP"
  echo "agent removed. Settings and music kept in: $SUPPORT"
}

status() {
  if loaded; then
    local pid
    pid=$(launchctl print "$DOMAIN/$LABEL" | awk '/^\tpid = / {print $3}')
    echo "agent:     loaded${pid:+, pid $pid}"
  else
    echo "agent:     not loaded (run: scripts/ssync.sh install)"
  fi
  if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT: listening"; else echo "port $PORT: NOT listening"; fi
  local ip
  if ip=$(lan_ip); then
    if curl -s -m 3 "http://$ip:$PORT/api/health" | grep -q '"ok":true'; then
      echo "LAN check: http://$ip:$PORT/api/health OK"
    else
      echo "LAN check: http://$ip:$PORT/api/health FAILED"
    fi
  fi
  [[ -f "$LOG" ]] && { echo "--- last log lines ($LOG)"; tail -n 5 "$LOG" | sed -E 's/token=[0-9a-f]+/token=<hidden: run scripts\/ssync.sh link>/'; }
}

case "${1:-}" in
  install) install ;;
  uninstall) uninstall ;;
  status) status ;;
  link) link ;;
  logs) tail -f "$LOG" ;;
  restart) launchctl kickstart -k "$DOMAIN/$LABEL" && sleep 2 && status ;;
  start)
    [[ -f "$PLIST" ]] || { echo "not installed (run: scripts/ssync.sh install)" >&2; exit 1; }
    loaded || launchctl bootstrap "$DOMAIN" "$PLIST"
    sleep 2 && status ;;
  stop) if loaded; then launchctl bootout "$DOMAIN/$LABEL"; fi; echo "agent stopped" ;;
  rotate-token) "$BIN" --rotate-token && launchctl kickstart -k "$DOMAIN/$LABEL" && sleep 2 && link ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
