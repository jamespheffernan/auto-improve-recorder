const stages = [
  { key: "capture", label: "Capture" },
  { key: "transcribe", label: "Transcribe" },
  { key: "improve", label: "Improve" },
  { key: "deliver", label: "Deliver" },
  { key: "confirm", label: "Confirm" },
  { key: "repair", label: "Repair" }
];

const stateOrder = [
  "idle",
  "starting",
  "recording",
  "latched",
  "transcribing",
  "improving",
  "delivering",
  "pasted",
  "submitted",
  "copied",
  "ready",
  "done",
  "failed",
  "permission-denied",
  "model-unavailable"
];

const stateCatalog = {
  idle: {
    label: "Idle",
    detail: "No active capture.",
    command: "Hold record to start.",
    menu: "Recorder idle",
    stage: "capture",
    activity: "quiet",
    commandMode: "start",
    color: "var(--idle)",
    elapsed: 0
  },
  starting: {
    label: "Starting",
    detail: "Checking microphone, target field, and recording mode.",
    command: "Esc cancels before audio is committed.",
    menu: "Recorder starting",
    stage: "capture",
    activity: "active",
    commandMode: "capture",
    color: "var(--starting)",
    elapsed: 0
  },
  recording: {
    label: "Recording",
    detail: "Listening in the focused field.",
    command: "Release sends. Space locks. Esc cancels.",
    menu: "Recording",
    stage: "capture",
    activity: "active",
    commandMode: "recording",
    color: "var(--record)",
    elapsed: 12
  },
  latched: {
    label: "Recording locked",
    detail: "Hands-free capture stays on until you send or cancel.",
    command: "Space sends. Esc cancels.",
    menu: "Recording locked",
    stage: "capture",
    activity: "active",
    commandMode: "latched",
    color: "var(--record)",
    elapsed: 18
  },
  transcribing: {
    label: "Transcribing",
    detail: "Audio is becoming text.",
    command: "Wait; Esc stops delivery if the target changed.",
    menu: "Transcribing",
    stage: "transcribe",
    activity: "active",
    commandMode: "wait",
    color: "var(--transcribe)",
    elapsed: 18
  },
  improving: {
    label: "Improving text",
    detail: "Cleanup is shaping the transcript before delivery.",
    command: "Wait; preview remains the recovery path.",
    menu: "Improving text",
    stage: "improve",
    activity: "active",
    commandMode: "wait",
    color: "var(--improve)",
    elapsed: 18
  },
  delivering: {
    label: "Delivering",
    detail: "Text is moving into the focused field.",
    command: "Keep focus in the target app.",
    menu: "Delivering text",
    stage: "deliver",
    activity: "active",
    commandMode: "deliver",
    color: "var(--deliver)",
    elapsed: 18
  },
  pasted: {
    label: "Pasted",
    detail: "Text landed in the focused field.",
    command: "Continue typing or start another recording.",
    menu: "Text pasted",
    stage: "confirm",
    activity: "resolved",
    commandMode: "done",
    color: "var(--success)",
    elapsed: 18
  },
  submitted: {
    label: "Submitted",
    detail: "Text pasted and Return was sent.",
    command: "Watch the target app for its send state.",
    menu: "Text submitted",
    stage: "confirm",
    activity: "resolved",
    commandMode: "done",
    color: "var(--success)",
    elapsed: 18
  },
  copied: {
    label: "Copied",
    detail: "Text copied because direct paste was unavailable.",
    command: "Press Command-V in the target app.",
    menu: "Text copied",
    stage: "confirm",
    activity: "resolved",
    commandMode: "copy",
    color: "var(--copy)",
    elapsed: 18
  },
  ready: {
    label: "Ready",
    detail: "Capture is ready after the last run.",
    command: "Hold record to dictate again.",
    menu: "Recorder ready",
    stage: "confirm",
    activity: "resolved",
    commandMode: "start",
    color: "var(--success)",
    elapsed: 0
  },
  done: {
    label: "Done",
    detail: "Workflow finished.",
    command: "No action needed.",
    menu: "Workflow done",
    stage: "confirm",
    activity: "resolved",
    commandMode: "done",
    color: "var(--success)",
    elapsed: 18
  },
  failed: {
    label: "Failed",
    detail: "The workflow stopped before delivery.",
    command: "Open preview to recover text.",
    menu: "Workflow failed",
    stage: "repair",
    activity: "blocked",
    commandMode: "repair",
    color: "var(--danger)",
    elapsed: 18
  },
  "permission-denied": {
    label: "Permission denied",
    detail: "Microphone or Accessibility access is blocked.",
    command: "Open System Settings.",
    menu: "Permission blocked",
    stage: "repair",
    activity: "blocked",
    commandMode: "permission",
    color: "var(--permission)",
    elapsed: 0
  },
  "model-unavailable": {
    label: "Model unavailable",
    detail: "The selected local model is missing or unhealthy.",
    command: "Choose another preset or install the model.",
    menu: "Model unavailable",
    stage: "repair",
    activity: "blocked",
    commandMode: "model",
    color: "var(--warning)",
    elapsed: 0
  },
  cancelled: {
    label: "Cancelled",
    detail: "Recording discarded.",
    command: "Hold record to start again.",
    menu: "Recording cancelled",
    stage: "capture",
    activity: "blocked",
    commandMode: "start",
    color: "var(--cancel)",
    elapsed: 0
  }
};

const stateAliases = {
  cleaning: "improving",
  improve: "improving",
  pasting: "delivering",
  paste: "delivering",
  delivering: "delivering",
  delivery: "delivering",
  permission: "permission-denied",
  permissions: "permission-denied",
  denied: "permission-denied",
  model: "model-unavailable",
  "ready-done": "done",
  "ready/done": "done"
};

const tuningStorageKey = "airWaitingTuning:v10";

