/* Hero terminal — replays a Session Watch moment on a loop. */
(function () {
  "use strict";
  var SPIN = ["·", "✢", "✳", "✶", "✻", "✽"];

  // Each step: html (string), delay before it appears (ms), type (line-by-line, instant).
  var SCRIPT = [
    { h: '<span class="t-faint">$</span> session watch', d: 300 },
    { h: '<span class="t-clay">✻</span> watching 3 accounts', d: 500 },
    { h: '  <span class="dot dot-yellow"></span> rashid@work <span class="t-faint">·</span> <span class="t-yellow">working</span> <span class="t-faint">· 2 chats</span>', d: 260 },
    { h: '  <span class="dot dot-green"></span> personal <span class="t-faint">·</span> <span class="t-green">free</span>', d: 220 },
    { h: '  <span class="dot dot-red"></span> team <span class="t-faint">·</span> <span class="t-red">limited</span> <span class="t-faint">· resets 14:30 · retry queued ⟳</span>', d: 220 },
    { h: '&nbsp;', d: 500 },
    { h: '<span class="t-user">&gt; fix the flaky relay test</span> <span class="t-faint">— sent from the iphone</span>', d: 900 },
    { h: '  <span class="t-clay spin">✻</span> <span class="t-dim">thinking…</span>', d: 700, spin: true },
    { h: '  <span class="t-faint">▸</span> Bash <span class="t-dim">swift test --filter RelayLiveTests</span> <span class="t-faint">↳ 2 agents</span>', d: 900 },
    { h: '<div class="needs-card"><span class="t-clay">◆ needs you · Edit</span> <span class="t-dim">relay/src/index.ts</span><br><span class="t-green">[allow]</span> <span class="t-dim">[always]</span> <span class="t-red">[deny]</span> <span class="t-faint">← answered from your lock screen</span></div>', d: 1300 },
    { h: '  <span class="t-green">✓</span> 14 tests passed', d: 1100 },
    { h: '<span class="t-green">✓ all done</span> <span class="t-faint">— buddy is celebrating</span>', d: 600, done: true }
  ];

  function run(body) {
    var i = 0, spinTimer = null;
    body.textContent = "";
    var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    function spinLine(lineEl) {
      var s = 0;
      var g = lineEl.querySelector(".spin");
      if (!g || reduced) return null;
      return setInterval(function () { s = (s + 1) % SPIN.length; g.textContent = SPIN[s]; }, 120);
    }

    function next() {
      if (i >= SCRIPT.length) {
        setTimeout(function () { run(body); }, 4000);
        return;
      }
      var step = SCRIPT[i++];
      setTimeout(function () {
        if (spinTimer) { clearInterval(spinTimer); spinTimer = null; }
        var line = document.createElement("div");
        line.className = "tl";
        line.innerHTML = step.h;
        body.appendChild(line);
        if (step.spin) spinTimer = spinLine(line);
        next();
      }, reduced ? 60 : step.d);
    }
    next();
  }

  document.addEventListener("DOMContentLoaded", function () {
    var body = document.getElementById("term-demo");
    if (!body) return;
    if ("IntersectionObserver" in window) {
      var started = false;
      new IntersectionObserver(function (entries, obs) {
        if (!started && entries[0].isIntersecting) { started = true; run(body); obs.disconnect(); }
      }, { threshold: 0.2 }).observe(body);
      // fallback: start anyway after 1.5s so the hero is never blank
      setTimeout(function () { if (!started) { started = true; run(body); } }, 1500);
    } else {
      run(body);
    }
  });
})();
