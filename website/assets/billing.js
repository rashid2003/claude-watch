/* Pricing + checkout against the Session Watch billing worker.
   API: billing/README.md in the repo. Falls back to static prices when offline. */
(function () {
  "use strict";
  var API = (window.SW_CONFIG && window.SW_CONFIG.BILLING_API) || "https://billing.sessionwatch.lajward.co";

  var FALLBACK = {
    pro_monthly: { amountCents: 499, displayPrice: "$4.99", per: "/month" },
    pro_yearly:  { amountCents: 3900, displayPrice: "$39", per: "/year" },
    lifetime:    { amountCents: 9900, displayPrice: "$99", per: " once" }
  };
  var state = { plans: FALLBACK, code: null, codeInfo: null };

  function $(id) { return document.getElementById(id); }
  function money(cents) {
    return (cents % 100 === 0) ? "$" + (cents / 100) : "$" + (cents / 100).toFixed(2);
  }

  function renderPrices() {
    Object.keys(state.plans).forEach(function (id) {
      var elAmount = document.querySelector('[data-price="' + id + '"]');
      if (!elAmount) return;
      var p = state.plans[id];
      var base = p.amountCents;
      var final_ = base;
      if (state.codeInfo && state.codeInfo.valid && state.codeInfo.plan === id) {
        final_ = state.codeInfo.finalPrice;
      }
      var html = "";
      if (final_ !== base) html += '<span class="strike">' + money(base) + "</span>";
      html += money(final_) + "<small>" + (p.per || "") + "</small>";
      elAmount.innerHTML = html;
    });
  }

  function loadPlans() {
    fetch(API + "/v1/plans").then(function (r) { return r.json(); }).then(function (data) {
      if (!data.plans) return;
      data.plans.forEach(function (p) {
        var per = p.interval === "month" ? "/month" : p.interval === "year" ? "/year" : " once";
        state.plans[p.id] = { amountCents: p.amountCents, per: per };
      });
      renderPrices();
    }).catch(function () { /* static prices stay */ });
  }

  function setMsg(text, ok) {
    var m = $("code-msg");
    if (!m) return;
    m.textContent = text || "";
    m.className = "code-msg " + (text ? (ok ? "ok" : "err") : "");
  }

  function applyCode() {
    var input = $("code-input");
    var code = (input.value || "").trim();
    if (!code) { state.code = null; state.codeInfo = null; setMsg(""); renderPrices(); return; }
    // validate against the most expensive plan the code allows; try each plan and keep the first valid answer per plan
    var planIds = Object.keys(state.plans);
    setMsg("checking…", true);
    Promise.all(planIds.map(function (plan) {
      return fetch(API + "/v1/codes/validate", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code: code, plan: plan })
      }).then(function (r) { return r.json(); }).then(function (res) { return { plan: plan, res: res }; })
        .catch(function () { return { plan: plan, res: null }; });
    })).then(function (results) {
      var valid = results.filter(function (x) { return x.res && x.res.valid; });
      if (valid.length === 0) {
        var reason = (results[0].res && results[0].res.reason) || "that code didn't work";
        state.code = null; state.codeInfo = null;
        setMsg(reason, false); renderPrices();
        return;
      }
      state.code = code;
      // store per-plan final prices
      state.codeInfo = { valid: true, perPlan: {} };
      valid.forEach(function (x) { state.codeInfo.perPlan[x.plan] = x.res.finalPrice; });
      var off = valid[0].res.percentOff ? valid[0].res.percentOff + "% off" : money(valid[0].res.amountOff) + " off";
      setMsg("✓ " + code.toUpperCase() + " applied — " + off, true);
      renderDiscounted();
    });
  }

  function renderDiscounted() {
    Object.keys(state.plans).forEach(function (id) {
      var elAmount = document.querySelector('[data-price="' + id + '"]');
      if (!elAmount) return;
      var p = state.plans[id];
      var html = "";
      if (state.codeInfo && state.codeInfo.perPlan && state.codeInfo.perPlan[id] != null
          && state.codeInfo.perPlan[id] !== p.amountCents) {
        html += '<span class="strike">' + money(p.amountCents) + "</span>";
        html += money(state.codeInfo.perPlan[id]) + "<small>" + (p.per || "") + "</small>";
      } else {
        html += money(p.amountCents) + "<small>" + (p.per || "") + "</small>";
      }
      elAmount.innerHTML = html;
    });
  }

  function checkout(plan, btn) {
    var email = ($("email-input") && $("email-input").value.trim()) || undefined;
    var old = btn.textContent;
    btn.disabled = true; btn.textContent = "opening checkout…";
    fetch(API + "/v1/checkout", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ plan: plan, code: state.code || undefined, email: email })
    }).then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
      .then(function (x) {
        if (x.ok && x.j.url) { window.location.href = x.j.url; return; }
        setMsg(x.j.error || "checkout didn't open — try again", false);
        btn.disabled = false; btn.textContent = old;
      }).catch(function () {
        setMsg("couldn't reach the billing service — try again in a minute", false);
        btn.disabled = false; btn.textContent = old;
      });
  }

  document.addEventListener("DOMContentLoaded", function () {
    renderPrices();
    loadPlans();
    var applyBtn = $("code-apply");
    if (applyBtn) applyBtn.addEventListener("click", applyCode);
    var input = $("code-input");
    if (input) input.addEventListener("keydown", function (e) { if (e.key === "Enter") { e.preventDefault(); applyCode(); } });
    document.querySelectorAll("[data-checkout]").forEach(function (btn) {
      btn.addEventListener("click", function () { checkout(btn.getAttribute("data-checkout"), btn); });
    });
  });
})();