// Everything that shapes the look of the HUD, pills, and waveform is pinned to
// the tuned Subtle values here. The dial kit no longer exposes these — they stay
// constant so the panel can focus entirely on the waveform -> stage transition.
const fixedTuning = {
  glowIntensity: 0.46,
  edgeDepth: 3,
  edgeBlur: 20,
  surfaceOpacity: 0.62,
  hudScale: 0.92,
  hudOffsetY: 8,
  ringInset: 10,
  trackWidth: 96,
  trackHeight: 24,
  compactTrackWidth: 62,
  pillWidth: 3,
  compactPillWidth: 7,
  pillGap: 1,
  compactPillGap: 1,
  pillRadius: 8,
  trackHiddenScale: 0.92,
  pillBaseHeight: 14,
  stageActiveScaleX: 1.08,
  stageMotionStagger: 70,
  stageUpcomingOpacity: 0.22,
  stageCompleteOpacity: 0.68,
  stageActiveOpacity: 1,
  stageGlowBlur: 18,
  stageGlowOpacity: 0.7,
  fillCompletedStages: true,
  waveMinHeight: 5,
  waveTroughOpacity: 0.48,
  wavePeakOpacity: 0.92,
  showHints: true,
  showRail: true,
  showFieldRing: true,
  showWave: true
};

// Transition dials only, grouped by the phase of the handoff they shape:
// Tempo (master speed) -> Wave in (energy handed off) -> Handoff (the settle)
// -> Landing (where it lands and how it lives after).
const tuningControls = [
  { group: "Tempo", key: "motionSpeed", label: "Motion speed", type: "range", default: 0.9, min: 0.45, max: 2, step: 0.05, unit: "x", description: "Master tempo. Scales the waveform, the wave→stage settle, and the stage breathing together. Higher plays everything faster; lower lets you study a single moment." },
  { group: "Wave in", key: "waveMaxHeight", label: "Wave height", type: "range", default: 22, min: 6, max: 52, step: 1, unit: "px", description: "Peak bar height while recording. This is the amplitude of motion that gets carried into the pills at the handoff — taller bars hand off more energy." },
  { group: "Wave in", key: "waveDuration", label: "Wave cycle", type: "range", default: 760, min: 280, max: 1800, step: 20, unit: "ms", description: "Time for one waveform pulse. Lower feels fast and urgent; higher feels like slow, calm breathing while recording." },
  { group: "Wave in", key: "waveDelayStep", label: "Wave stagger", type: "range", default: 90, min: 0, max: 260, step: 5, unit: "ms", description: "Delay between neighbouring bars, which creates the travelling ripple across the waveform. 0 makes every bar pulse in unison." },
  { group: "Handoff", key: "modeTransitionMs", label: "Settle duration", type: "range", default: 260, min: 80, max: 700, step: 10, unit: "ms", description: "How long each pill takes to morph from waveform into its stage shape. Longer is a slower, more deliberate handoff." },
  { group: "Handoff", key: "modeStaggerMs", label: "Pill stagger", type: "range", default: 12, min: 0, max: 80, step: 1, unit: "ms", description: "Extra delay per pill as the settle radiates outward from the active stage. Higher ripples the handoff; 0 settles every pill at once." },
  { group: "Handoff", key: "handoffCarry", label: "Live carry", type: "range", default: 1, min: 0, max: 1, step: 0.01, unit: "", description: "How much of each pill's live waveform height and opacity is kept at the instant of handoff. 1 carries the wave's pose in fully; 0 starts the settle from a fixed pose." },
  { group: "Handoff", key: "handoffPeakScale", label: "Active overshoot", type: "range", default: 1.72, min: 1, max: 2.8, step: 0.01, unit: "x", description: "How tall the active (current-stage) pill springs mid-handoff before settling — the overshoot that gives the morph its pop." },
  { group: "Handoff", key: "handoffNeighborScale", label: "Neighbor overshoot", type: "range", default: 1.12, min: 0.4, max: 2, step: 0.01, unit: "x", description: "How tall the completed neighbour pills spring mid-handoff. Keep it below the active overshoot so the current stage stays the focal point." },
  { group: "Handoff", key: "settleBounce", label: "Settle bounce", type: "range", default: 0.45, min: 0, max: 1.4, step: 0.02, unit: "x", description: "Follow-through after the overshoot: the pill dips under rest, does a small re-overshoot, then settles — a damped spring. 0 is a clean single decel; higher feels springier and more alive." },
  { group: "Landing", key: "stageActiveScaleY", label: "Active height", type: "range", default: 1.25, min: 0.75, max: 3, step: 0.01, unit: "x", description: "Resting height of the active stage pill once it has landed. Taller makes the current stage read as clearly lit." },
  { group: "Landing", key: "stageMotionScale", label: "Stage breathing", type: "range", default: 1.05, min: 1, max: 1.6, step: 0.01, unit: "x", description: "Amplitude of the gentle breathing the completed and active pills keep after landing. 1 is perfectly still; higher shows more life." },
  { group: "Landing", key: "stageMotionDuration", label: "Breathing cycle", type: "range", default: 1650, min: 700, max: 3600, step: 50, unit: "ms", description: "Time for one breath of the settled stage pills. Lower is a quicker pulse; higher is slow and calm." }
];

const tuningDefaults = {
  ...fixedTuning,
  ...Object.fromEntries(tuningControls.map((control) => [control.key, control.default]))
};

// Presets now only carry transition values; the fixed look is unaffected by them.
// Subtle mirrors the dial defaults (refined); Loud is the punchier upper bound.
const tuningPresets = {
  Subtle: {
    motionSpeed: 0.9,
    waveMaxHeight: 22,
    waveDuration: 760,
    waveDelayStep: 90,
    modeTransitionMs: 260,
    modeStaggerMs: 12,
    handoffCarry: 1,
    handoffPeakScale: 1.72,
    handoffNeighborScale: 1.12,
    settleBounce: 0.45,
    stageActiveScaleY: 1.25,
    stageMotionScale: 1.05,
    stageMotionDuration: 1650
  },
  Loud: {
    motionSpeed: 1.25,
    waveMaxHeight: 32,
    waveDuration: 560,
    waveDelayStep: 70,
    modeTransitionMs: 300,
    modeStaggerMs: 22,
    handoffCarry: 1,
    handoffPeakScale: 2.1,
    handoffNeighborScale: 1.25,
    settleBounce: 0.9,
    stageActiveScaleY: 1.6,
    stageMotionScale: 1.12,
    stageMotionDuration: 1100
  }
};

