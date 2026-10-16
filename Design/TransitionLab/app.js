/*
  TransitionLab — waveform -> stage handoff microscope.

  One large pill series is driven by a single normalized time `tau` (ms relative
  to release, at tau = 0). tau < 0 is the live recording waveform; tau >= 0 is the
  resolution into the stage bar.

  The resolution is a single CONTINUOUS damped morph, not a gather-then-settle:
  at release the wave keeps moving and its amplitude damps to zero while each
  pill's centre drifts to its stage height. Because tau = 0 is just "stop
  sampling and start damping", the motion is velocity-continuous there — no flat
  frame, no eruption. The emphasis glides from pill 1 (Capture) to pill 2
  (Transcribe): pill 1 pulses up early, pill 2 swells up late into the active
  height. A slider scrubs tau; play advances it in slow motion.
*/

const PILL_COUNT = 6;
const ACTIVE_INDEX = 1; // "Transcribe" is the incoming active stage
const WINDOW = { pre: 760, post: 1100 }; // scrub range, ms around release
const STEP_MS = 16;

// Fixed model values (Subtle defaults that this lab does not expose as dials).
const fixed = {
  waveDuration: 760,
  waveDelayStep: 90,
  waveMinHeight: 5,
  pillBaseHeight: 14,
  trackHiddenScale: 0.92,
  stageActiveScaleX: 1.08,
  stageActiveScaleY: 1.25,
  stageMotionScale: 1.05,
  stageMotionDuration: 1650,
  waveTroughOpacity: 0.48,
  wavePeakOpacity: 0.92,
  stageCompleteOpacity: 0.68,
  stageActiveOpacity: 1,
  stageUpcomingOpacity: 0.22
};

// Dials the lab exposes for the resolution.
const dials = {
  speed: 0.15,
  resolveMs: 520,
  staggerMs: 16,
  leadBump: 0.5,
  activeOvershoot: 0.5,
  settleBounce: 0.4,
  waveMaxHeight: 22
};

const dialDefs = [
  { key: "resolveMs", label: "Resolve time", min: 160, max: 1200, step: 20, unit: "ms" },
  { key: "staggerMs", label: "Pill stagger", min: 0, max: 80, step: 1, unit: "ms" },
  { key: "leadBump", label: "Capture lead", min: 0, max: 1.2, step: 0.02, unit: "×" },
  { key: "activeOvershoot", label: "Active overshoot", min: 0, max: 1.2, step: 0.02, unit: "×" },
  { key: "settleBounce", label: "Settle bounce", min: 0, max: 1, step: 0.02, unit: "×" },
  { key: "waveMaxHeight", label: "Wave height", min: 6, max: 52, step: 1, unit: "px" }
];

// ---- Easing ----
function cubicBezier(x1, y1, x2, y2) {
  const cx = 3 * x1;
  const bx = 3 * (x2 - x1) - cx;
  const ax = 1 - cx - bx;
  const cy = 3 * y1;
  const by = 3 * (y2 - y1) - cy;
  const ay = 1 - cy - by;
  const sampleX = (t) => ((ax * t + bx) * t + cx) * t;
  const sampleY = (t) => ((ay * t + by) * t + cy) * t;
  const solveX = (x) => {
    let t = x;
    for (let i = 0; i < 6; i++) {
      const err = sampleX(t) - x;
      const d = (3 * ax * t + 2 * bx) * t + cx;
      if (Math.abs(err) < 1e-5 || d === 0) break;
      t -= err / d;
    }
    return Math.min(1, Math.max(0, t));
  };
  return (x) => sampleY(solveX(x));
}

const easeOut = cubicBezier(0.2, 0.8, 0.2, 1);
const easeInOut = cubicBezier(0.42, 0, 0.58, 1);
const lerp = (a, b, t) => a + (b - a) * t;
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

// Smooth hump: 0 at q=0 and q=1, 1 at q=peak, with zero slope everywhere
// (cosine halves), so adding it never introduces a corner.
function humpAt(q, peak) {
  if (q <= 0 || q >= 1) return 0;
  const t = q < peak ? q / peak : (1 - q) / (1 - peak);
  return 0.5 - 0.5 * Math.cos(Math.PI * t);
}

// Colours from the prototype: recording red, transcribe orange, upcoming dim
// white. Colour cross-fades with the morph progress, so it starts red at
// release and resolves with the shape.
const RECORD_RGB = [255, 75, 87];
const STAGE_RGB = [244, 165, 63];
const UPCOMING_RGB = [232, 236, 244];
const rgbStr = (c) => `rgb(${c[0]}, ${c[1]}, ${c[2]})`;
const mixRgb = (a, b, t) => [
  Math.round(lerp(a[0], b[0], t)),
  Math.round(lerp(a[1], b[1], t)),
  Math.round(lerp(a[2], b[2], t))
];

