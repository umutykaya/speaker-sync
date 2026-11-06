// Speaker Sync remote. The Mac is authoritative: this page never keeps its own
// copy of playback state. It polls GET /api/state while visible, and every
// command returns the full state, which replaces whatever is on screen.

type MatchKind = "uid" | "name" | "missing";
type Status = "noOutputs" | "loading" | "playing" | "paused" | "ended" | "error";

interface OutputState {
  uid: string; name: string; delayMs: number; gain: number; matchedBy: MatchKind;
  limitEnabled: boolean; limitDb: number; limitingDb?: number;
}
interface DeviceState { uid: string; name: string; transport: string; channels: number; sampleRate: number }
interface Track { id: string; name: string; bytes: number; durationSeconds: number; addedAt: string }
interface ProfileState { name: string; savedAt: string; outputs: string[] }
interface State {
  status: Status;
  error?: string;
  notices: string[];
  positionSeconds: number;
  durationSeconds: number;
  source: { kind: "click" | "track" | "live"; trackId?: string; name: string };
  master: number;
  outputs: OutputState[];
  devices: DeviceState[];
  tracks: Track[];
  profiles: ProfileState[];
  sampleRate?: number;
  inputLevelDb?: number;
  liveSilentSeconds?: number;
  serverTime: string;
}

const TOKEN_KEY = "ssync.token";
const MUTE_KEY = "ssync.unmuteGain";
const POLL_MS = 1000;
const MAX_DELAY = 2000;
const MAX_OUTPUTS = 8;
const LIVE_SOURCES: [string, string, string][] = [
  ["com.spotify.client", "Spotify", "Whatever Spotify plays on this Mac"],
  ["all", "All Mac audio", "Every app, including notification sounds"],
];

const $ = <T extends HTMLElement = HTMLElement>(id: string): T => {
  const el = document.getElementById(id);
  if (!el) throw new Error(`missing #${id}`);
  return el as T;
};

function store(key: string, value?: string | null): string | null {
  // Storage can throw in private mode; the page must still work without it.
  try {
    if (value === undefined) return localStorage.getItem(key);
    if (value === null) localStorage.removeItem(key);
    else localStorage.setItem(key, value);
  } catch { /* ignore */ }
  return null;
}

// ---------- API ----------

class HttpError extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}

let token = "";
let seqSent = 0;
let seqApplied = 0;
let state: State | null = null;
let stateAt = 0;
let online = true;

async function api(path: string, init: RequestInit = {}): Promise<State> {
  const seq = ++seqSent;
  const res = await fetch(`/api/${path}`, {
    ...init,
    cache: "no-store",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...(init.headers ?? {}) },
  });
  const body = await res.json().catch(() => ({ error: `HTTP ${res.status}` }));
  if (res.status === 401) { unpair("Pairing expired or token changed. Open the pairing link again."); throw new HttpError(401, body.error); }
  if (!res.ok) throw new HttpError(res.status, body.error ?? `HTTP ${res.status}`);
  setOnline(true);
  // Responses can arrive out of order; never let an older one overwrite a newer one.
  if (seq > seqApplied && "outputs" in body) { seqApplied = seq; applyState(body as State); }
  return body as State;
}

const post = (path: string, body?: unknown) => api(path, { method: "POST", body: body === undefined ? undefined : JSON.stringify(body) });

/// Run a command; show its error as a toast instead of failing silently.
async function act(fn: () => Promise<unknown>, busyMsg?: string): Promise<void> {
  if (busyMsg) toast(busyMsg, 0);
  try {
    await fn();
    if (busyMsg) toast("");
  } catch (e) {
    if (e instanceof HttpError) { if (e.status !== 401) toast(e.message); }
    else { setOnline(false); toast("Can't reach the Mac."); }
  }
}

// ---------- polling ----------

let pollTimer: number | undefined;