const variants = [
  {
    key: "A",
    name: "Edge instrument",
    render: renderEdgeInstrument
  },
  {
    key: "B",
    name: "Field-attached",
    render: renderFieldAttached
  },
  {
    key: "C",
    name: "Micro HUD",
    render: renderMicroHUD
  },
  {
    key: "D",
    name: "Glow readout",
    render: renderGlowReadout
  }
];

const app = document.getElementById("app");
const root = document.getElementById("variantRoot");
const stateLabel = document.getElementById("stateLabel");
const stateReadout = document.getElementById("stateReadout");
const recordButton = document.getElementById("recordButton");
const latchButton = document.getElementById("latchButton");
const cancelButton = document.getElementById("cancelButton");
const prevVariant = document.getElementById("prevVariant");
const nextVariant = document.getElementById("nextVariant");
const variantKey = document.getElementById("variantKey");
const variantName = document.getElementById("variantName");
const menuStatus = document.getElementById("menuStatus");
const modeChip = document.getElementById("modeChip");
const targetField = document.getElementById("targetField");
const stateGrid = document.getElementById("stateGrid");
const railList = document.getElementById("railList");
const readoutTitle = document.getElementById("readoutTitle");
const readoutDetail = document.getElementById("readoutDetail");
const readoutCommand = document.getElementById("readoutCommand");
const playFlowButton = document.getElementById("playFlowButton");
const tuningPresetsRoot = document.getElementById("tuningPresets");
const tuningForm = document.getElementById("tuningForm");
const resetTuneButton = document.getElementById("resetTuneButton");
const copyTuneButton = document.getElementById("copyTuneButton");
const tuningOutput = document.getElementById("tuningOutput");

let state = getStateKey();
let latched = state === "latched";
let recordingStartedAt = 0;
let timerId = 0;
let flowTimer = 0;
let trackTransitionTimer = 0;
let elapsedSeconds = stateInfo(state).elapsed;
let tuning = loadTuning();

function normalizeState(value) {
  const key = String(value || "idle").trim().toLowerCase().replace(/\s+/g, "-");
  if (stateCatalog[key]) return key;
  return stateAliases[key] || "idle";
}

function stateInfo(value = state) {
  return stateCatalog[normalizeState(value)] || stateCatalog.idle;
}

function getVariantKey() {
  const params = new URLSearchParams(window.location.search);
  const requested = (params.get("variant") || "B").toUpperCase();
  return variants.some((variant) => variant.key === requested) ? requested : "B";
}

function getStateKey() {
  const params = new URLSearchParams(window.location.search);
  return normalizeState(params.get("state") || "idle");
}

function updateURL(replace = false) {
  const params = new URLSearchParams(window.location.search);
  params.set("variant", app.dataset.variant || getVariantKey());
  params.set("state", state);
  const nextURL = `${window.location.pathname}?${params.toString()}`;
  window.history[replace ? "replaceState" : "pushState"]({}, "", nextURL);
}

function setVariant(key, replace = false, skipURL = false) {
  const variant = variants.find((item) => item.key === key) || variants[0];
  if (app.dataset.trackTransition) {
    clearTrackTransition();
  }
  app.dataset.variant = variant.key;
  variantKey.textContent = variant.key;
  variantName.textContent = variant.name;
  root.innerHTML = variant.render();
  render();
  if (!skipURL) updateURL(replace);
}

function cycleVariant(direction) {
  const currentKey = app.dataset.variant || getVariantKey();
  const index = variants.findIndex((variant) => variant.key === currentKey);
  const next = variants[(index + direction + variants.length) % variants.length];
  setVariant(next.key);
}

function jumpToState(nextState, replace = false) {
  clearFlow();
  applyState(nextState, { updateUrl: true, replace });
}

function applyState(nextState, options = {}) {
  state = normalizeState(nextState);
  const info = stateInfo(state);
  latched = state === "latched";

  if (typeof options.elapsed === "number") {
    elapsedSeconds = options.elapsed;
  } else if (!timerId) {
    elapsedSeconds = info.elapsed;
  }

  if (options.liveTimer) {
    startTimer();
  } else if (!options.keepTimer) {
    stopTimer();
  }

  render();

  if (options.updateUrl) {
    updateURL(options.replace);
  }
}

