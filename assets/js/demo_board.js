// <oskol-demo-board>: the guest home's board. A decorative, looping demo
// game on a CSS-3D board tilted back on the desk: checkers lift and move,
// dice tumble, Sage thinks on the far edge. It plays no real game and
// talks to nothing; it is drawn in the page's board theme (the `--bg-*`
// tokens a `.bg-theme-*` ancestor sets), so a new theme repaints it with no
// JS at all.
//
// It fills its box and scales the board, the chip and the shadow to fit
// inside it, centred. The board always lies the long way across: it is
// never turned, whatever the box's shape.
//
// API
//   attribute `reduced-motion`   force the still version (the OS setting
//                                 `prefers-reduced-motion` is honoured anyway)
//   attribute `align="bottom"`   sit on the bottom of the box, spare height above
//   el.roll(color, a, b)         throw the board's dice: color "W"/"white"
//                                 or "B"/"black", a and b 1..6
//
// The loop runs only while the element is connected, on screen and the
// document is visible; it starts the demo game over when it comes back.

const NS = "http://www.w3.org/2000/svg";
const ROBOT =
  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 8V4H8"/><rect width="16" height="12" x="4" y="8" rx="2"/><path d="M2 14h2"/><path d="M20 14h2"/><path d="M15 13v2"/><path d="M9 13v2"/></svg>';

// The opening position, and a short, legal-looking game from it.
const OPEN = { W: { 24: 2, 13: 5, 8: 3, 6: 5 }, B: { 1: 2, 12: 5, 17: 3, 19: 5 } };
const SCRIPT = [
  ["W", 3, 1, [[8, 5], [6, 5]]],
  ["B", 6, 4, [[12, 18], [12, 16]]],
  ["W", 6, 2, [[13, 7], [13, 11]]],
  ["B", 5, 3, [[17, 22], [19, 22]]],
  ["W", 4, 2, [[8, 4], [6, 4]]],
  ["B", 6, 5, [[16, 22], [18, 23]]],
  ["W", 5, 5, [[13, 8], [13, 8], [11, 6], [7, 2]]],
];

const R = 21.5;
const STEP = 43;
const LAYERS = 16;
const TILT = 32;

const px = (p) =>
  p <= 6 ? 336 + (6 - p) * 48 + 24
  : p <= 12 ? 16 + (12 - p) * 48 + 24
  : p <= 18 ? 16 + (p - 13) * 48 + 24
  : 336 + (p - 19) * 48 + 24;
const isTop = (p) => p >= 13;
const slot = (p, k) => {
  const kk = k < 5 ? k : 4 - (k - 5) * 0.5 - 0.25; // overlap beyond five
  const y = isTop(p) ? 16 + R + 1 + Math.max(0, kk) * STEP : 444 - R - 1 - Math.max(0, kk) * STEP;
  return [px(p), y];
};

// Theme colours, mixed from the page's tokens so a theme class repaints them live.
const mix = (v, other, pct) => `color-mix(in oklab, var(${v}), ${other} ${pct}%)`;
const stop = (offset, color) => `<stop offset="${offset}" style="stop-color: ${color}"/>`;

let instances = 0;

class OskolDemoBoard extends HTMLElement {
  static get observedAttributes() {
    return ["reduced-motion", "align"];
  }

  constructor() {
    super();
    this._uid = `odb${++instances}`;
    this._built = false;
    this._gen = 0;
    this._timers = new Set();
    this._frames = new Set();
    this._visible = true;
    this._fitQueued = 0;
    this._mq = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : null;
    this._onMotion = () => this._applyMotion();
    this._onVisibility = () => this._sync();
  }

  connectedCallback() {
    this.setAttribute("aria-hidden", "true");
    if (!this._built) this._build();
    this._connected = true;
    this._applyMotion();
    if (this._mq && this._mq.addEventListener) this._mq.addEventListener("change", this._onMotion);
    document.addEventListener("visibilitychange", this._onVisibility);
    this._ro = new ResizeObserver(() => this._queueFit());
    this._ro.observe(this);
    this._io = new IntersectionObserver((entries) => {
      for (const e of entries) this._visible = e.isIntersecting;
      this._sync();
    });
    this._io.observe(this);
    this._fit();
    this._sync();
  }

  disconnectedCallback() {
    this._connected = false;
    this._stop();
    if (this._mq && this._mq.removeEventListener) this._mq.removeEventListener("change", this._onMotion);
    document.removeEventListener("visibilitychange", this._onVisibility);
    if (this._ro) this._ro.disconnect();
    if (this._io) this._io.disconnect();
    this._ro = this._io = null;
    if (this._fitQueued) cancelAnimationFrame(this._fitQueued);
    this._fitQueued = 0;
  }