async function poll(): Promise<void> {
  window.clearTimeout(pollTimer);
  if (!token) return;
  try { await api("state"); }
  catch (e) { if (!(e instanceof HttpError)) setOnline(false); }
  if (document.visibilityState === "visible" && token) pollTimer = window.setTimeout(poll, POLL_MS);
}

document.addEventListener("visibilitychange", () => {
  // Safari suspends hidden pages; on return, fetch fresh state immediately.
  if (document.visibilityState === "visible") poll();
  else window.clearTimeout(pollTimer);
});
window.addEventListener("pageshow", () => poll());
window.addEventListener("online", () => poll());

function setOnline(ok: boolean): void {
  online = ok;
  $("app").classList.toggle("offline", !ok);
  renderBanner();
  renderConn();
}

// ---------- rendering ----------

/// Controls the user is touching right now are not overwritten by polls.
const busyControls = new Set<string>();
function holdWhileTouching(el: HTMLElement, key: string): void {
  let release: number | undefined;
  const hold = () => { window.clearTimeout(release); busyControls.add(key); };
  const letGo = () => { window.clearTimeout(release); release = window.setTimeout(() => busyControls.delete(key), 800); };
  el.addEventListener("pointerdown", hold);
  el.addEventListener("focus", hold);
  el.addEventListener("input", hold);
  el.addEventListener("pointerup", letGo);
  el.addEventListener("pointercancel", letGo);
  el.addEventListener("change", letGo);
  el.addEventListener("blur", letGo);
}

function fmtTime(s: number): string {
  if (!isFinite(s) || s < 0) s = 0;
  const m = Math.floor(s / 60);
  const sec = Math.floor(s % 60);
  return `${m}:${sec.toString().padStart(2, "0")}`;
}
const fmtMs = (v: number) => `${Number.isInteger(v) ? v : v.toFixed(1)} ms`;
const fmtPct = (g: number) => `${Math.round(g * 100)}%`;
const fmtDb = (db: number) => `${db < 0 ? "−" : ""}${Math.abs(Math.round(db))} dB`;

function setFill(slider: HTMLInputElement): void {
  const min = Number(slider.min), max = Number(slider.max) || 1;
  slider.style.setProperty("--fill", `${((Number(slider.value) - min) / (max - min)) * 100}%`);
}

const statusLabel: Record<Status, [string, string]> = {
  noOutputs: ["No speakers", "idle"],
  loading: ["Opening…", "warn"],
  playing: ["Playing", "ok"],
  paused: ["Paused", "idle"],
  ended: ["Ended", "idle"],
  error: ["Stopped", "err"],
};

function applyState(s: State): void {
  const structureChanged = !state
    || sig(state.outputs.map(o => [o.uid, o.name, o.matchedBy])) !== sig(s.outputs.map(o => [o.uid, o.name, o.matchedBy]));
  const prev = state;
  state = s;
  stateAt = performance.now();

  const [label, kind] = statusLabel[s.status];
  const pill = $("status");
  pill.textContent = label;
  pill.dataset.kind = kind;
  $("source-name").textContent = s.source.name;

  const playing = s.status === "playing";
  // SVG elements have no .hidden property; toggle the attribute instead.
  document.getElementById("icon-play")!.toggleAttribute("hidden", playing);
  document.getElementById("icon-pause")!.toggleAttribute("hidden", !playing);
  $("btn-play").setAttribute("aria-label", playing ? "Pause" : "Play");
  const active = s.status === "playing" || s.status === "paused" || s.status === "ended";
  for (const id of ["btn-play", "btn-stop", "seek"]) ($(id) as HTMLButtonElement | HTMLInputElement).disabled = !active;
  renderLive(s);

  const seek = $<HTMLInputElement>("seek");
  seek.max = String(s.durationSeconds);
  $("duration").textContent = fmtTime(s.durationSeconds);
  renderPosition();

  if (!busyControls.has("master")) {
    const m = $<HTMLInputElement>("master");
    m.value = String(Math.round(s.master * 100));
    setFill(m);
    $("master-val").textContent = fmtPct(s.master);
  }

  if (structureChanged) renderOutputs(s.outputs);
  updateOutputs(s.outputs);
  $("outputs-empty").hidden = s.outputs.length > 0;

  renderNotices(s.notices);
  renderBanner();
  if (!prev || sig(prev.tracks) !== sig(s.tracks) || sig(prev.source) !== sig(s.source)) renderTracks(s);
  if (!prev || sig(prev.profiles) !== sig(s.profiles)) renderProfiles(s.profiles);
  renderDevices(s, !prev || sig(prev.devices) !== sig(s.devices) || sig(prev.outputs.map(o => o.uid)) !== sig(s.outputs.map(o => o.uid)));
  $("updated").textContent = `Updated ${new Date().toLocaleTimeString()}`;
  renderConn();

  // First visit with nothing selected: open the picker.
  if (!prev && s.outputs.length === 0) ($("outputs-picker") as HTMLDetailsElement).open = true;
}