function render() {
  const info = stateInfo(state);
  const activeStageIndex = stages.findIndex((stageItem) => stageItem.key === info.stage);
  app.dataset.state = state;
  app.dataset.stage = info.stage;
  app.dataset.activity = info.activity;
  app.dataset.command = info.commandMode;
  app.dataset.rail = info.activity === "quiet" ? "false" : "true";
  const nextTrack = state === "recording" || state === "latched" ? "wave" : "stage";
  const previousTrack = app.dataset.track;
  if (previousTrack && previousTrack !== nextTrack) {
    if (previousTrack === "wave" && nextTrack === "stage") {
      // Capture the outgoing (recording) colour so the settle can cross-fade
      // from it into the new stage colour instead of snapping.
      const outgoingColor = getComputedStyle(app).getPropertyValue("--state-color").trim();
      app.style.setProperty("--prev-state-color", outgoingColor || info.color);
      captureWaveCarry(activeStageIndex);
    }
    app.dataset.trackTransition = `${previousTrack}-to-${nextTrack}`;
    scheduleTrackTransitionClear(nextTrack);
  }
  app.dataset.track = nextTrack;
  app.dataset.motion = ["recording", "latched", "transcribing", "improving", "delivering", "starting"].includes(state) ? "active" : "still";
  app.style.setProperty("--state-color", info.color);

  stateLabel.textContent = info.label;
  stateReadout.textContent = state;
  recordButton.textContent = ["recording", "latched"].includes(state) ? "Release to send" : "Hold to record";
  latchButton.textContent = latched ? "Space: send" : "Space: latch";
  modeChip.textContent = latched ? "Persistent recording" : "Walkie talkie";
  menuStatus.textContent = menuTextForState(state);
  readoutTitle.textContent = info.label;
  readoutDetail.textContent = info.detail;
  readoutCommand.textContent = info.command;

  document.querySelectorAll("[data-bind='label']").forEach((node) => {
    node.textContent = info.label;
  });
  document.querySelectorAll("[data-bind='detail']").forEach((node) => {
    node.textContent = info.detail;
  });
  document.querySelectorAll("[data-bind='command']").forEach((node) => {
    node.textContent = info.command;
  });
  document.querySelectorAll("[data-bind='timer']").forEach((node) => {
    node.textContent = formatTimer(elapsedSeconds);
  });
  document.querySelectorAll("[data-bind='hints']").forEach((node) => {
    node.innerHTML = hintsForState(state, node.dataset.hintSize === "short");
  });
  document.querySelectorAll("[data-stage]").forEach((node) => {
    const stageIndex = stages.findIndex((stageItem) => stageItem.key === node.dataset.stage);
    if (stageIndex >= 0) {
      node.style.setProperty("--handoff-distance", Math.abs(stageIndex - activeStageIndex));
    }
    node.classList.toggle("active", node.dataset.stage === info.stage);
    node.classList.toggle("complete", stageIndex >= 0 && stageIndex < activeStageIndex);
    node.classList.toggle("upcoming", stageIndex > activeStageIndex);
  });
  document.querySelectorAll("[data-state-jump]").forEach((node) => {
    const active = node.dataset.stateJump === state;
    node.classList.toggle("active", active);
    node.setAttribute("aria-pressed", active ? "true" : "false");
  });
  document.querySelectorAll(".rail-step").forEach((node) => {
    node.classList.toggle("active", node.dataset.stageKey === info.stage);
    node.classList.toggle("blocked", info.activity === "blocked" && node.dataset.stageKey === info.stage);
  });
}

function scheduleTrackTransitionClear(expectedTrack = app.dataset.track) {
  clearTimeout(trackTransitionTimer);
  trackTransitionTimer = window.setTimeout(() => {
    if (app.dataset.track === expectedTrack) {
      clearTrackTransition();
    }
  }, trackTransitionClearDelay());
}

function clearTrackTransition() {
  clearTimeout(trackTransitionTimer);
  trackTransitionTimer = 0;
  delete app.dataset.trackTransition;
}

function trackTransitionClearDelay() {
  const speed = Math.max(0.1, Number(tuning.motionSpeed) || 1);
  const settleMs = Math.round((Number(tuning.modeTransitionMs) || 260) / Math.sqrt(speed));
  const staggerMs = Math.round((Number(tuning.modeStaggerMs) || 0) / Math.sqrt(speed));
  return Math.max(80, settleMs + staggerMs * (stages.length - 1)) + 40;
}

function captureWaveCarry(activeStageIndex) {
  const carry = clampNumber(Number(tuning.handoffCarry), 0, 1);
  const peakScale = finiteNumber(tuning.handoffPeakScale, 1);
  const neighborScale = finiteNumber(tuning.handoffNeighborScale, 1);
  const troughScale = finiteNumber(getComputedStyle(app).getPropertyValue("--wave-min-scale"), 1);
  const peakOpacity = finiteNumber(tuning.wavePeakOpacity, 1);
  const troughOpacity = finiteNumber(tuning.waveTroughOpacity, 1);
  const fillCompleted = Boolean(tuning.fillCompletedStages);

  document.querySelectorAll(".track-pill").forEach((node) => {
    const computed = getComputedStyle(node);
    const sampledScale = transformScaleY(computed.transform);
    const sampledOpacity = finiteNumber(computed.opacity, 1);
    const stageIndex = stages.findIndex((stageItem) => stageItem.key === node.dataset.stage);
    const isActive = stageIndex === activeStageIndex;
    const isComplete = fillCompleted && stageIndex >= 0 && stageIndex < activeStageIndex;
    const fallbackScale = isActive ? peakScale : isComplete ? neighborScale : troughScale;
    const fallbackOpacity = isActive || isComplete ? peakOpacity : troughOpacity;
    const carryScale = fallbackScale + (sampledScale - fallbackScale) * carry;
    const carryOpacity = fallbackOpacity + (sampledOpacity - fallbackOpacity) * carry;

    node.style.setProperty("--carry-scale", carryScale.toFixed(3));
    node.style.setProperty("--carry-opacity", clampNumber(carryOpacity, 0, 1).toFixed(3));
  });
}

function transformScaleY(transform) {
  if (!transform || transform === "none") return 1;

  try {
    const Matrix = window.DOMMatrixReadOnly || window.DOMMatrix || window.WebKitCSSMatrix;
    if (Matrix) {
      const matrix = new Matrix(transform);
      if (Number.isFinite(matrix.d)) return Math.abs(matrix.d);
      if (Number.isFinite(matrix.m22)) return Math.abs(matrix.m22);
    }
  } catch {
    // Fall through to the string parser for older engines.
  }

  const matrix2d = transform.match(/^matrix\(([^)]+)\)$/);
  if (matrix2d) {
    const parts = matrix2d[1].split(",").map((part) => Number(part.trim()));
    return Number.isFinite(parts[3]) ? Math.abs(parts[3]) : 1;
  }

  const matrix3d = transform.match(/^matrix3d\(([^)]+)\)$/);
  if (matrix3d) {
    const parts = matrix3d[1].split(",").map((part) => Number(part.trim()));
    return Number.isFinite(parts[5]) ? Math.abs(parts[5]) : 1;
  }

  return 1;
}

function clampNumber(value, min, max) {
  if (!Number.isFinite(value)) return min;
  return Math.min(max, Math.max(min, value));
}

function finiteNumber(value, fallback) {
  const numeric = Number(value);
  return Number.isFinite(numeric) ? numeric : fallback;
}