  attributeChangedCallback(name) {
    if (!this._built) return;
    if (name === "align") this._queueFit();
    else this._applyMotion();
  }

  // ---- the page's hook: throw the dice on the board ----
  roll(color, a, b) {
    if (!this._built) return;
    const side = String(color).toUpperCase().startsWith("B") ? "B" : "W";
    const face = (v) => Math.min(6, Math.max(1, Math.round(Number(v)) || 1));
    const box = side === "W" ? this._diceW : this._diceB;
    const other = side === "W" ? this._diceB : this._diceW;
    other.querySelectorAll(".db-die").forEach((d) => d.classList.remove("is-show"));
    box.querySelectorAll(".db-die").forEach((d, i) => {
      const v = face(i === 0 ? a : b);
      d.className = "db-die";
      void d.offsetWidth; // restart the tumble
      d.className = `db-die is-show db-d${v}` + (this._reduce ? "" : " is-rolling");
    });
  }

  // ---- building ----
  _build() {
    this._built = true;
    const u = this._uid;
    const root = document.createElement("div");
    root.className = "demo-board";
    root.setAttribute("aria-hidden", "true");
    root.innerHTML = `
      <div class="db-stage">
        <div class="db-floor"></div>
        <div class="db-rig">
          <div class="db-slab">
            <div class="db-turn">
              <div class="db-drop"></div>
              <div class="db-wrap">
                <svg class="db-board" viewBox="0 0 640 460" preserveAspectRatio="none" focusable="false"></svg>
                <div class="db-sheen"></div>
                <div class="db-dice db-white"><div class="db-die"></div><div class="db-die"></div></div>
                <div class="db-dice db-black"><div class="db-die"></div><div class="db-die"></div></div>
              </div>
            </div>
            <div class="db-seat"><span class="db-av">${ROBOT}</span>Sage<span class="db-thinking"><b></b><b></b><b></b></span></div>
          </div>
        </div>
      </div>`;
    this.appendChild(root);
    this._root = root;
    this._stage = root.querySelector(".db-stage");
    this._floor = root.querySelector(".db-floor");
    this._rig = root.querySelector(".db-rig");
    this._turn = root.querySelector(".db-turn");
    this._wrapEl = root.querySelector(".db-wrap");
    this._seat = root.querySelector(".db-seat");
    this._drop = root.querySelector(".db-drop");
    this._thinking = root.querySelector(".db-thinking");
    this._diceW = root.querySelector(".db-white");
    this._diceB = root.querySelector(".db-black");
    root.querySelectorAll(".db-die").forEach((d) => (d.innerHTML = "<i></i>".repeat(9)));

    // the body of the board: stacked layers under the face, darkest at the bottom
    this._layers = [];
    for (let i = LAYERS; i >= 1; i--) {
      const d = document.createElement("div");
      d.className = "db-layer" + (i === LAYERS ? " db-base" : "");
      d.dataset.i = i;
      this._turn.insertBefore(d, this._wrapEl);
      this._layers.push(d);
    }
    this._rig.style.transform = `rotateY(0deg) rotateX(${TILT}deg) rotateZ(0deg)`;

    this._drawBoard(root.querySelector(".db-board"), u);
    this._thinking.style.display = "none";
  }