const sig = (v: unknown) => JSON.stringify(v);

/// Live source: no timeline; show the input level and explain silence.
function renderLive(s: State): void {
  const live = s.source.kind === "live";
  $("seek-wrap").hidden = live;
  $("live").hidden = !live;
  $("btn-play").setAttribute("aria-label", live ? (s.status === "playing" ? "Mute speakers" : "Unmute speakers") : (s.status === "playing" ? "Pause" : "Play"));
  const hint = $("live-hint");
  if (!live) { hint.hidden = true; return; }
  const db = s.inputLevelDb;
  $("meter-bar").style.width = db === undefined ? "0" : `${Math.max(0, Math.min(100, ((db + 60) / 60) * 100))}%`;
  $("live-level").textContent = db === undefined ? "silent" : `${Math.round(db)} dB`;
  const silent = s.liveSilentSeconds === undefined || s.liveSilentSeconds < 0 || s.liveSilentSeconds > 5;
  if (s.status === "playing" && silent) {
    const app = s.source.name === "Spotify" ? "Spotify" : "an app";
    hint.textContent = `No audio received. Start playback in ${app} on this Mac` +
      (app === "Spotify" ? " (or choose this Mac in Spotify Connect on your phone)" : "") +
      ". If it is playing and this stays silent, allow SpeakerSync under System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only, then press Reconnect.";
    hint.hidden = false;
  } else if (s.status === "paused") {
    hint.textContent = "Speakers are muted. Press play to hear the Mac's audio on them.";
    hint.hidden = false;
  } else {
    hint.hidden = true;
  }
}

/// Between polls, advance the position locally so the slider moves smoothly.
function renderPosition(): void {
  if (!state || busyControls.has("seek") || state.source.kind === "live") return;
  let pos = state.positionSeconds;
  if (state.status === "playing") {
    pos += (performance.now() - stateAt) / 1000;
    pos = state.source.kind === "click" ? pos % state.durationSeconds : Math.min(pos, state.durationSeconds);
  }
  const seek = $<HTMLInputElement>("seek");
  seek.value = String(pos);
  setFill(seek);
  $("elapsed").textContent = fmtTime(pos);
}
window.setInterval(renderPosition, 250);

function renderConn(): void {
  const c = $("conn");
  if (!online) { c.textContent = "Offline"; c.dataset.kind = "err"; }
  else { c.textContent = "Connected"; c.dataset.kind = "ok"; }
}

function renderBanner(): void {
  const banner = $("banner"), text = $("banner-text"), btn = $<HTMLButtonElement>("banner-action");
  if (!online) {
    text.textContent = "Can't reach the Mac. Playback on the Mac is not affected.";
    btn.textContent = "Retry";
    btn.onclick = () => { toast("Retrying…"); poll(); };
    banner.hidden = false;
  } else if (state?.status === "error") {
    text.textContent = state.error ?? "Outputs are not active.";
    btn.textContent = "Reconnect";
    btn.onclick = () => act(() => post("reconnect"), "Reconnecting speakers…");
    banner.hidden = false;
  } else {
    banner.hidden = true;
  }
}