function renderStateControls() {
  stateGrid.innerHTML = stateOrder
    .map((key) => {
      const info = stateInfo(key);
      const stage = stages.find((item) => item.key === info.stage);
      return `
        <button class="state-chip" type="button" data-state-jump="${key}" aria-pressed="false">
          <span class="state-dot" style="--dot-color: ${info.color}"></span>
          <span class="state-chip-copy">
            <strong>${info.label}</strong>
            <small>${stage ? stage.label : "State"}</small>
          </span>
          <span class="state-key">${key}</span>
        </button>
      `;
    })
    .join("");

  railList.innerHTML = stages
    .map((stageItem) => {
      return `
        <div class="rail-step" data-stage-key="${stageItem.key}">
          <span></span>
          <strong>${stageItem.label}</strong>
        </div>
      `;
    })
    .join("");
}

function renderTuningControls() {
  tuningPresetsRoot.innerHTML = Object.keys(tuningPresets)
    .map((name) => `<button type="button" data-tune-preset="${name}">${name}</button>`)
    .join("");

  let activeGroup = "";
  const controls = [];
  tuningControls.forEach((control) => {
    const group = control.group || "Controls";
    if (group !== activeGroup) {
      if (activeGroup) controls.push("</fieldset>");
      controls.push(`<fieldset class="tuning-group"><legend>${group}</legend>`);
      activeGroup = group;
    }
    controls.push(renderTuningControl(control));
  });
  if (activeGroup) controls.push("</fieldset>");
  tuningForm.innerHTML = controls.join("");

  syncTuningInputs();
}

function renderTuningControl(control) {
  if (control.type === "toggle") {
    return `
      <label class="tuning-control tuning-toggle" data-tip="${control.description || ""}">
        <span class="tuning-control-header">
          <span>${control.label}</span>
          <span class="tuning-value" data-tune-value="${control.key}">on</span>
        </span>
        <input type="checkbox" name="${control.key}">
      </label>
    `;
  }

  return `
    <label class="tuning-control" data-tip="${control.description || ""}">
      <span class="tuning-control-header">
        <span>${control.label}</span>
        <span class="tuning-value" data-tune-value="${control.key}"></span>
      </span>
      <input
        type="range"
        name="${control.key}"
        min="${control.min}"
        max="${control.max}"
        step="${control.step}"
      >
    </label>
  `;
}

function loadTuning() {
  try {
    const saved = JSON.parse(localStorage.getItem(tuningStorageKey) || "{}");
    return sanitizeTuning(saved);
  } catch {
    return { ...tuningDefaults };
  }
}

function saveTuning() {
  try {
    localStorage.setItem(tuningStorageKey, JSON.stringify(tuning));
  } catch {
    // Local files or privacy settings can block storage. Live tuning still works.
  }
}

function sanitizeTuning(source = {}) {
  // Always seed the pinned look, then layer only the tunable transition keys.
  const result = { ...fixedTuning };
  tuningControls.forEach((control) => {
    const value = source[control.key];
    if (control.type === "toggle") {
      result[control.key] = typeof value === "boolean" ? value : control.default;
      return;
    }

    const numeric = Number(value);
    result[control.key] = Number.isFinite(numeric)
      ? Math.min(control.max, Math.max(control.min, numeric))
      : control.default;
  });
  return result;
}

function syncTuningInputs() {
  tuningControls.forEach((control) => {
    const input = tuningForm.elements[control.key];
    if (!input) return;
    if (control.type === "toggle") {
      input.checked = Boolean(tuning[control.key]);
    } else {
      input.value = tuning[control.key];
    }
    updateTuningValueLabel(control.key);
  });
  updatePresetButtons();
}

function updateTuningValueLabel(key) {
  const control = tuningControls.find((item) => item.key === key);
  const label = document.querySelector(`[data-tune-value="${key}"]`);
  if (!control || !label) return;

  if (control.type === "toggle") {
    label.textContent = tuning[key] ? "on" : "off";
    return;
  }

  const value = Number(tuning[key]);
  const formatted = Number.isInteger(value) ? String(value) : value.toFixed(2).replace(/0+$/, "").replace(/\.$/, "");
  label.textContent = `${formatted}${control.unit}`;
}

