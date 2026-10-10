/* Buddy — the Session Watch mascot, rebuilt in SVG from the app's Canvas shapes
   (Sources/WatchProtocol/BuddyArt.swift). Three characters, five moods. */
(function () {
  "use strict";

  var MOODS = {
    sleeping:    { accent: "#7399F2", label: "sleeping" },
    busy:        { accent: "#33C79E", label: "busy" },
    needsyou:    { accent: "#FF9E1A", label: "needs you" },
    celebrating: { accent: "#9E66F2", label: "celebrating" },
    error:       { accent: "#ED424D", label: "error" }
  };
  var INK = "#211F33";

  function el(tag, attrs, children) {
    var n = document.createElementNS("http://www.w3.org/2000/svg", tag);
    for (var k in attrs) n.setAttribute(k, attrs[k]);
    (children || []).forEach(function (c) { n.appendChild(c); });
    return n;
  }

  /* ---- character bodies (100×100 box, feet around y=86) ---- */

  function blobbyBody() {
    var g = el("g", { class: "b-body" });
    g.appendChild(el("path", {
      d: "M50 18 C72 18 84 36 84 56 C84 76 70 86 50 86 C30 86 16 76 16 56 C16 36 28 18 50 18 Z",
      fill: "url(#blobbyGrad)"
    }));
    // gloss highlight
    g.appendChild(el("ellipse", { cx: 38, cy: 32, rx: 10, ry: 6, fill: "rgba(255,255,255,0.45)", transform: "rotate(-18 38 32)" }));
    // feet
    g.appendChild(el("ellipse", { cx: 38, cy: 87, rx: 8, ry: 5, fill: "#40A88F" }));
    g.appendChild(el("ellipse", { cx: 62, cy: 87, rx: 8, ry: 5, fill: "#40A88F" }));
    // arms
    g.appendChild(el("ellipse", { class: "b-arm b-arm-l", cx: 17, cy: 58, rx: 6, ry: 9, fill: "#52BD9F" }));
    g.appendChild(el("ellipse", { class: "b-arm b-arm-r", cx: 83, cy: 58, rx: 6, ry: 9, fill: "#52BD9F" }));
    // cheeks
    g.appendChild(el("ellipse", { class: "b-cheek", cx: 33, cy: 57, rx: 5, ry: 3, fill: "rgba(255,150,170,0.55)" }));
    g.appendChild(el("ellipse", { class: "b-cheek", cx: 67, cy: 57, rx: 5, ry: 3, fill: "rgba(255,150,170,0.55)" }));
    return g;
  }

  function boltBody() {
    var g = el("g", { class: "b-body" });
    // body
    g.appendChild(el("rect", { x: 30, y: 56, width: 40, height: 30, rx: 10, fill: "url(#boltGrad)", stroke: "#808FB8", "stroke-width": 1.5 }));
    // head
    g.appendChild(el("rect", { x: 24, y: 18, width: 52, height: 42, rx: 17, fill: "url(#boltGrad)", stroke: "#808FB8", "stroke-width": 1.5 }));
    // screen face
    g.appendChild(el("rect", { x: 31, y: 25, width: 38, height: 28, rx: 10, fill: "#1A213D" }));
    // antenna
    g.appendChild(el("line", { x1: 50, y1: 18, x2: 50, y2: 10, stroke: "#808FB8", "stroke-width": 2 }));
    g.appendChild(el("circle", { class: "b-glow", cx: 50, cy: 8, r: 3.4, fill: "#33C79E" }));
    // feet
    g.appendChild(el("rect", { x: 33, y: 85, width: 12, height: 5, rx: 2.5, fill: "#808FB8" }));
    g.appendChild(el("rect", { x: 55, y: 85, width: 12, height: 5, rx: 2.5, fill: "#808FB8" }));
    // arms
    g.appendChild(el("rect", { class: "b-arm b-arm-l", x: 21, y: 58, width: 7, height: 16, rx: 3.5, fill: "#B9C5E3" }));
    g.appendChild(el("rect", { class: "b-arm b-arm-r", x: 72, y: 58, width: 7, height: 16, rx: 3.5, fill: "#B9C5E3" }));
    return g;
  }

  function pixelBody() {
    var g = el("g", { class: "b-body", "shape-rendering": "crispEdges" });
    var P = 5, ox = 15, oy = 24;           // 14×13 grid of 5px cells
    var B = "#FF8C9E", S = "#DB5C80", F = "#331433";
    var rows = [
      "..1..........1",
      ".11..........11",
      ".111........111",
      "..111111111111",
      ".1111111111111.",
      "11111111111111",
      "11133111133111",
      "11133111133111",
      "11111111111111",
      "11112222221111",
      ".111111111111.",
      "..11........11",
      "..22........22"
    ];
    rows.forEach(function (row, y) {
      for (var x = 0; x < row.length; x++) {
        var c = row[x];
        if (c === ".") continue;
        var fill = c === "1" ? B : c === "2" ? S : F;
        g.appendChild(el("rect", { x: ox + x * P, y: oy + y * P, width: P, height: P, fill: fill }));
      }
    });
    return g;
  }

  /* ---- faces (shared layer, toggled per mood) ---- */

  function faces(charName) {
    var g = el("g", { class: "b-face" });
    var eyeY = charName === "bolt" ? 38 : 48;
    var lx = charName === "bolt" ? 41 : 39, rx = charName === "bolt" ? 59 : 61;
    var eyeFill = charName === "bolt" ? "#33C79E" : INK;

    // normal eyes (busy / needs you)
    var open = el("g", { class: "f f-open" });
    open.appendChild(el("circle", { cx: lx, cy: eyeY, r: 4.4, fill: eyeFill }));
    open.appendChild(el("circle", { cx: rx, cy: eyeY, r: 4.4, fill: eyeFill }));
    if (charName !== "bolt") {
      open.appendChild(el("circle", { cx: lx + 1.4, cy: eyeY - 1.4, r: 1.4, fill: "#fff" }));
      open.appendChild(el("circle", { cx: rx + 1.4, cy: eyeY - 1.4, r: 1.4, fill: "#fff" }));
    }
    g.appendChild(open);

    // closed eyes (sleeping)
    var closed = el("g", { class: "f f-closed", stroke: eyeFill, "stroke-width": 2.2, "stroke-linecap": "round", fill: "none" });
    closed.appendChild(el("path", { d: "M" + (lx - 4) + " " + eyeY + " Q " + lx + " " + (eyeY + 3) + " " + (lx + 4) + " " + eyeY }));
    closed.appendChild(el("path", { d: "M" + (rx - 4) + " " + eyeY + " Q " + rx + " " + (eyeY + 3) + " " + (rx + 4) + " " + eyeY }));
    g.appendChild(closed);

    // happy ^^ eyes (celebrating)
    var happy = el("g", { class: "f f-happy", stroke: eyeFill, "stroke-width": 2.2, "stroke-linecap": "round", fill: "none" });
    happy.appendChild(el("path", { d: "M" + (lx - 4) + " " + (eyeY + 1) + " Q " + lx + " " + (eyeY - 4) + " " + (lx + 4) + " " + (eyeY + 1) }));
    happy.appendChild(el("path", { d: "M" + (rx - 4) + " " + (eyeY + 1) + " Q " + rx + " " + (eyeY - 4) + " " + (rx + 4) + " " + (eyeY + 1) }));
    g.appendChild(happy);

    // X eyes (error)
    var xg = el("g", { class: "f f-x", stroke: eyeFill, "stroke-width": 2.2, "stroke-linecap": "round" });
    [[lx, eyeY], [rx, eyeY]].forEach(function (p) {
      xg.appendChild(el("line", { x1: p[0] - 3.4, y1: p[1] - 3.4, x2: p[0] + 3.4, y2: p[1] + 3.4 }));
      xg.appendChild(el("line", { x1: p[0] + 3.4, y1: p[1] - 3.4, x2: p[0] - 3.4, y2: p[1] + 3.4 }));
    });
    g.appendChild(xg);

    var mouthY = charName === "bolt" ? 46 : 60;
    // small smile (busy / sleeping)
    g.appendChild(el("path", { class: "f f-smile", d: "M45 " + mouthY + " Q 50 " + (mouthY + 4) + " 55 " + mouthY,
      stroke: eyeFill, "stroke-width": 2.2, "stroke-linecap": "round", fill: "none" }));
    // open mouth (needs you / celebrating)
    g.appendChild(el("ellipse", { class: "f f-o", cx: 50, cy: mouthY + 1, rx: 4.6, ry: 5.4, fill: charName === "bolt" ? "#33C79E" : INK }));
    // frown (error)
    g.appendChild(el("path", { class: "f f-frown", d: "M45 " + (mouthY + 3) + " Q 50 " + (mouthY - 2) + " 55 " + (mouthY + 3),
      stroke: eyeFill, "stroke-width": 2.2, "stroke-linecap": "round", fill: "none" }));
    return g;
  }

  /* ---- mood props ---- */

  function props() {
    var g = el("g", { class: "b-props" });

    // sleeping z z z
    var z = el("g", { class: "p p-z", fill: "#7399F2", "font-family": "inherit", "font-weight": "800" });
    [[70, 26, 10], [78, 18, 13], [87, 9, 16]].forEach(function (s, i) {
      var t = el("text", { x: s[0], y: s[1], "font-size": s[2], class: "zz zz" + i });
      t.textContent = "z";
      z.appendChild(t);
    });
    g.appendChild(z);

    // needs-you badge
    var ny = el("g", { class: "p p-bang" });
    ny.appendChild(el("circle", { cx: 79, cy: 16, r: 10, fill: "#FF9E1A" }));
    var bang = el("text", { x: 79, y: 21, "text-anchor": "middle", "font-size": 14, "font-weight": 800, fill: "#fff" });
    bang.textContent = "!";
    ny.appendChild(bang);
    g.appendChild(ny);

    // error sweat drop
    var sweat = el("path", { class: "p p-sweat", d: "M76 30 C76 30 82 38 82 42 A6 6 0 1 1 70 42 C70 38 76 30 76 30 Z", fill: "#66B3FF" });
    g.appendChild(sweat);

    // confetti
    var confetti = el("g", { class: "p p-confetti" });
    var colors = ["#FF8DA1", "#FFD166", "#5BD4E0", "#FF9E1A", "#9E66F2", "#6BDBB8"];
    for (var i = 0; i < 12; i++) {
      var cx = 14 + (i * 73) % 72, cy = 6 + (i * 29) % 26;
      var r = el("rect", { x: cx, y: cy, width: 4, height: 4, rx: 1, fill: colors[i % 6], class: "cf cf" + (i % 4) });
      confetti.appendChild(r);
    }
    g.appendChild(confetti);

    // busy dust
    var dust = el("g", { class: "p p-dust", fill: "rgba(200,200,200,0.4)" });
    dust.appendChild(el("circle", { class: "du du0", cx: 24, cy: 88, r: 3 }));
    dust.appendChild(el("circle", { class: "du du1", cx: 76, cy: 90, r: 2.4 }));
    g.appendChild(dust);
    return g;
  }

  function defs() {
    var d = el("defs", {});
    var g1 = el("linearGradient", { id: "blobbyGrad", x1: 0, y1: 0, x2: 0, y2: 1 });
    g1.appendChild(el("stop", { offset: "0%", "stop-color": "#6BDBB8" }));
    g1.appendChild(el("stop", { offset: "100%", "stop-color": "#40A88F" }));
    d.appendChild(g1);
    var g2 = el("linearGradient", { id: "boltGrad", x1: 0, y1: 0, x2: 0, y2: 1 });
    g2.appendChild(el("stop", { offset: "0%", "stop-color": "#FFFFFF" }));
    g2.appendChild(el("stop", { offset: "100%", "stop-color": "#D1DBF2" }));
    d.appendChild(g2);
    return d;
  }

  function build(charName) {
    var svg = el("svg", { viewBox: "0 0 100 100", role: "img", "aria-label": "buddy, the session watch mascot, " + charName });
    svg.appendChild(defs());
    svg.appendChild(el("ellipse", { class: "b-shadow", cx: 50, cy: 93, rx: 24, ry: 4, fill: "rgba(0,0,0,0.3)" }));
    var mover = el("g", { class: "b-move" });
    mover.appendChild(charName === "bolt" ? boltBody() : charName === "pixel" ? pixelBody() : blobbyBody());
    mover.appendChild(faces(charName));
    svg.appendChild(mover);
    svg.appendChild(props());
    return svg;
  }

  window.Buddy = {
    MOODS: MOODS,
    mount: function (host, charName, mood) {
      host.textContent = "";
      var svg = build(charName);
      svg.classList.add("buddy-canvas");
      host.appendChild(svg);
      this.setMood(host, mood || "busy");
      return svg;
    },
    setMood: function (host, mood) {
      var svg = host.querySelector("svg");
      if (!svg) return;
      Object.keys(MOODS).forEach(function (m) { svg.classList.remove("m-" + m); });
      svg.classList.add("m-" + mood);
    }
  };

  /* mood styling + animation, injected once */
  var css = [
    ".buddy-canvas text{font-family:inherit}",
    ".buddy-canvas .f,.buddy-canvas .p{visibility:hidden}",
    /* face per mood */
    ".m-busy .f-open,.m-busy .f-smile{visibility:visible}",
    ".m-needsyou .f-open,.m-needsyou .f-o,.m-needsyou .p-bang{visibility:visible}",
    ".m-sleeping .f-closed,.m-sleeping .f-smile,.m-sleeping .p-z{visibility:visible}",
    ".m-celebrating .f-happy,.m-celebrating .f-o,.m-celebrating .p-confetti{visibility:visible}",
    ".m-error .f-x,.m-error .f-frown,.m-error .p-sweat{visibility:visible}",
    ".m-busy .p-dust{visibility:visible}",
    /* motion */
    ".b-move{transform-origin:50px 86px}",
    ".m-busy .b-move{animation:bd-bounce 0.7s ease-in-out infinite}",
    ".m-sleeping .b-move{animation:bd-breathe 2.6s ease-in-out infinite}",
    ".m-needsyou .b-move{animation:bd-jump 0.8s ease-in-out infinite}",
    ".m-celebrating .b-move{animation:bd-cheer 0.6s ease-in-out infinite}",
    ".m-error .b-move{animation:bd-shake 0.5s linear infinite}",
    ".m-needsyou .p-bang{animation:bd-pulse 0.8s ease-in-out infinite;transform-origin:79px 16px}",
    ".m-celebrating .b-arm-l{animation:bd-armup 0.6s ease-in-out infinite;transform-origin:20px 58px}",
    ".m-celebrating .b-arm-r{animation:bd-armup 0.6s ease-in-out infinite reverse;transform-origin:80px 58px}",
    ".zz0{animation:bd-zfloat 2.4s ease-in-out infinite}",
    ".zz1{animation:bd-zfloat 2.4s ease-in-out 0.4s infinite}",
    ".zz2{animation:bd-zfloat 2.4s ease-in-out 0.8s infinite}",
    ".cf0{animation:bd-fall 1.4s linear infinite}",
    ".cf1{animation:bd-fall 1.7s linear 0.3s infinite}",
    ".cf2{animation:bd-fall 1.2s linear 0.6s infinite}",
    ".cf3{animation:bd-fall 1.9s linear 0.1s infinite}",
    ".du0{animation:bd-puff 0.7s ease-out infinite}",
    ".du1{animation:bd-puff 0.7s ease-out 0.35s infinite}",
    "@keyframes bd-bounce{0%,100%{transform:translateY(0) scaleY(1)}50%{transform:translateY(-7px) scaleY(1.03)}}",
    "@keyframes bd-breathe{0%,100%{transform:scaleY(1)}50%{transform:scaleY(0.95) scaleX(1.03)}}",
    "@keyframes bd-jump{0%,100%{transform:translateY(0)}40%{transform:translateY(-14px)}60%{transform:translateY(-12px)}}",
    "@keyframes bd-cheer{0%,100%{transform:translateY(0) rotate(-2deg)}50%{transform:translateY(-9px) rotate(2deg)}}",
    "@keyframes bd-shake{0%,100%{transform:translateX(0)}25%{transform:translateX(-3px)}75%{transform:translateX(3px)}}",
    "@keyframes bd-pulse{0%,100%{transform:scale(1)}50%{transform:scale(1.18)}}",
    "@keyframes bd-zfloat{0%{opacity:0;transform:translateY(4px)}30%{opacity:1}100%{opacity:0;transform:translateY(-8px)}}",
    "@keyframes bd-fall{0%{opacity:1;transform:translateY(-6px) rotate(0)}100%{opacity:0;transform:translateY(40px) rotate(180deg)}}",
    "@keyframes bd-puff{0%{opacity:0.6;transform:scale(0.6)}100%{opacity:0;transform:scale(1.5)}}",
    "@media (prefers-reduced-motion: reduce){.b-move,.p-bang,.zz,.cf,.du,.b-arm{animation:none !important}}"
  ].join("\n");
  var style = document.createElement("style");
  style.textContent = css;
  document.head.appendChild(style);
})();