function renderNotices(notices: string[]): void {
  const ul = $("notices");
  ul.replaceChildren(...notices.map(n => el("li", {}, n)));
}

function el<K extends keyof HTMLElementTagNameMap>(tag: K, attrs: Record<string, string> = {}, ...children: (Node | string)[]): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") e.className = v;
    else e.setAttribute(k, v);
  }
  e.append(...children);
  return e;
}

// ---------- speakers ----------

function unmuteGain(uid: string): number {
  try { return (JSON.parse(store(MUTE_KEY) ?? "{}") as Record<string, number>)[uid] ?? 1; } catch { return 1; }
}
function rememberGain(uid: string, g: number): void {
  let m: Record<string, number> = {};
  try { m = JSON.parse(store(MUTE_KEY) ?? "{}"); } catch { /* ignore */ }
  m[uid] = g;
  store(MUTE_KEY, JSON.stringify(m));
}

function renderOutputs(outputs: OutputState[]): void {
  const root = $("outputs");
  root.replaceChildren(...outputs.map(o => {
    const key = (k: string) => `${k}:${o.uid}`;
    const gain = el("input", { class: "slider", type: "range", min: "0", max: "100", step: "1", "aria-label": `${o.name} volume`, "data-role": "gain" });
    const delayInput = el("input", { type: "number", inputmode: "decimal", min: "0", max: String(MAX_DELAY), step: "0.5", "aria-label": `${o.name} delay in milliseconds`, "data-role": "delay" });
    const mute = el("button", { class: "small-btn mute", type: "button", "data-role": "mute" }, "Mute");
    const limitOn = el("input", { type: "checkbox", class: "check", id: `lim-${o.uid.replace(/[^a-zA-Z0-9]/g, "_")}`, "data-role": "limit-on" });
    const limitDb = el("input", { class: "slider", type: "range", min: "-40", max: "0", step: "1", "aria-label": `${o.name} level limit in dB`, "data-role": "limit-db" });
    holdWhileTouching(gain, key("gain"));
    holdWhileTouching(delayInput, key("delay"));
    holdWhileTouching(limitOn, key("limit-on"));
    holdWhileTouching(limitDb, key("limit-db"));

    limitOn.addEventListener("change", () => {
      const row = limitOn.closest(".output");
      row?.querySelector<HTMLElement>('[data-role="limit-controls"]')?.toggleAttribute("hidden", !limitOn.checked);
      act(() => post("output", { uid: o.uid, limitEnabled: limitOn.checked }));
    });
    const sendLimit = throttle((db: number) => act(() => post("output", { uid: o.uid, limitDb: db })), 150);
    limitDb.addEventListener("input", () => {
      setFill(limitDb);
      setText(o.uid, "limit-val", fmtDb(Number(limitDb.value)));
      sendLimit(Number(limitDb.value));
    });
    limitDb.addEventListener("change", () => sendLimit.flush());

    const sendGain = throttle((g: number) => act(() => post("output", { uid: o.uid, gain: g })), 150);
    gain.addEventListener("input", () => {
      setFill(gain);
      const g = Number(gain.value) / 100;
      setText(o.uid, "gain-val", fmtPct(g));
      sendGain(g);
    });
    gain.addEventListener("change", () => sendGain.flush());

    mute.addEventListener("click", () => {
      const cur = state?.outputs.find(x => x.uid === o.uid);
      if (!cur) return;
      if (cur.gain > 0) { rememberGain(o.uid, cur.gain); act(() => post("output", { uid: o.uid, gain: 0 })); }
      else act(() => post("output", { uid: o.uid, gain: unmuteGain(o.uid) }));
    });

    const nudge = (d: number) => () => {
      const cur = state?.outputs.find(x => x.uid === o.uid)?.delayMs ?? 0;
      sendDelay(o.uid, cur + d);
    };
    delayInput.addEventListener("change", () => {
      const v = Number(delayInput.value);
      if (delayInput.value.trim() === "" || !isFinite(v)) { toast("Enter a number of milliseconds."); return; }
      sendDelay(o.uid, v);
    });
    delayInput.addEventListener("keydown", e => { if (e.key === "Enter") delayInput.blur(); });

    const btn = (label: string) => el("button", { type: "button", "aria-label": `${label} milliseconds` }, label);
    const b = [btn("−10"), btn("−1"), btn("+1"), btn("+10")];
    [-10, -1, 1, 10].forEach((d, j) => b[j]!.addEventListener("click", nudge(d)));

    return el("div", { class: "output", "data-uid": o.uid },
      el("div", { class: "output-head" },
        el("div", {},
          el("div", { class: "output-name" }, o.name),
          el("div", { class: "badge", "data-role": "badge" }, ""),
        ),
        mute,
      ),
      el("label", { class: "slider-label" }, "Volume ", el("output", { "data-role": "gain-val" }, "")),
      gain,
      el("div", { class: "limit" },
        el("div", { class: "limit-head" },
          limitOn,
          el("label", { for: limitOn.id, class: "grow" }, "Limit level"),
          el("span", { class: "limiting", "data-role": "limiting", hidden: "" }, ""),
        ),
        el("div", { "data-role": "limit-controls", hidden: "" },
          el("label", { class: "slider-label" }, "Ceiling ", el("output", { "data-role": "limit-val" }, "")),
          limitDb,
          el("p", { class: "muted small limit-help" }, "Caps loud peaks on this speaker only. Quieter parts and the other speaker are not affected."),
        ),
      ),
      el("div", { class: "delay" },
        el("div", { class: "delay-label" }, "Delay", el("span", { class: "muted", "data-role": "delay-val" }, "")),
        el("div", { class: "delay-controls" }, b[0]!, b[1]!, delayInput, b[2]!, b[3]!),
      ),
    );
  }));
}