function applyTuning(options = {}) {
  const speed = Number(tuning.motionSpeed) || 1;
  const modeTransitionMs = Math.round((Number(tuning.modeTransitionMs) || 260) / Math.sqrt(speed));
  const modeStaggerMs = Math.round((Number(tuning.modeStaggerMs) || 0) / Math.sqrt(speed));
  const stageMotionDuration = Math.round((Number(tuning.stageMotionDuration) || 1650) / Math.sqrt(speed));
  const stageMotionStagger = Math.round((Number(tuning.stageMotionStagger) || 0) / Math.sqrt(speed));
  const basePillHeight = Math.max(1, Number(tuning.pillBaseHeight) || 1);
  const troughScale = (Number(tuning.waveMinHeight) / basePillHeight) * (Number(tuning.trackHiddenScale) || 1);
  const stageMotionScale = Number(tuning.stageMotionScale) || 1;
  const activeMotionScaleX = Number(tuning.stageActiveScaleX) * (1 + (stageMotionScale - 1) * 0.35);
  const activeMotionScaleY = Number(tuning.stageActiveScaleY) * stageMotionScale;
  app.style.setProperty("--tune-glow-opacity", tuning.glowIntensity);
  app.style.setProperty("--tune-edge-depth", `${tuning.edgeDepth}px`);
  app.style.setProperty("--tune-edge-blur", `${tuning.edgeBlur}px`);
  app.style.setProperty("--tune-halo-blur", `${Math.max(10, Math.round(tuning.edgeBlur * 1.6))}px`);
  app.style.setProperty("--tune-surface-opacity", tuning.surfaceOpacity);
  app.style.setProperty("--tune-hud-scale", tuning.hudScale);
  app.style.setProperty("--tune-hud-rest-scale", (tuning.hudScale * 0.96).toFixed(3));
  app.style.setProperty("--tune-hud-y", `${tuning.hudOffsetY}px`);
  app.style.setProperty("--tune-ring-inset", `${tuning.ringInset}px`);
  app.style.setProperty("--track-width", `${tuning.trackWidth}px`);
  app.style.setProperty("--track-height", `${tuning.trackHeight}px`);
  app.style.setProperty("--track-compact-width", `${tuning.compactTrackWidth}px`);
  app.style.setProperty("--pill-width", `${tuning.pillWidth}px`);
  app.style.setProperty("--pill-compact-width", `${tuning.compactPillWidth}px`);
  app.style.setProperty("--pill-gap", `${tuning.pillGap}px`);
  app.style.setProperty("--pill-compact-gap", `${tuning.compactPillGap}px`);
  app.style.setProperty("--pill-radius", `${tuning.pillRadius}px`);
  app.style.setProperty("--pill-hidden-scale", tuning.trackHiddenScale);
  app.style.setProperty("--handoff-carry", tuning.handoffCarry);
  app.style.setProperty("--handoff-peak-scale", tuning.handoffPeakScale);
  app.style.setProperty("--handoff-neighbor-scale", tuning.handoffNeighborScale);
  app.style.setProperty("--settle-bounce", tuning.settleBounce);
  app.style.setProperty("--pill-base-height", `${tuning.pillBaseHeight}px`);
  app.style.setProperty("--stage-active-scale-x", tuning.stageActiveScaleX);
  app.style.setProperty("--stage-active-scale-y", tuning.stageActiveScaleY);
  app.style.setProperty("--stage-motion-scale", stageMotionScale);
  app.style.setProperty("--stage-active-motion-scale-x", activeMotionScaleX.toFixed(3));
  app.style.setProperty("--stage-active-motion-scale-y", activeMotionScaleY.toFixed(3));
  app.style.setProperty("--stage-motion-duration", `${stageMotionDuration}ms`);
  app.style.setProperty("--stage-motion-stagger", `${stageMotionStagger}ms`);
  app.style.setProperty("--stage-upcoming-opacity", tuning.stageUpcomingOpacity);
  app.style.setProperty("--stage-complete-opacity", tuning.stageCompleteOpacity);
  app.style.setProperty("--stage-active-opacity", tuning.stageActiveOpacity);
  app.style.setProperty("--stage-glow-blur", `${tuning.stageGlowBlur}px`);
  app.style.setProperty("--stage-glow-opacity", tuning.stageGlowOpacity);
  app.style.setProperty("--stage-active-glow-blur", `${Math.round(tuning.stageGlowBlur * tuning.stageGlowOpacity)}px`);
  app.style.setProperty("--wave-glow-blur", `${Math.round(tuning.stageGlowBlur * tuning.stageGlowOpacity * 0.42)}px`);
  app.style.setProperty("--wave-min-height", `${tuning.waveMinHeight}px`);
  app.style.setProperty("--wave-max-height", `${tuning.waveMaxHeight}px`);
  app.style.setProperty("--wave-min-scale", Math.max(0.05, troughScale).toFixed(3));
  app.style.setProperty("--wave-max-scale", Math.max(0.05, tuning.waveMaxHeight / basePillHeight).toFixed(3));
  app.style.setProperty("--wave-delay-step", `${Math.round(tuning.waveDelayStep / speed)}ms`);
  app.style.setProperty("--wave-trough-opacity", tuning.waveTroughOpacity);
  app.style.setProperty("--wave-peak-opacity", tuning.wavePeakOpacity);
  app.style.setProperty("--tune-wave-duration", `${Math.round(tuning.waveDuration / speed)}ms`);
  app.style.setProperty("--tune-paste-duration", `${Math.round(840 / speed)}ms`);
  app.style.setProperty("--tune-transition", `${Math.round(160 / Math.sqrt(speed))}ms`);
  app.style.setProperty("--mode-transition", `${modeTransitionMs}ms`);
  app.style.setProperty("--mode-stagger", `${modeStaggerMs}ms`);
  app.dataset.showHints = tuning.showHints ? "true" : "false";
  app.dataset.showRail = tuning.showRail ? "true" : "false";
  app.dataset.showFieldRing = tuning.showFieldRing ? "true" : "false";
  app.dataset.showWave = tuning.showWave ? "true" : "false";
  app.dataset.fillCompleted = tuning.fillCompletedStages ? "true" : "false";

  if (!options.skipSave) saveTuning();
  updatePresetButtons();
  tuningOutput.textContent = options.label || matchingTuningPreset() || "Custom";
  if (app.dataset.trackTransition) {
    scheduleTrackTransitionClear();
  }
}

function updatePresetButtons() {
  document.querySelectorAll("[data-tune-preset]").forEach((button) => {
    button.classList.toggle("active", button.dataset.tunePreset === matchingTuningPreset());
  });
}

function matchingTuningPreset() {
  return Object.entries(tuningPresets).find(([, preset]) => tuningMatches(preset))?.[0] || "";
}

function tuningMatches(preset) {
  const candidate = sanitizeTuning(preset);
  return tuningControls.every((control) => {
    const value = tuning[control.key];
    const target = candidate[control.key];
    return control.type === "toggle" ? value === target : Math.abs(value - target) < 0.001;
  });
}

function updateTuningFromInput(input) {
  const control = tuningControls.find((item) => item.key === input.name);
  if (!control) return;
  tuning[input.name] = control.type === "toggle" ? input.checked : Number(input.value);
  updateTuningValueLabel(input.name);
  applyTuning();
}

function applyTuningPreset(name) {
  tuning = sanitizeTuning(tuningPresets[name] || tuningDefaults);
  syncTuningInputs();
  applyTuning({ label: name });
}

async function copyTuningValues() {
  const text = JSON.stringify(tuning, null, 2);
  try {
    await navigator.clipboard.writeText(text);
    tuningOutput.textContent = "Copied values";
  } catch {
    tuningOutput.textContent = text.replace(/\s+/g, " ");
  }
}