// ---- Model ----
function roleOf(i) {
  if (i === ACTIVE_INDEX) return "active";
  return i < ACTIVE_INDEX ? "complete" : "upcoming";
}

function waveScales() {
  const base = fixed.pillBaseHeight;
  return {
    min: (fixed.waveMinHeight / base) * fixed.trackHiddenScale,
    max: dials.waveMaxHeight / base
  };
}

function wavePhase(tau, i) {
  return 0.5 - 0.5 * Math.cos((2 * Math.PI * (tau - i * fixed.waveDelayStep)) / fixed.waveDuration);
}

function waveScaleAt(tau, i) {
  const { min, max } = waveScales();
  return min + (max - min) * wavePhase(tau, i);
}

function waveOpacityAt(tau, i) {
  return lerp(fixed.waveTroughOpacity, fixed.wavePeakOpacity, wavePhase(tau, i));
}

// Capture (pill 0) leads, then the bar resolves left-to-right.
function pillDelay(i) {
  return i * dials.staggerMs;
}

function breathe(role, sinceSettleMs) {
  if (role === "upcoming" || sinceSettleMs <= 0) return 1;
  const s = 0.5 - 0.5 * Math.cos((2 * Math.PI * sinceSettleMs) / fixed.stageMotionDuration);
  return 1 + (fixed.stageMotionScale - 1) * s;
}

function stageTargetScale(role) {
  return role === "active" ? fixed.stageActiveScaleY : 1;
}

function stageTargetOpacity(role) {
  if (role === "active") return fixed.stageActiveOpacity;
  return role === "complete" ? fixed.stageCompleteOpacity : fixed.stageUpcomingOpacity;
}

function poseAt(tau, i) {
  const role = roleOf(i);
  if (tau < 0) {
    return { scaleY: waveScaleAt(tau, i), scaleX: 1, opacity: waveOpacityAt(tau, i), role, color: RECORD_RGB };
  }

  const { min, max } = waveScales();
  const waveCenter = (min + max) / 2;
  const local = tau - pillDelay(i);
  const q = clamp(local / dials.resolveMs, 0, 1);
  const e = easeInOut(q);

  const target = stageTargetScale(role);
  let scaleY;
  if (q >= 1) {
    // Settled: hold the stage height with a gentle breath.
    scaleY = target * breathe(role, local - dials.resolveMs);
  } else {
    // Damped morph: the live wave keeps moving while its swing fades to zero and
    // the centre drifts to the stage height.
    const osc = (waveScaleAt(tau, i) - waveCenter) * (1 - e);
    scaleY = lerp(waveCenter, target, e) + osc;
    // Emphasis glides from capture (early) to active (late).
    if (i === 0) {
      scaleY += humpAt(q, 0.28) * dials.leadBump;
    }
    if (role === "active") {
      scaleY += humpAt(q, 0.72) * dials.activeOvershoot;
      scaleY -= humpAt(q, 0.9) * dials.settleBounce * 0.22; // small ring after the swell
    }
  }

  const opacity = lerp(waveOpacityAt(tau, i), stageTargetOpacity(role), e);
  const colorTarget = role === "upcoming" ? UPCOMING_RGB : STAGE_RGB;
  const color = mixRgb(RECORD_RGB, colorTarget, e);
  const scaleX = role === "active" ? lerp(1, fixed.stageActiveScaleX, e) : 1;
  return { scaleY, scaleX, opacity, role, color };
}

function resolveEnd() {
  return dials.resolveMs + (PILL_COUNT - 1) * dials.staggerMs;
}

function phaseLabel(tau) {
  if (tau < 0) return "Recording";
  if (tau <= resolveEnd()) return "Resolving";
  return "Settled";
}

// ---- DOM + state ----
const pillsRoot = document.getElementById("pills");
const phaseEl = document.getElementById("phase");
const tauEl = document.getElementById("tau");
const scrub = document.getElementById("scrub");
const playButton = document.getElementById("play");
const speedInput = document.getElementById("speed");
const speedOut = document.getElementById("speedOut");
const loopInput = document.getElementById("loop");
const dialsRoot = document.getElementById("dials");

const pillEls = [];
for (let i = 0; i < PILL_COUNT; i++) {
  const el = document.createElement("div");
  el.className = "pill";
  pillEls.push(el);
  pillsRoot.appendChild(el);
}

let tau = 0;
let playing = false;
let rafId = null;
let lastTs = null;

function fractionToTau(fraction) {
  return lerp(-WINDOW.pre, WINDOW.post, fraction);
}

function tauToFraction(value) {
  return (value - -WINDOW.pre) / (WINDOW.pre + WINDOW.post);
}