function updateOutputs(outputs: OutputState[]): void {
  outputs.forEach((o, i) => {
    const row = document.querySelector<HTMLElement>(`.output[data-uid="${CSS.escape(o.uid)}"]`);
    if (!row) return;
    const q = <T extends HTMLElement>(role: string) => row.querySelector<T>(`[data-role="${role}"]`)!;
    const clock = outputs.length < 2 ? "" : i === 0 ? "Clock" : "Drift-corrected";
    const by = o.matchedBy === "name" ? "found by name" : o.matchedBy === "missing" ? "not connected" : "";
    q("badge").textContent = [clock, by].filter(Boolean).join(" · ");
    if (!busyControls.has(`gain:${o.uid}`)) {
      const g = q<HTMLInputElement>("gain");
      g.value = String(Math.round(o.gain * 100));
      setFill(g);
      q("gain-val").textContent = fmtPct(o.gain);
    }
    if (!busyControls.has(`delay:${o.uid}`)) q<HTMLInputElement>("delay").value = String(o.delayMs);
    if (!busyControls.has(`limit-on:${o.uid}`)) {
      q<HTMLInputElement>("limit-on").checked = o.limitEnabled;
      q("limit-controls").toggleAttribute("hidden", !o.limitEnabled);
    }
    if (!busyControls.has(`limit-db:${o.uid}`)) {
      const l = q<HTMLInputElement>("limit-db");
      l.value = String(o.limitDb);
      setFill(l);
      q("limit-val").textContent = fmtDb(o.limitDb);
    }
    const limiting = q("limiting");
    const active = o.limitEnabled && o.limitingDb !== undefined;
    limiting.toggleAttribute("hidden", !active);
    limiting.textContent = active ? `limiting ${fmtDb(o.limitingDb!)}` : "";
    q("delay-val").textContent = fmtMs(o.delayMs);
    const mute = q<HTMLButtonElement>("mute");
    const muted = o.gain === 0;
    mute.textContent = muted ? "Unmute" : "Mute";
    mute.classList.toggle("on", muted);
    mute.setAttribute("aria-pressed", String(muted));
  });
}