  _drawBoard(svg, u) {
    const el = (n, a, p) => {
      const e = document.createElementNS(NS, n);
      for (const k in a) e.setAttribute(k, a[k]);
      (p || svg).appendChild(e);
      return e;
    };
    const defs = el("defs", {});
    defs.innerHTML = `
      <linearGradient id="${u}-frame" x1="0" y1="0" x2="0" y2="1">${stop(0, mix("--bg-frame", "white", 5))}${stop(1, mix("--bg-frame", "black", 40))}</linearGradient>
      <radialGradient id="${u}-felt" cx=".5" cy=".45" r=".75">${stop(0, mix("--bg-felt", "white", 3))}${stop(1, mix("--bg-felt", "black", 26))}</radialGradient>
      <linearGradient id="${u}-pa" x1="0" y1="0" x2="0" y2="1">${stop(0, mix("--bg-point-a", "white", 10))}${stop(1, mix("--bg-point-a", "black", 18))}</linearGradient>
      <linearGradient id="${u}-pb" x1="0" y1="0" x2="0" y2="1">${stop(0, mix("--bg-point-b", "white", 12))}${stop(1, mix("--bg-point-b", "black", 18))}</linearGradient>
      <radialGradient id="${u}-cw" cx=".38" cy=".32" r=".75">${stop(0, mix("--bg-checker-light", "white", 60))}${stop(0.65, mix("--bg-checker-light", "#1f2c4a", 8))}${stop(1, mix("--bg-checker-light", "#1f2c4a", 30))}</radialGradient>
      <radialGradient id="${u}-cb" cx=".38" cy=".32" r=".75">${stop(0, mix("--bg-checker-dark", "white", 18))}${stop(0.6, "var(--bg-checker-dark)")}${stop(1, mix("--bg-checker-dark", "black", 55))}</radialGradient>
      <filter id="${u}-cs" x="-30%" y="-30%" width="160%" height="170%"><feDropShadow dx="0" dy="3" stdDeviation="2.5" flood-color="#000" flood-opacity=".55"/></filter>`;

    el("rect", { x: 0, y: 0, width: 640, height: 460, rx: 13, fill: `url(#${u}-frame)` });
    el("rect", { x: 16, y: 16, width: 288, height: 428, rx: 8, fill: `url(#${u}-felt)` });
    el("rect", { x: 336, y: 16, width: 288, height: 428, rx: 8, fill: `url(#${u}-felt)` });
    el("rect", { x: 306, y: 16, width: 28, height: 428, rx: 6, class: "db-bar" });
    el("line", { x1: 320, y1: 40, x2: 320, y2: 200, class: "db-barline" });
    el("line", { x1: 320, y1: 260, x2: 320, y2: 420, class: "db-barline" });
    for (let p = 1; p <= 24; p++) {
      const x = px(p);
      const t = isTop(p);
      const base = t ? 16 : 444;
      const tip = t ? 16 + 186 : 444 - 186;
      el("path", {
        d: `M${x - 23} ${base} L${x} ${tip} L${x + 23} ${base} Z`,
        fill: p % 2 ? `url(#${u}-pa)` : `url(#${u}-pb)`,
        opacity: 0.95,
      });
    }
    // inner edge sheen
    el("rect", { x: 1, y: 1, width: 638, height: 458, rx: 12, fill: "none", stroke: "rgba(255,255,255,.07)", "stroke-width": 2 });

    this._svgEl = el;
    this._men = el("g", { class: "db-men" });
  }

  _setup() {
    const el = this._svgEl;
    const u = this._uid;
    this._men.textContent = "";
    this._stacks = {};
    this._pieces = [];
    for (const c of ["W", "B"]) {
      for (const p in OPEN[c]) {
        for (let i = 0; i < OPEN[c][p]; i++) {
          const g = el("g", { class: "db-checker " + (c === "W" ? "db-light" : "db-dark"), filter: `url(#${u}-cs)` }, this._men);
          el("circle", { r: R, class: "db-face", fill: c === "W" ? `url(#${u}-cw)` : `url(#${u}-cb)`, "stroke-width": 1 }, g);
          el("circle", { r: R - 6, fill: "none", class: "db-inner", "stroke-width": 1.5 }, g);
          el("circle", { r: R + 2.5, class: "db-ring" }, g);
          const pc = { c, g, p: +p };
          (this._stacks[p] = this._stacks[p] || []).push(pc);
          this._pieces.push(pc);
          this._place(pc, this._stacks[p].length - 1);
        }
      }
    }
  }

  _place(pc, k) {
    const [x, y] = slot(pc.p, k);
    pc.x = x;
    pc.y = y;
    pc.g.setAttribute("transform", `translate(${x} ${y})`);
  }

  // ---- the loop ----
  _wait(ms, gen) {
    return new Promise((res, rej) => {
      if (gen !== this._gen) return rej(STOP);
      const t = setTimeout(() => {
        this._timers.delete(t);
        gen === this._gen ? res() : rej(STOP);
      }, ms);
      this._timers.add(t);
    });
  }

  _frame(gen) {
    return new Promise((res, rej) => {
      if (gen !== this._gen) return rej(STOP);
      const f = requestAnimationFrame((now) => {
        this._frames.delete(f);
        gen === this._gen ? res(now) : rej(STOP);
      });
      this._frames.add(f);
    });
  }

  async _move(from, to, gen) {
    const pc = this._stacks[from].pop();
    pc.p = to;
    (this._stacks[to] = this._stacks[to] || []).push(pc);
    const [x0, y0] = [pc.x, pc.y];
    const [x1, y1] = slot(to, this._stacks[to].length - 1);
    this._men.appendChild(pc.g);
    this._pieces.forEach((q) => q.g.classList.remove("is-moved"));
    pc.g.classList.add("is-moved");
    pc.x = x1;
    pc.y = y1;
    if (this._reduce) {
      pc.g.setAttribute("transform", `translate(${x1} ${y1})`);
      return this._wait(700, gen);
    }
    const dur = 820;
    const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
    const t0 = performance.now();
    for (;;) {
      const now = await this._frame(gen);
      const t = Math.min(1, Math.max(0, (now - t0) / dur));
      const e = ease(t);
      const lift = Math.sin(Math.PI * t) * 34;
      const s = 1 + Math.sin(Math.PI * t) * 0.12;
      pc.g.setAttribute("transform", `translate(${x0 + (x1 - x0) * e} ${y0 + (y1 - y0) * e - lift}) scale(${s})`);
      if (t >= 1) return;
    }
  }

