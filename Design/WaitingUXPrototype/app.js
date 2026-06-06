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

let state = "idle";
let latched = false;
let recordingStartedAt = 0;
let timerId = 0;
let flowTimer = 0;
let elapsedSeconds = 0;

function getVariantKey() {
  const params = new URLSearchParams(window.location.search);
  const requested = (params.get("variant") || "A").toUpperCase();
  return variants.some((variant) => variant.key === requested) ? requested : "A";
}

function setVariant(key, replace = false) {
  const variant = variants.find((item) => item.key === key) || variants[0];
  const params = new URLSearchParams(window.location.search);
  params.set("variant", variant.key);
  const nextURL = `${window.location.pathname}?${params.toString()}`;
  window.history[replace ? "replaceState" : "pushState"]({}, "", nextURL);

  app.dataset.variant = variant.key;
  variantKey.textContent = variant.key;
  variantName.textContent = variant.name;
  root.innerHTML = variant.render();
  render();
}

function cycleVariant(direction) {
  const currentKey = getVariantKey();
  const index = variants.findIndex((variant) => variant.key === currentKey);
  const next = variants[(index + direction + variants.length) % variants.length];
  setVariant(next.key);
}

function render() {
  app.dataset.state = state;
  app.style.setProperty("--state-color", colorForState(state));
  stateLabel.textContent = labelForState(state);
  stateReadout.textContent = state;
  recordButton.textContent = state === "recording" || state === "latched" ? "Release to send" : "Hold to record";
  latchButton.textContent = latched ? "Space: unlatch" : "Space: latch";
  modeChip.textContent = latched ? "Persistent recording" : "Walkie talkie";
  menuStatus.textContent = menuTextForState(state);

  document.querySelectorAll("[data-bind='label']").forEach((node) => {
    node.textContent = labelForState(state);
  });
  document.querySelectorAll("[data-bind='detail']").forEach((node) => {
    node.textContent = detailForState(state);
  });
  document.querySelectorAll("[data-bind='timer']").forEach((node) => {
    node.textContent = formatTimer(elapsedSeconds);
  });
  document.querySelectorAll("[data-stage]").forEach((node) => {
    node.classList.toggle("active", node.dataset.stage === stageForState(state));
  });
}

function startRecording(nextLatched = false) {
  if (["transcribing", "cleaning", "pasting"].includes(state)) return;
  clearFlow();
  latched = nextLatched;
  state = nextLatched ? "latched" : "recording";
  recordingStartedAt = Date.now();
  elapsedSeconds = 0;
  clearInterval(timerId);
  timerId = window.setInterval(() => {
    elapsedSeconds = Math.max(0, Math.floor((Date.now() - recordingStartedAt) / 1000));
    render();
  }, 200);
  targetField.focus();
  render();
}

function releaseRecording(force = false) {
  if (state !== "recording" && state !== "latched") return;
  if (latched && !force) return;
  latched = false;
  clearInterval(timerId);
  runProcessingFlow();
}

function toggleLatch() {
  if (state === "latched") {
    releaseRecording(true);
    return;
  }
  startRecording(true);
}

function cancel() {
  if (state === "idle") return;
  clearFlow();
  latched = false;
  state = "cancelled";
  render();
  flowTimer = window.setTimeout(() => {
    state = "idle";
    render();
  }, 850);
}

function runProcessingFlow() {
  const steps = [
    ["transcribing", 1000],
    ["cleaning", 1120],
    ["pasting", 760],
    ["done", 1100],
    ["idle", 0]
  ];

  let index = 0;
  function next() {
    const [nextState, delay] = steps[index];
    state = nextState;
    render();

    if (nextState === "done") {
      targetField.value += "\n\nThis is the finished LAIR text landing in the focused field.";
    }

    index += 1;
    if (index < steps.length) {
      flowTimer = window.setTimeout(next, delay);
    }
  }
  next();
}

function clearFlow() {
  clearTimeout(flowTimer);
  clearInterval(timerId);
}

function colorForState(value) {
  switch (value) {
    case "recording":
    case "latched":
      return "var(--record)";
    case "transcribing":
      return "var(--transcribe)";
    case "cleaning":
      return "var(--clean)";
    case "pasting":
      return "var(--paste)";
    case "done":
      return "var(--success)";
    case "cancelled":
      return "var(--cancel)";
    default:
      return "var(--success)";
  }
}