function setText(uid: string, role: string, text: string): void {
  const n = document.querySelector(`.output[data-uid="${CSS.escape(uid)}"] [data-role="${role}"]`);
  if (n) n.textContent = text;
}

function sendDelay(uid: string, ms: number): void {
  const v = Math.min(MAX_DELAY, Math.max(0, Math.round(ms * 2) / 2));
  if (v !== ms) toast(`Delay is limited to 0–${MAX_DELAY} ms.`);
  setText(uid, "delay-val", fmtMs(v));
  act(() => post("output", { uid, delayMs: v }));
}

function throttle<A>(fn: (a: A) => void, ms: number): ((a: A) => void) & { flush: () => void } {
  let last = 0, pending: A | undefined, timer: number | undefined, has = false;
  const run = () => { if (!has) return; has = false; last = performance.now(); fn(pending as A); };
  const t = ((a: A) => {
    pending = a; has = true;
    const wait = ms - (performance.now() - last);
    window.clearTimeout(timer);
    if (wait <= 0) run(); else timer = window.setTimeout(run, wait);
  }) as ((a: A) => void) & { flush: () => void };
  t.flush = () => { window.clearTimeout(timer); run(); };
  return t;
}

// ---------- library ----------

function renderTracks(s: State): void {
  const fmtSize = (b: number) => b > 1e6 ? `${(b / 1e6).toFixed(1)} MB` : `${Math.round(b / 1e3)} kB`;
  const item = (title: string, sub: string, current: boolean, onPick: () => void, onDelete?: () => void) => {
    const pick = el("button", { class: "pick", type: "button" },
      el("div", { class: "title" }, title), el("div", { class: "sub" }, sub));
    pick.addEventListener("click", onPick);
    const li = el("li", current ? { class: "current", "aria-current": "true" } : {}, pick);
    if (onDelete) {
      const del = el("button", { class: "danger", type: "button", "aria-label": `Delete ${title}` }, "Delete");
      del.addEventListener("click", onDelete);
      li.append(del);
    }
    return li;
  };
  const items = [
    ...LIVE_SOURCES.map(([target, title, sub]) => {
      const li = item(title, sub, s.source.kind === "live" && s.source.name === title,
        () => act(() => post("source", { live: target }), `Connecting ${title}…`));
      li.querySelector(".title")!.append(el("span", { class: "tag" }, "LIVE"));
      return li;
    }),
    item("Calibration click", "1 per second, every 4th is higher", s.source.kind === "click",
      () => act(() => post("source", { trackId: null }), "Loading click…")),
    ...s.tracks.map(t => item(t.name, `${fmtTime(t.durationSeconds)} · ${fmtSize(t.bytes)}`, s.source.trackId === t.id,
      () => act(() => post("source", { trackId: t.id }), "Loading track…"),
      () => { if (confirm(`Delete “${t.name}” from the Mac?`)) act(() => api(`tracks/${encodeURIComponent(t.id)}`, { method: "DELETE" })); })),
  ];
  $("tracks").replaceChildren(...items);
}

function upload(file: File): void {
  const bar = $("upload-bar"), text = $("upload-text"), box = $("upload-progress");
  box.hidden = false;
  bar.style.width = "0";
  text.textContent = `Uploading ${file.name}…`;
  const xhr = new XMLHttpRequest();
  xhr.open("PUT", `/api/tracks?name=${encodeURIComponent(file.name)}`);
  xhr.setRequestHeader("Authorization", `Bearer ${token}`);
  xhr.upload.onprogress = e => {
    if (!e.lengthComputable) return;
    const pct = Math.round((e.loaded / e.total) * 100);
    bar.style.width = `${pct}%`;
    text.textContent = `Uploading ${file.name}… ${pct}%`;
  };
  xhr.onload = () => {
    box.hidden = true;
    if (xhr.status === 201) { toast(`Added ${file.name}`); poll(); return; }
    let msg = `Upload failed (HTTP ${xhr.status})`;
    try { msg = JSON.parse(xhr.responseText).error ?? msg; } catch { /* keep default */ }
    if (xhr.status === 401) unpair("Pairing expired. Open the pairing link again.");
    else toast(msg);
  };
  xhr.onerror = () => { box.hidden = true; toast("Upload failed: can't reach the Mac."); };
  xhr.send(file);
}