function render() {
  for (let i = 0; i < PILL_COUNT; i++) {
    const pose = poseAt(tau, i);
    const el = pillEls[i];
    el.style.transform = `scaleX(${pose.scaleX.toFixed(3)}) scaleY(${pose.scaleY.toFixed(3)})`;
    el.style.opacity = pose.opacity.toFixed(3);
    el.style.backgroundColor = rgbStr(pose.color);
    el.style.boxShadow = pose.role === "active" ? `0 0 30px rgba(${pose.color[0]}, ${pose.color[1]}, ${pose.color[2]}, 0.45)` : "none";
    el.dataset.role = pose.role;
  }
  phaseEl.textContent = phaseLabel(tau);
  phaseEl.style.color = tau < 0 ? rgbStr(RECORD_RGB) : rgbStr(STAGE_RGB);
  const rounded = Math.round(tau);
  tauEl.textContent = `${rounded >= 0 ? "+" : "−"}${Math.abs(rounded)} ms`;
  scrub.value = String(Math.round(clamp(tauToFraction(tau), 0, 1) * 1000));
}

function setTau(value) {
  tau = clamp(value, -WINDOW.pre, WINDOW.post);
  render();
}

function updatePlayButton() {
  playButton.textContent = playing ? "❚❚ Pause" : "▶ Play slow-mo";
  playButton.classList.toggle("primary", !playing);
}

function tick(ts) {
  if (!playing) return;
  if (lastTs === null) lastTs = ts;
  const dt = ts - lastTs;
  lastTs = ts;
  tau += dt * dials.speed;
  if (tau >= WINDOW.post) {
    if (loopInput.checked) {
      tau = -WINDOW.pre;
    } else {
      tau = WINDOW.post;
      playing = false;
      updatePlayButton();
    }
  }
  render();
  if (playing) rafId = requestAnimationFrame(tick);
}

function play() {
  if (playing) return;
  if (tau >= WINDOW.post) tau = -WINDOW.pre;
  playing = true;
  lastTs = null;
  updatePlayButton();
  rafId = requestAnimationFrame(tick);
}

function pause() {
  if (!playing) return;
  playing = false;
  if (rafId) cancelAnimationFrame(rafId);
  rafId = null;
  updatePlayButton();
}

function togglePlay() {
  if (playing) pause();
  else play();
}

// ---- Dials ----
function renderDials() {
  dialsRoot.innerHTML = dialDefs
    .map(
      (d) => `
        <label class="dial">
          <span class="dial-head">
            <span>${d.label}</span>
            <output data-out="${d.key}"></output>
          </span>
          <input type="range" name="${d.key}" min="${d.min}" max="${d.max}" step="${d.step}" />
        </label>
      `
    )
    .join("");
  dialDefs.forEach((d) => {
    const input = dialsRoot.querySelector(`input[name="${d.key}"]`);
    input.value = String(dials[d.key]);
    updateDialOut(d);
  });
}

function updateDialOut(d) {
  const out = dialsRoot.querySelector(`[data-out="${d.key}"]`);
  const value = dials[d.key];
  const shown = Number.isInteger(value) ? value : value.toFixed(2);
  out.textContent = d.unit ? `${shown}${d.unit}` : shown;
}

dialsRoot.addEventListener("input", (event) => {
  const input = event.target;
  if (!(input instanceof HTMLInputElement)) return;
  const def = dialDefs.find((d) => d.key === input.name);
  if (!def) return;
  dials[def.key] = Number(input.value);
  updateDialOut(def);
  render();
});

// ---- Wiring ----
scrub.addEventListener("input", () => {
  pause();
  setTau(fractionToTau(Number(scrub.value) / 1000));
});

playButton.addEventListener("click", togglePlay);
document.getElementById("stepBack").addEventListener("click", () => {
  pause();
  setTau(tau - STEP_MS);
});
document.getElementById("stepFwd").addEventListener("click", () => {
  pause();
  setTau(tau + STEP_MS);
});
document.getElementById("toHandoff").addEventListener("click", () => {
  pause();
  setTau(0);
});

speedInput.addEventListener("input", () => {
  dials.speed = Number(speedInput.value);
  speedOut.textContent = `${dials.speed.toFixed(2)}×`;
});

window.addEventListener("keydown", (event) => {
  if (event.target instanceof HTMLInputElement && event.target.type === "range" && event.key !== " ") return;
  if (event.key === " ") {
    event.preventDefault();
    togglePlay();
  } else if (event.key === "ArrowLeft") {
    event.preventDefault();
    pause();
    setTau(tau - STEP_MS);
  } else if (event.key === "ArrowRight") {
    event.preventDefault();
    pause();
    setTau(tau + STEP_MS);
  }
});

renderDials();
render();
play();