function startRecording(nextLatched = false) {
  if (["transcribing", "improving", "delivering"].includes(state)) return;
  clearFlow();
  elapsedSeconds = 0;
  applyState("starting", { updateUrl: true, replace: true, elapsed: 0 });
  targetField.focus();
  flowTimer = window.setTimeout(() => {
    applyState(nextLatched ? "latched" : "recording", {
      updateUrl: true,
      replace: true,
      elapsed: 0,
      liveTimer: true
    });
  }, 260);
}

function releaseRecording(force = false) {
  if (state === "starting") {
    clearTimeout(flowTimer);
    runProcessingFlow();
    return;
  }
  if (state !== "recording" && state !== "latched") return;
  if (latched && !force) return;
  stopTimer();
  runProcessingFlow();
}

function toggleLatch() {
  if (state === "latched") {
    releaseRecording(true);
    return;
  }
  if (state === "recording") {
    applyState("latched", {
      updateUrl: true,
      replace: true,
      elapsed: elapsedSeconds,
      liveTimer: true
    });
    return;
  }
  startRecording(true);
}

function cancel() {
  if (state === "idle") return;
  clearFlow();
  applyState("cancelled", { updateUrl: true, replace: true, elapsed: 0 });
  flowTimer = window.setTimeout(() => {
    applyState("idle", { updateUrl: true, replace: true });
  }, 850);
}

function playFlow() {
  clearFlow();
  elapsedSeconds = 0;
  const steps = [
    { state: "starting", delay: 680, elapsed: 0 },
    { state: "recording", delay: 1250, elapsed: 0, liveTimer: true },
    { state: "latched", delay: 850, liveTimer: true },
    { state: "transcribing", delay: 980 },
    { state: "improving", delay: 1120 },
    { state: "delivering", delay: 760 },
    { state: "pasted", delay: 950, appendDelivery: true },
    { state: "done", delay: 900 },
    { state: "ready", delay: 0 }
  ];

  let index = 0;
  function next() {
    const step = steps[index];
    applyState(step.state, {
      updateUrl: true,
      replace: true,
      elapsed: step.elapsed,
      liveTimer: step.liveTimer,
      keepTimer: step.liveTimer
    });

    if (step.appendDelivery) appendDeliveredText("pasted");

    index += 1;
    if (index < steps.length) {
      flowTimer = window.setTimeout(next, step.delay);
    }
  }
  next();
}

function runProcessingFlow() {
  const steps = [
    { state: "transcribing", delay: 1000 },
    { state: "improving", delay: 1120 },
    { state: "delivering", delay: 760 },
    { state: "pasted", delay: 950, appendDelivery: true },
    { state: "done", delay: 1100 },
    { state: "ready", delay: 0 }
  ];

  let index = 0;
  function next() {
    const step = steps[index];
    applyState(step.state, { updateUrl: true, replace: true });

    if (step.appendDelivery) appendDeliveredText("pasted");

    index += 1;
    if (index < steps.length) {
      flowTimer = window.setTimeout(next, step.delay);
    }
  }
  next();
}

function appendDeliveredText(kind) {
  const samples = {
    pasted: "This is the finished AutoImproveRecorder text landing in the focused field.",
    submitted: "This text was submitted after paste.",
    copied: "This text was copied for manual paste."
  };
  targetField.value += `\n\n${samples[kind] || samples.pasted}`;
}

function startTimer() {
  stopTimer();
  recordingStartedAt = Date.now() - elapsedSeconds * 1000;
  timerId = window.setInterval(() => {
    elapsedSeconds = Math.max(0, Math.floor((Date.now() - recordingStartedAt) / 1000));
    render();
  }, 200);
}

function stopTimer() {
  clearInterval(timerId);
  timerId = 0;
}

function clearFlow() {
  clearTimeout(flowTimer);
  flowTimer = 0;
  stopTimer();
}

function menuTextForState(value) {
  const info = stateInfo(value);
  if (value === "recording" || value === "latched") {
    return `${info.menu} ${formatTimer(elapsedSeconds)}`;
  }
  return info.menu;
}

function formatTimer(seconds) {
  const mins = Math.floor(seconds / 60).toString().padStart(2, "0");
  const secs = Math.floor(seconds % 60).toString().padStart(2, "0");
  return `${mins}:${secs}`;
}

function statusTrack(modifier = "") {
  const className = modifier ? `status-track ${modifier}` : "status-track";
  return `
    <div class="${className}" aria-hidden="true">
      ${stages
        .map((stageItem, index) => `<span class="track-pill" data-stage="${stageItem.key}" style="--pill-index: ${index}"></span>`)
        .join("")}
    </div>
  `;
}

function keyHints(short = false) {
  return `<div class="key-hints" data-bind="hints" data-hint-size="${short ? "short" : "full"}">${hintsForState(state, short)}</div>`;
}

function hintsForState(value, short = false) {
  const info = stateInfo(value);
  switch (info.commandMode) {
    case "recording":
      return short
        ? "<kbd>Space</kbd><span>lock</span><kbd>Esc</kbd><span>cancel</span>"
        : "<kbd>Release</kbd><span>send</span><kbd>Space</kbd><span>lock</span><kbd>Esc</kbd><span>cancel</span>";
    case "latched":
      return "<kbd>Space</kbd><span>send</span><kbd>Esc</kbd><span>cancel</span>";
    case "capture":
      return "<kbd>Esc</kbd><span>cancel startup</span>";
    case "wait":
      return "<span class=\"hint-pill\">Working</span><span>keep the target ready</span>";
    case "deliver":
      return "<span class=\"hint-pill\">Delivering</span><span>keep focus in place</span>";
    case "copy":
      return "<kbd>Command-V</kbd><span>manual paste</span>";
    case "permission":
      return "<span class=\"hint-pill danger\">Open System Settings</span>";
    case "model":
      return "<span class=\"hint-pill warning\">Choose a preset</span>";
    case "repair":
      return "<span class=\"hint-pill danger\">Open preview</span><span>recover text</span>";
    case "done":
      return "<span class=\"hint-pill success\">Finished</span>";
    default:
      return short ? "<kbd>Hold</kbd><span>dictate</span>" : "<kbd>Hold</kbd><span>record to dictate</span>";
  }
}