// ---------- profiles ----------

function renderProfiles(profiles: ProfileState[]): void {
  $("profiles").replaceChildren(...profiles.map(p => {
    const load = el("button", { class: "small-btn", type: "button" }, "Load");
    load.addEventListener("click", () => act(() => post(`profiles/${encodeURIComponent(p.name)}/load`), `Loading “${p.name}”…`));
    const del = el("button", { class: "danger", type: "button", "aria-label": `Delete profile ${p.name}` }, "Delete");
    del.addEventListener("click", () => { if (confirm(`Delete profile “${p.name}”?`)) act(() => api(`profiles/${encodeURIComponent(p.name)}`, { method: "DELETE" })); });
    return el("li", {},
      el("div", { class: "grow" }, el("div", { class: "title" }, p.name), el("div", { class: "sub" }, p.outputs.join(" + "))),
      load, del);
  }));
}

// ---------- output picker ----------

let picked: string[] = [];
let pickerDirty = false;

function renderDevices(s: State, rebuild: boolean): void {
  if (!pickerDirty) picked = s.outputs.map(o => o.uid).filter(u => s.devices.some(d => d.uid === u));
  $("picker-summary").textContent = s.outputs.length ? s.outputs.map(o => o.name).join(" + ") : "none";
  if (!rebuild && !pickerDirty) { syncPicker(); return; }
  const bt = (d: DeviceState) => d.transport.startsWith("bluetooth");
  const devices = [...s.devices].sort((a, b) => Number(bt(b)) - Number(bt(a)) || a.name.localeCompare(b.name));
  $("devices").replaceChildren(...devices.map(d => {
    const id = `dev-${d.uid.replace(/[^a-zA-Z0-9]/g, "_")}`;
    const cb = el("input", { type: "checkbox", class: "check", id, "data-uid": d.uid });
    cb.addEventListener("change", () => {
      pickerDirty = true;
      if (cb.checked) { if (picked.length < MAX_OUTPUTS) picked.push(d.uid); else cb.checked = false; }
      else picked = picked.filter(u => u !== d.uid);
      syncPicker();
    });
    return el("li", {},
      cb,
      el("label", { for: id, class: "grow" },
        el("div", { class: "title" }, d.name),
        el("div", { class: "sub" }, `${d.transport} · ${d.channels} ch · ${(d.sampleRate / 1000).toFixed(1)} kHz`)),
      el("span", { class: "order", "data-order": d.uid, hidden: "" }, ""));
  }));
  syncPicker();
}

function syncPicker(): void {
  document.querySelectorAll<HTMLInputElement>("#devices input[data-uid]").forEach(cb => {
    const uid = cb.dataset.uid!;
    cb.checked = picked.includes(uid);
    cb.disabled = !cb.checked && picked.length >= MAX_OUTPUTS;
    const badge = document.querySelector<HTMLElement>(`[data-order="${CSS.escape(uid)}"]`);
    if (badge) {
      const i = picked.indexOf(uid);
      badge.hidden = i < 0;
      badge.textContent = i === 0 ? "Clock" : String(i + 1);
    }
  });
  const same = state && sig(picked) === sig(state.outputs.map(o => o.uid));
  $<HTMLButtonElement>("btn-apply-outputs").disabled = picked.length === 0 || !!same;
}

// ---------- toast ----------

