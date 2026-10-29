(function () {
  "use strict";

  var root = document.documentElement;
  var dict = window.FOLDGIT_I18N || { en: {}, zh: {} };
  var darkQuery = window.matchMedia("(prefers-color-scheme: dark)");
  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  function store(key, value) {
    try { localStorage.setItem(key, value); } catch (e) {}
  }
  function clamp(v, lo, hi) { return Math.min(hi, Math.max(lo, v)); }
  function easeInOut(t) { return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2; }

  // ---------------------------------------------------------------- language
  var i18nNodes = Array.prototype.slice.call(document.querySelectorAll("[data-i18n]"));
  i18nNodes.forEach(function (el) { el.__zh = el.innerHTML; });
  var metaDescription = document.querySelector('meta[name="description"]');

  function lang() { return root.dataset.lang === "en" ? "en" : "zh"; }

  function applyLanguage() {
    var l = lang();
    var table = dict[l] || {};
    i18nNodes.forEach(function (el) {
      var key = el.getAttribute("data-i18n");
      el.innerHTML = l === "zh" ? el.__zh : (table[key] || el.__zh);
    });
    root.lang = l === "zh" ? "zh-CN" : "en";
    labelThemeButton();
    if (table["meta.title"]) document.title = table["meta.title"];
    if (table["meta.description"] && metaDescription) metaDescription.setAttribute("content", table["meta.description"]);
    updateShot();
  }

  // Chinese for any zh-* browser language, English for everything else.
  function browserLang() {
    var list = navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language || ""];
    return String(list[0]).toLowerCase().indexOf("zh") === 0 ? "zh" : "en";
  }

  document.getElementById("lang-toggle").addEventListener("click", function () {
    root.dataset.lang = lang() === "zh" ? "en" : "zh";
    // Choosing the browser's own language again drops the override.
    store("foldgit.lang", root.dataset.lang === browserLang() ? "" : root.dataset.lang);
    applyLanguage();
  });

  // ---------------------------------------------------------------- appearance
  function scheme() {
    if (root.dataset.theme === "light" || root.dataset.theme === "dark") return root.dataset.theme;
    return darkQuery.matches ? "dark" : "light";
  }
  var appIcons = document.querySelectorAll("[data-app-icon]");
  var favicons = document.querySelectorAll('link[rel="icon"]');

  function applyScheme() {
    var dark = scheme() === "dark";
    root.dataset.scheme = dark ? "dark" : "light";
    root.dataset.mode = mode();
    labelThemeButton();
    Array.prototype.forEach.call(appIcons, function (img) { img.src = dark ? "assets/icon-dark.webp" : "assets/icon.webp"; });
    // The page toggle can differ from the system, so favicons follow the page rather than their media queries.
    Array.prototype.forEach.call(favicons, function (link) {
      link.removeAttribute("media");
      link.href = dark ? "assets/favicon-dark.png" : "assets/favicon.png";
    });
    updateShot();
  }
  // Auto follows the browser; light and dark are explicit choices.
  var modes = ["auto", "light", "dark"];
  var modeTitles = {
    zh: { auto: "外观：自动", light: "外观：浅色", dark: "外观：深色" },
    en: { auto: "Appearance: Automatic", light: "Appearance: Light", dark: "Appearance: Dark" }
  };
  var themeButton = document.getElementById("theme-toggle");

  function mode() { return root.dataset.theme === "light" || root.dataset.theme === "dark" ? root.dataset.theme : "auto"; }
  function labelThemeButton() {
    var title = modeTitles[lang()][mode()];
    themeButton.title = title;
    themeButton.setAttribute("aria-label", title);
  }

  themeButton.addEventListener("click", function () {
    var next = modes[(modes.indexOf(mode()) + 1) % modes.length];
    if (next === "auto") delete root.dataset.theme; else root.dataset.theme = next;
    root.dataset.mode = next;
    store("foldgit.theme", next === "auto" ? "" : next);
    applyScheme();
  });
  if (darkQuery.addEventListener) darkQuery.addEventListener("change", applyScheme);

  // ---------------------------------------------------------------- screenshot
  var shot = document.getElementById("main-shot");
  var currentShot = "";
  var screenshotScene = "main";
  var screenshotButtons = document.querySelectorAll("[data-screenshot]");
  screenshotButtons.forEach((button) => {
    button.addEventListener("click", () => {
      screenshotScene = button.dataset.screenshot;
      screenshotButtons.forEach((item) => item.setAttribute("aria-pressed", String(item === button)));
      updateShot();
    });
  });

  const updateShot = () => {
    if (!shot) return;
    var base = "assets/screenshots/" + screenshotScene + "-" + lang() + "-" + scheme();
    if (base === currentShot) return;
    var first = currentShot === "";
    currentShot = base;
    var next = new Image();
    next.srcset = base + ".webp?v=20261029-2 1x, " + base + "@2x.webp?v=20261029-2 2x";
    next.src = base + ".webp?v=20261029-2";
    var swap = () => {
      if (base !== currentShot) return;
      shot.srcset = next.srcset;
      shot.src = next.src;
      shot.alt = (dict[lang()] || {})["shot." + screenshotScene + ".alt"] || "";
      shot.classList.remove("is-swapping");
      shot.classList.add("is-loaded");
    };
    if (first) { swap(); return; }
    shot.classList.add("is-swapping");
    var ready = next.decode ? next.decode() : Promise.resolve();
    ready.catch(() => {}).then(() => { setTimeout(swap, 180); });
  };

  // ---------------------------------------------------------------- reveal
  var revealTargets = document.querySelectorAll("[data-reveal]");
  if ("IntersectionObserver" in window && !reduceMotion) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-in");
          io.unobserve(entry.target);
        }
      });
    }, { threshold: 0.14, rootMargin: "0px 0px -6% 0px" });
    revealTargets.forEach(function (el) { io.observe(el); });
  } else {
    revealTargets.forEach(function (el) { el.classList.add("is-in"); });
  }

  // ---------------------------------------------------------------- glass highlight
  document.addEventListener("pointermove", function (e) {
    var el = e.target.closest && e.target.closest(".glass");
    if (!el) return;
    var r = el.getBoundingClientRect();
    el.style.setProperty("--mx", (e.clientX - r.left) + "px");
    el.style.setProperty("--my", (e.clientY - r.top) + "px");
  }, { passive: true });

  // ---------------------------------------------------------------- fold story
  var foldSection = document.getElementById("fold");
  var foldStage = document.getElementById("fold-stage");
  var canvas = document.getElementById("fs-canvas");
  var steps = Array.prototype.slice.call(document.querySelectorAll("#fold-steps li"));
  var rows = {};
  if (canvas) Array.prototype.forEach.call(canvas.querySelectorAll(".fs-row"), function (el) { rows[el.dataset.id] = el; });
  var foldStep = -1;

  // Loose positions for the scattered state, as fractions of the free canvas area.
  var scatter = {
    aurora: [0.02, 0.0, -6], tide: [0.36, 0.13, 5], pebble: [0.06, 0.3, 3], harbor: [0.38, 0.45, -4],
    lumen: [0.0, 0.6, -3], kite: [0.33, 0.76, 6], moss: [0.08, 0.93, -5]
  };
  var indents = { aurora: 22, tide: 22, "tide-wt": 44, pebble: 22, harbor: 22, lumen: 22, kite: 22, moss: 22, infrequent: 22 };

  function set(el, s) {
    el.style.setProperty("--x", (s.x || 0) + "px");
    el.style.setProperty("--y", (s.y || 0) + "px");
    el.style.setProperty("--r", (s.r || 0) + "deg");
    el.style.setProperty("--s", s.s == null ? 1 : s.s);
    el.style.setProperty("--o", s.o == null ? 1 : s.o);
    el.style.setProperty("--fx", (s.fx || 0) + "deg");
    el.style.setProperty("--indent", (s.indent || 0) + "px");
    el.style.setProperty("--i", s.i || 0);
  }

  function layoutFold(step) {
    var W = canvas.clientWidth, H = canvas.clientHeight;
    var pitch = H < 380 ? 34 : 42;
    var order = ["studio", "aurora", "tide"];
    if (step >= 2) order.push("tide-wt");
    order.push("pebble", "oss", "harbor", "lumen");
    if (step >= 3) order.push("infrequent"); else order.push("kite", "moss");
    var y = {};
    order.forEach(function (id, n) { y[id] = n * pitch; });

    Object.keys(rows).forEach(function (id) {
      var el = rows[id];
      el.classList.toggle("is-selected", step >= 1 && id === "aurora");
      if (step === 0) {
        var p = scatter[id];
        if (p) {
          set(el, { x: p[0] * W, y: p[1] * (H - 52), r: p[2], i: Object.keys(scatter).indexOf(id) });
        } else {
          set(el, { y: 0, o: 0, s: 0.92, fx: -70 });
        }
        return;
      }
      if (id in y) {
        set(el, { y: y[id], indent: indents[id] || 0, i: order.indexOf(id) });
      } else if (id === "tide-wt") {
        set(el, { y: y.tide, indent: 44, o: 0, fx: -90, s: 0.98 });
      } else if (id === "infrequent") {
        set(el, { y: y.lumen + pitch, indent: 22, o: 0, fx: -90 });
      } else {
        // Infrequent repositories fold up into the disclosure row.
        set(el, { y: y.infrequent, indent: 22, o: 0, fx: 80, s: 0.96, i: 2 });
      }
    });
  }

  function setFoldStep(step) {
    if (!foldStage || step === foldStep) return;
    foldStep = step;
    foldStage.dataset.step = String(step);
    steps.forEach(function (li, n) { li.classList.toggle("is-active", n === step); });
    layoutFold(step);
  }

  // ---------------------------------------------------------------- scroll loop
  var shotFrame = document.getElementById("shot-frame");
  var nav = document.querySelector(".nav");
  var smoothY = window.scrollY;
  var ticking = false;

  function frame() {
    var target = window.scrollY;
    // Critically damped follow gives the scroll-linked motion a soft, non-linear feel.
    smoothY += (target - smoothY) * (reduceMotion ? 1 : 0.14);
    if (Math.abs(target - smoothY) < 0.3) smoothY = target;

    var vh = window.innerHeight;
    var max = Math.max(1, document.documentElement.scrollHeight - vh);
    root.style.setProperty("--scroll", (smoothY / max).toFixed(4));

    if (shotFrame) {
      var p = easeInOut(clamp(smoothY / (vh * 0.75), 0, 1));
      shotFrame.style.setProperty("--shot-tilt", (24 * (1 - p)).toFixed(2) + "deg");
      shotFrame.style.setProperty("--shot-scale", (0.9 + 0.1 * p).toFixed(4));
      shotFrame.style.setProperty("--shot-y", (-30 * p).toFixed(1) + "px");
    }
    nav.classList.toggle("is-compact", target > 40);

    if (foldSection) {
      var rect = foldSection.getBoundingClientRect();
      var fp = clamp(-rect.top / Math.max(1, rect.height - vh), 0, 1);
      steps[0].parentNode.style.setProperty("--fold-progress", fp.toFixed(4));
      setFoldStep(fp < 0.2 ? 0 : fp < 0.46 ? 1 : fp < 0.72 ? 2 : 3);
    }

    if (smoothY !== target) {
      requestAnimationFrame(frame);
    } else {
      ticking = false;
    }
  }
  function kick() {
    if (!ticking) { ticking = true; requestAnimationFrame(frame); }
  }
  window.addEventListener("scroll", kick, { passive: true });
  window.addEventListener("resize", function () { var s = foldStep; foldStep = -1; setFoldStep(s < 0 ? 0 : s); kick(); });

  // ---------------------------------------------------------------- manual contents
  var tocLinks = Array.prototype.slice.call(document.querySelectorAll(".toc a"));
  if (tocLinks.length && "IntersectionObserver" in window) {
    var spy = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        tocLinks.forEach(function (link) { link.classList.toggle("is-current", link.hash === "#" + entry.target.id); });
      });
    }, { rootMargin: "-30% 0px -60% 0px" });
    document.querySelectorAll(".m-section").forEach(function (section) { spy.observe(section); });
  }

  // ---------------------------------------------------------------- start
  applyScheme();
  applyLanguage();
  setFoldStep(0);
  kick();
  // Hero copy reveals on load rather than waiting for the observer.
  requestAnimationFrame(function () {
    document.querySelectorAll(".hero [data-reveal]").forEach(function (el) { el.classList.add("is-in"); });
  });
})();