function renderEdgeInstrument() {
  return `
    <div class="variant-a-root">
      <div class="edge-instrument">
        <div class="status">
          <strong data-bind="label">Ready</strong>
          <span data-bind="detail">Hold to dictate.</span>
        </div>
        ${statusTrack()}
        <div class="timer" data-bind="timer">00:00</div>
        ${keyHints()}
      </div>
      <div class="paste-flight"></div>
    </div>
  `;
}

function renderFieldAttached() {
  return `
    <div class="variant-b-root">
      <div class="field-ring"></div>
      <div class="field-anchor">
        <span class="dot"></span>
        <strong data-bind="label">Ready</strong>
        ${statusTrack()}
        <span class="timer" data-bind="timer">00:00</span>
      </div>
      <div class="field-command" data-bind="command">Hold record to start.</div>
      <div class="paste-flight"></div>
    </div>
  `;
}

function renderMicroHUD() {
  return `
    <div class="variant-c-root">
      <div class="cursor-hud">
        <div class="cursor-hud-inner">
          ${statusTrack("compact")}
          <strong data-bind="label">Ready</strong>
          <span class="timer" data-bind="timer">00:00</span>
        </div>
      </div>
      <div class="ambient-hints">${keyHints(true)}</div>
      <div class="paste-flight"></div>
    </div>
  `;
}

function renderGlowReadout() {
  return `
    <div class="variant-d-root">
      <div class="edge-port"></div>
      <div class="glow-tether"></div>
      <div class="glow-readout">
        <div class="readout-core">
          <span class="readout-dot"></span>
          ${statusTrack("compact")}
          <span class="timer" data-bind="timer">00:00</span>
        </div>
        <div class="readout-copy">
          <strong data-bind="label">Ready</strong>
          <span data-bind="detail">Hold to dictate.</span>
          <em data-bind="command">Hold record to start.</em>
        </div>
      </div>
      <div class="glow-command-line">${keyHints(true)}</div>
      <div class="paste-flight"></div>
    </div>
  `;
}

renderStateControls();
renderTuningControls();
applyTuning({ skipSave: true });

recordButton.addEventListener("pointerdown", (event) => {
  event.preventDefault();
  startRecording(false);
});

recordButton.addEventListener("pointerup", (event) => {
  event.preventDefault();
  releaseRecording();
});

recordButton.addEventListener("pointerleave", () => releaseRecording());
latchButton.addEventListener("click", toggleLatch);
cancelButton.addEventListener("click", cancel);
playFlowButton.addEventListener("click", playFlow);
prevVariant.addEventListener("click", () => cycleVariant(-1));
nextVariant.addEventListener("click", () => cycleVariant(1));

stateGrid.addEventListener("click", (event) => {
  const button = event.target.closest("[data-state-jump]");
  if (!button) return;
  jumpToState(button.dataset.stateJump);
});

tuningForm.addEventListener("input", (event) => {
  const input = event.target;
  if (!(input instanceof HTMLInputElement)) return;
  updateTuningFromInput(input);
});

const tuningTip = document.createElement("div");
tuningTip.className = "tuning-tip";
tuningTip.setAttribute("role", "tooltip");
document.body.appendChild(tuningTip);

function showTuningTip(control) {
  const tip = control && control.dataset ? control.dataset.tip : "";
  if (!tip) {
    hideTuningTip();
    return;
  }
  tuningTip.textContent = tip;
  const controlRect = control.getBoundingClientRect();
  const panel = control.closest(".tuning-panel");
  const panelRect = (panel || control).getBoundingClientRect();
  const tipRect = tuningTip.getBoundingClientRect();
  // Float to the left of the panel by default; flip right only if cramped.
  let left = panelRect.left - tipRect.width - 14;
  if (left < 12) left = panelRect.right + 14;
  let top = controlRect.top + controlRect.height / 2 - tipRect.height / 2;
  top = Math.max(12, Math.min(top, window.innerHeight - tipRect.height - 12));
  tuningTip.style.left = `${Math.round(left)}px`;
  tuningTip.style.top = `${Math.round(top)}px`;
  tuningTip.classList.add("is-visible");
}

function hideTuningTip() {
  tuningTip.classList.remove("is-visible");
}

tuningForm.addEventListener("mouseover", (event) => {
  const control = event.target.closest(".tuning-control");
  if (control) showTuningTip(control);
});

tuningForm.addEventListener("mouseout", (event) => {
  const to = event.relatedTarget;
  if (!to || !to.closest || !to.closest(".tuning-control")) hideTuningTip();
});

tuningForm.addEventListener("focusin", (event) => {
  const control = event.target.closest(".tuning-control");
  if (control) showTuningTip(control);
});

tuningForm.addEventListener("focusout", hideTuningTip);

tuningPresetsRoot.addEventListener("click", (event) => {
  const button = event.target.closest("[data-tune-preset]");
  if (!button) return;
  applyTuningPreset(button.dataset.tunePreset);
});

resetTuneButton.addEventListener("click", () => {
  applyTuningPreset("Subtle");
});

copyTuneButton.addEventListener("click", copyTuningValues);

window.addEventListener("keydown", (event) => {
  const tag = event.target.tagName;
  const typing = tag === "INPUT" || tag === "TEXTAREA" || event.target.isContentEditable;
  if (!typing && event.key === "ArrowLeft") {
    event.preventDefault();
    cycleVariant(-1);
  }
  if (!typing && event.key === "ArrowRight") {
    event.preventDefault();
    cycleVariant(1);
  }
  if (event.key === " " && (!typing || ["starting", "recording", "latched"].includes(state))) {
    event.preventDefault();
    toggleLatch();
  }
  if (event.key === "Escape") {
    event.preventDefault();
    cancel();
  }
});

window.addEventListener("popstate", () => {
  state = getStateKey();
  latched = state === "latched";
  clearFlow();
  setVariant(getVariantKey(), true, true);
});

setVariant(getVariantKey(), true);