let toastTimer: number | undefined;
function toast(msg: string, ms = 3500): void {
  const t = $("toast");
  window.clearTimeout(toastTimer);
  if (!msg) { t.hidden = true; return; }
  t.textContent = msg;
  t.hidden = false;
  if (ms > 0) toastTimer = window.setTimeout(() => { t.hidden = true; }, ms);
}

// ---------- pairing ----------

function unpair(message?: string): void {
  token = "";
  store(TOKEN_KEY, null);
  window.clearTimeout(pollTimer);
  state = null;
  $("app").hidden = true;
  $("pair").hidden = false;
  if (message) toast(message, 6000);
}

function startApp(): void {
  $("pair").hidden = true;
  $("app").hidden = false;
  poll();
}

/// Pairing link: http://<mac>:8095/#token=<hex>. The fragment is never sent to
/// the server; move it to storage and drop it from the address bar.
function tokenFromHash(): string | null {
  const m = location.hash.match(/token=([0-9a-fA-F]{32})/);
  if (!m) return null;
  const t = m[1]!.toLowerCase();
  store(TOKEN_KEY, t);
  history.replaceState(null, "", location.pathname);
  return t;
}

function init(): void {
  const fromHash = tokenFromHash();
  token = store(TOKEN_KEY) ?? fromHash ?? "";
  // Pairing link opened in a tab already showing this page: no reload happens.
  window.addEventListener("hashchange", () => {
    const t = tokenFromHash();
    if (t) { token = t; startApp(); }
  });

  $("pair-form").addEventListener("submit", e => {
    e.preventDefault();
    const v = $<HTMLInputElement>("pair-token").value.trim().toLowerCase();
    if (!/^[0-9a-f]{32}$/.test(v)) { toast("The token is 32 hex characters."); return; }
    token = v;
    store(TOKEN_KEY, v);
    startApp();
  });

  $("btn-play").addEventListener("click", () => act(() => post("transport", { action: state?.status === "playing" ? "pause" : "play" })));
  $("btn-stop").addEventListener("click", () => act(() => post("transport", { action: "stop" })));

  const seek = $<HTMLInputElement>("seek");
  holdWhileTouching(seek, "seek");
  seek.addEventListener("input", () => { setFill(seek); $("elapsed").textContent = fmtTime(Number(seek.value)); });
  seek.addEventListener("change", () => act(() => post("seek", { seconds: Number(seek.value) })));

  const master = $<HTMLInputElement>("master");
  holdWhileTouching(master, "master");
  const sendMaster = throttle((g: number) => act(() => post("master", { gain: g })), 150);
  master.addEventListener("input", () => {
    setFill(master);
    const g = Number(master.value) / 100;
    $("master-val").textContent = fmtPct(g);
    sendMaster(g);
  });
  master.addEventListener("change", () => sendMaster.flush());

  $("btn-click").addEventListener("click", () => act(async () => {
    if (state?.source.kind !== "click") await post("source", { trackId: null });
    await post("transport", { action: "play" });
  }, "Starting click…"));

  $<HTMLInputElement>("upload").addEventListener("change", e => {
    const input = e.target as HTMLInputElement;
    const f = input.files?.[0];
    input.value = "";
    if (f) upload(f);
  });

  $("profile-form").addEventListener("submit", e => {
    e.preventDefault();
    const input = $<HTMLInputElement>("profile-name");
    const name = input.value.trim();
    if (!name) { toast("Enter a profile name."); return; }
    act(async () => { await post("profiles", { name }); input.value = ""; toast(`Saved “${name}”`); });
  });

  $("btn-apply-outputs").addEventListener("click", () => act(async () => {
    await post("outputs", { uids: picked });
    pickerDirty = false;
    ($("outputs-picker") as HTMLDetailsElement).open = false;
  }, "Opening speakers…"));

  $("btn-unpair").addEventListener("click", () => { if (confirm("Unpair this device? You will need the pairing link again.")) unpair(); });

  if (token) startApp();
  else { $("pair").hidden = false; }
}

init();