function labelForState(value) {
  switch (value) {
    case "recording":
      return "Recording";
    case "latched":
      return "Recording locked";
    case "transcribing":
      return "Transcribing";
    case "cleaning":
      return "Cleaning text";
    case "pasting":
      return "Pasting";
    case "done":
      return "Done";
    case "cancelled":
      return "Cancelled";
    default:
      return "Ready";
  }
}

function detailForState(value) {
  switch (value) {
    case "recording":
      return "Release to send. Space locks recording. Esc cancels.";
    case "latched":
      return "Space or the button sends. Esc cancels.";
    case "transcribing":
      return "Audio is becoming text.";
    case "cleaning":
      return "Final wording is being shaped.";
    case "pasting":
      return "Text is moving into the focused field.";
    case "done":
      return "Text landed.";
    case "cancelled":
      return "Recording discarded.";
    default:
      return "Hold to dictate.";
  }
}

function menuTextForState(value) {
  switch (value) {
    case "recording":
    case "latched":
      return `${labelForState(value)} ${formatTimer(elapsedSeconds)}`;
    case "idle":
      return "LAIR ready";
    default:
      return `LAIR ${labelForState(value).toLowerCase()}`;
  }
}

function stageForState(value) {
  if (value === "transcribing") return "transcribe";
  if (value === "cleaning") return "clean";
  if (value === "pasting") return "paste";
  if (value === "done") return "done";
  return "record";
}

function formatTimer(seconds) {
  const mins = Math.floor(seconds / 60).toString().padStart(2, "0");
  const secs = Math.floor(seconds % 60).toString().padStart(2, "0");
  return `${mins}:${secs}`;
}

function waveBars(count = 7) {
  return `<div class="wave" aria-hidden="true">${Array.from({ length: count }, () => "<span></span>").join("")}</div>`;
}

function stageDots() {
  return `
    <div class="stage-dots" aria-hidden="true">
      <span data-stage="record"></span>
      <span data-stage="transcribe"></span>
      <span data-stage="clean"></span>
      <span data-stage="paste"></span>
      <span data-stage="done"></span>
    </div>
  `;
}

function keyHints(short = false) {
  if (short) {
    return `<div class="key-hints"><kbd>Space</kbd><span>lock/send</span><kbd>Esc</kbd><span>cancel</span></div>`;
  }
  return `<div class="key-hints"><kbd>Release</kbd><span>send</span><kbd>Space</kbd><span>lock</span><kbd>Esc</kbd><span>cancel</span></div>`;
}

function renderEdgeInstrument() {
  return `
    <div class="variant-a-root">
      <div class="edge-instrument">
        <div class="status">
          <strong data-bind="label">Ready</strong>
          <span data-bind="detail">Hold to dictate.</span>
        </div>
        ${waveBars()}
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
        ${waveBars(6)}
        <span class="timer" data-bind="timer">00:00</span>
        ${stageDots()}
      </div>
      <div class="paste-flight"></div>
    </div>
  `;
}

function renderMicroHUD() {
  return `
    <div class="variant-c-root">
      <div class="cursor-hud">
        <div class="cursor-hud-inner">
          ${waveBars(5)}
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
          ${waveBars(5)}
          <span class="timer" data-bind="timer">00:00</span>
        </div>
        <div class="readout-copy">
          <strong data-bind="label">Ready</strong>
          <span data-bind="detail">Hold to dictate.</span>
        </div>
      </div>
      <div class="edge-stage-strip">
        <span data-stage="record"></span>
        <span data-stage="transcribe"></span>
        <span data-stage="clean"></span>
        <span data-stage="paste"></span>
        <span data-stage="done"></span>
      </div>
      <div class="glow-command-line">${keyHints(true)}</div>
      <div class="paste-flight"></div>
    </div>
  `;
}

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
prevVariant.addEventListener("click", () => cycleVariant(-1));
nextVariant.addEventListener("click", () => cycleVariant(1));

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
  if (event.key === " " && (state !== "idle" || !typing)) {
    event.preventDefault();
    toggleLatch();
  }
  if (event.key === "Escape") {
    event.preventDefault();
    cancel();
  }
});

window.addEventListener("popstate", () => setVariant(getVariantKey(), true));

setVariant(getVariantKey(), true);