  async _loop(gen) {
    for (;;) {
      this._setup();
      this._men.style.opacity = "1";
      await this._wait(900, gen);
      for (const [side, a, b, moves] of SCRIPT) {
        this._thinking.style.display = side === "B" ? "" : "none";
        if (side === "B") await this._wait(900, gen);
        this.roll(side, a, b);
        await this._wait(1100, gen);
        for (const [f, t] of moves) {
          await this._move(f, t, gen);
          await this._wait(160, gen);
        }
        await this._wait(900, gen);
      }
      this._thinking.style.display = "none";
      await this._wait(1400, gen);
      this._men.style.opacity = "0";
      this._clearDice();
      await this._wait(700, gen);
    }
  }

  _clearDice() {
    this._root.querySelectorAll(".db-die").forEach((d) => d.classList.remove("is-show", "is-rolling"));
  }

  _sync() {
    const run = this._connected && this._visible && !document.hidden;
    if (run && !this._running) {
      this._running = true;
      const gen = ++this._gen;
      this._clearDice();
      this._loop(gen).catch((e) => {
        if (e !== STOP) throw e;
      });
    } else if (!run && this._running) {
      this._stop();
    }
  }

  _stop() {
    this._running = false;
    this._gen++;
    this._timers.forEach(clearTimeout);
    this._frames.forEach(cancelAnimationFrame);
    this._timers.clear();
    this._frames.clear();
  }

  _applyMotion() {
    this._reduce = this.hasAttribute("reduced-motion") || !!(this._mq && this._mq.matches);
    this._root.classList.toggle("is-reduced", this._reduce);
  }

  // ---- sizing: contain the board, its chip and its shadow in the box ----
  _queueFit() {
    if (this._fitQueued) return;
    this._fitQueued = requestAnimationFrame(() => {
      this._fitQueued = 0;
      this._fit();
    });
  }

  _apply(bw, dx, dy) {
    const s = this._root.style;
    s.setProperty("--bw", `${bw}px`);
    s.setProperty("--dx", `${dx}px`);
    s.setProperty("--dy", `${dy}px`);
    const T = Math.max(bw < 300 ? 5 : 9, this._turn.clientWidth * 0.032);
    this._layers.forEach((d) => (d.style.transform = `translateZ(${(-T * d.dataset.i) / LAYERS}px)`));
    this._drop.style.transform = `translateZ(${-T - this._turn.clientWidth * 0.09}px)`;
  }

  _extent() {
    const h = this.getBoundingClientRect();
    let l = Infinity, t = Infinity, r = -Infinity, b = -Infinity;
    for (const e of [this._wrapEl, this._seat, this._floor]) {
      const q = e.getBoundingClientRect();
      l = Math.min(l, q.left); t = Math.min(t, q.top);
      r = Math.max(r, q.right); b = Math.max(b, q.bottom);
    }
    return { w: r - l, h: b - t, cx: (l + r) / 2 - h.left, cy: (t + b) / 2 - h.top };
  }

  _fit() {
    if (!this._built) return;
    const W = this.clientWidth;
    const H = this.clientHeight;
    if (W < 2 || H < 2) return;
    const pad = 0.97;
    let bw = Math.min(W / 1.2, H / 0.8);
    for (let i = 0; i < 3; i++) {
      this._apply(bw, 0, 0);
      const x = this._extent();
      if (!x.w || !x.h) return;
      const f = Math.min((W * pad) / x.w, (H * pad) / x.h);
      bw = Math.max(40, bw * f);
      if (Math.abs(f - 1) < 0.004) break;
    }
    bw = Math.floor(bw);
    this._apply(bw, 0, 0);
    const x = this._extent();
    // align="bottom": the board sits on the bottom of its box, and whatever
    // height is spare goes above it (the page keeps what is under the board
    // at a fixed distance from it). Centred otherwise.
    const cy = this.getAttribute("align") === "bottom" ? H - x.h / 2 - H * (1 - pad) / 2 : H / 2;
    this._apply(bw, Math.round(W / 2 - x.cx), Math.round(cy - x.cy));
  }
}

const STOP = Symbol("demo-board-stop");

if (!customElements.get("oskol-demo-board")) {
  customElements.define("oskol-demo-board", OskolDemoBoard);
}
