(function () {
  "use strict";

  var root = document.documentElement;
  var dict = window.FOLDGIT_I18N || { en: {}, zh: {} };
  var darkQuery = window.matchMedia("(prefers-color-scheme: dark)");
  const motionQuery = window.matchMedia("(prefers-reduced-motion: reduce)");
  var reduceMotion = motionQuery.matches;

  function store(key, value) {
    try { localStorage.setItem(key, value); } catch (e) {}
  }
  function clamp(v, lo, hi) { return Math.min(hi, Math.max(lo, v)); }
  function easeInOut(t) { return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2; }
  const setStyle = (element, name, value) => {
    if (element.style.getPropertyValue(name) !== value) element.style.setProperty(name, value);
  };

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
    scheduleMeasure();
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

  const updateShot = () => {
    if (!shot) return;
    var base = "assets/screenshots/main-" + lang() + "-" + scheme();
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
      shot.alt = dict[lang()]["shot.main.alt"];
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
  const hoverQuery = window.matchMedia("(hover: hover) and (pointer: fine)");
  let highlightFrame = 0;
  let pointer = null;
  const updateHighlight = () => {
    highlightFrame = 0;
    if (!pointer || reduceMotion || document.hidden || !hoverQuery.matches) return;
    const { element, x, y } = pointer;
    const rect = element.getBoundingClientRect();
    setStyle(element, "--mx", Math.round(x - rect.left) + "px");
    setStyle(element, "--my", Math.round(y - rect.top) + "px");
  };
  document.addEventListener("pointermove", (event) => {
    if (reduceMotion || !hoverQuery.matches || document.hidden) return;
    const element = event.target.closest && event.target.closest(".glass");
    pointer = element ? { element, x: event.clientX, y: event.clientY } : null;
    if (pointer && !highlightFrame) highlightFrame = requestAnimationFrame(updateHighlight);
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
    foldgit: [0.02, 0.0, -6], tide: [0.36, 0.13, 5], pebble: [0.06, 0.3, 3], harbor: [0.38, 0.45, -4],
    lumen: [0.0, 0.6, -3], kite: [0.33, 0.76, 6], moss: [0.08, 0.93, -5]
  };
  var indents = { foldgit: 22, tide: 22, "foldgit-wt": 44, pebble: 22, harbor: 22, lumen: 22, kite: 22, moss: 22, infrequent: 22 };

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
    var order = ["studio", "foldgit"];
    if (step >= 2) order.push("foldgit-wt");
    order.push("tide", "pebble", "oss", "harbor", "lumen");
    if (step >= 3) order.push("infrequent"); else order.push("kite", "moss");
    var y = {};
    order.forEach(function (id, n) { y[id] = n * pitch; });

    Object.keys(rows).forEach(function (id) {
      var el = rows[id];
      el.classList.toggle("is-selected", step >= 1 && id === "foldgit");
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
      } else if (id === "foldgit-wt") {
        set(el, { y: y.foldgit, indent: 44, o: 0, fx: -90, s: 0.98 });
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

  // ---------------------------------------------------------------- scroll-linked scenes
  const shotFrame = document.getElementById("shot-frame");
  const shotWindow = shotFrame && shotFrame.querySelector(".shot-window");
  const shotStage = document.getElementById("stage");
  const shotSticky = document.getElementById("stage-sticky");
  const bands = document.querySelector(".bands");
  const nav = document.querySelector(".nav");
  const desktopQuery = window.matchMedia("(min-width: 861px)");
  let geometry = null;
  let measureFrame = 0;
  let animationFrame = 0;
  let smoothY = window.scrollY;
  let stageWasVisible = false;
  let foldLayoutDirty = true;

  // Read layout only after size or content changes, before any per-frame writes.
  const measureGeometry = () => {
    measureFrame = 0;
    const contentHeight = shotSticky ? shotSticky.offsetHeight : 0;
    if (shotStage && shotStage.style.getPropertyValue("--stage-content-height") !== contentHeight + "px") {
      setStyle(shotStage, "--stage-content-height", contentHeight + "px");
      scheduleMeasure();
      return;
    }
    const scrollY = window.scrollY;
    const viewportHeight = window.innerHeight;
    const stageRect = shotStage && shotStage.getBoundingClientRect();
    const foldRect = foldSection && foldSection.getBoundingClientRect();
    geometry = {
      viewportHeight,
      maxScroll: Math.max(1, document.documentElement.scrollHeight - viewportHeight),
      stageTop: stageRect ? stageRect.top + scrollY : 0,
      stageHeight: stageRect ? stageRect.height : 0,
      stageDistance: stageRect ? Math.max(1, stageRect.height - contentHeight) : 1,
      stickyTop: shotSticky ? parseFloat(getComputedStyle(shotSticky).top) || 0 : 0,
      shotHeight: shotFrame ? shotFrame.clientHeight : 0,
      foldTop: foldRect ? foldRect.top + scrollY : 0,
      foldHeight: foldRect ? foldRect.height : 0,
      foldDistance: foldRect ? Math.max(1, foldRect.height - viewportHeight) : 1
    };
    foldLayoutDirty = true;
    kick();
  };
  const scheduleMeasure = () => {
    if (!measureFrame && !document.hidden) measureFrame = requestAnimationFrame(measureGeometry);
  };

  const frame = () => {
    animationFrame = 0;
    if (!geometry || document.hidden) return;
    const target = window.scrollY;
    const stageVisible = shotWindow && target + geometry.viewportHeight > geometry.stageTop
      && target < geometry.stageTop + geometry.stageHeight;
    // Only the visible screenshot follows softly; other sections settle in one frame.
    if (stageVisible && stageWasVisible && !reduceMotion) smoothY += (target - smoothY) * 0.22;
    else smoothY = target;
    if (Math.abs(target - smoothY) < 0.3) smoothY = target;

    if (bands) {
      const parallax = !reduceMotion && desktopQuery.matches;
      const offset = -60 * target / geometry.maxScroll;
      setStyle(bands, "transform", parallax ? "translate3d(0, " + offset.toFixed(2) + "px, 0)" : "none");
    }
    if (shotWindow) {
      const progress = clamp((smoothY + geometry.stickyTop - geometry.stageTop) / geometry.stageDistance, 0, 1);
      shotFrame.classList.toggle("is-animating", !!stageVisible && !reduceMotion && progress > 0.12 && progress < 0.8);
      if (reduceMotion) {
        setStyle(shotWindow, "opacity", "1");
        setStyle(shotWindow, "transform", "none");
      } else if (stageVisible) {
        // Hold the wallpaper before the window rises and unfolds into place.
        const unfold = easeInOut(clamp((progress - 0.12) / 0.68, 0, 1));
        setStyle(shotWindow, "opacity", clamp((progress - 0.12) / 0.18, 0, 1).toFixed(4));
        setStyle(shotWindow, "transform", "translate3d(0, " + ((1 - unfold) * geometry.shotHeight * 0.38).toFixed(2)
          + "px, " + (-180 * (1 - unfold)).toFixed(2) + "px) rotateX(" + (62 * (1 - unfold)).toFixed(2)
          + "deg) scale(" + (0.86 + 0.14 * unfold).toFixed(4) + ")");
      }
    }
    stageWasVisible = stageVisible;
    if (nav) nav.classList.toggle("is-compact", target > 40);

    if (foldSection && target + geometry.viewportHeight > geometry.foldTop && target < geometry.foldTop + geometry.foldHeight) {
      const progress = clamp((target - geometry.foldTop) / geometry.foldDistance, 0, 1);
      setStyle(steps[0].parentNode, "--fold-progress", progress.toFixed(4));
      const step = Math.min(steps.length - 1, Math.floor(progress * steps.length));
      if (foldLayoutDirty) foldStep = -1;
      setFoldStep(step);
      foldLayoutDirty = false;
    }

    if (smoothY !== target) kick();
  };
  const kick = () => {
    if (!animationFrame && !document.hidden) animationFrame = requestAnimationFrame(frame);
  };
  window.addEventListener("scroll", kick, { passive: true });
  window.addEventListener("resize", scheduleMeasure, { passive: true });
  desktopQuery.addEventListener("change", kick);
  motionQuery.addEventListener("change", () => {
    reduceMotion = motionQuery.matches;
    if (reduceMotion) revealTargets.forEach((element) => element.classList.add("is-in"));
    scheduleMeasure();
  });
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) {
      cancelAnimationFrame(animationFrame);
      cancelAnimationFrame(measureFrame);
      cancelAnimationFrame(highlightFrame);
      animationFrame = measureFrame = highlightFrame = 0;
      pointer = null;
      if (shotFrame) shotFrame.classList.remove("is-animating");
    } else {
      smoothY = window.scrollY;
      stageWasVisible = false;
      scheduleMeasure();
    }
  });
  if ("ResizeObserver" in window) {
    const resizeObserver = new ResizeObserver(scheduleMeasure);
    resizeObserver.observe(document.body);
    if (shotSticky) resizeObserver.observe(shotSticky);
  }
  if (shot) shot.addEventListener("load", scheduleMeasure);
  if (document.fonts) document.fonts.ready.then(scheduleMeasure);

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
  scheduleMeasure();
  // Hero copy reveals on load rather than waiting for the observer.
  requestAnimationFrame(function () {
    document.querySelectorAll(".hero [data-reveal]").forEach(function (el) { el.classList.add("is-in"); });
  });
})();
