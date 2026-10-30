// 用无头 Chromium 逐帧渲染 scene.html，经 CDP 截图后直接送入 ffmpeg。
// node render.mjs --lang zh --ratio 16x9 --out video.mp4 [--fps 30] [--dur 秒，默认取 scene.html 的 DURATION]
// node render.mjs --lang zh --ratio 16x9 --stills 0.5,4,9 --outdir dir
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync, readdirSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, v, i, a) => (v.startsWith("--") ? [...acc, [v.slice(2), a[i + 1]]] : acc), []));
const lang = args.lang || "zh";
const ratio = args.ratio || "16x9";
const fps = Number(args.fps || 30);
const [W, H] = ratio === "9x16" ? [1080, 1920] : [1920, 1080];
const here = dirname(fileURLToPath(import.meta.url));

function findBrowser() {
  if (process.env.CHROME) return process.env.CHROME;
  const base = join(homedir(), "Library/Caches/ms-playwright");
  const dirs = readdirSync(base).filter((d) => d.startsWith("chromium_headless_shell-")).sort().reverse();
  for (const d of dirs) {
    for (const sub of readdirSync(join(base, d))) {
      const p = join(base, d, sub, "chrome-headless-shell");
      if (existsSync(p)) return p;
    }
  }
  throw new Error("chrome-headless-shell not found; set CHROME");
}

const port = 9300 + Math.floor(Math.random() * 500);
const chrome = spawn(findBrowser(), [
  `--remote-debugging-port=${port}`, "--hide-scrollbars", "--allow-file-access-from-files",
  "--force-color-profile=srgb", "--font-render-hinting=none", `--window-size=${W},${H}`, "about:blank",
], { stdio: ["ignore", "ignore", "pipe"] });

async function pageWs() {
  for (let i = 0; i < 100; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      const page = list.find((x) => x.type === "page");
      if (page) return page.webSocketDebuggerUrl;
    } catch {}
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error("browser did not start");
}

const ws = new WebSocket(await pageWs());
await new Promise((r) => ws.addEventListener("open", r, { once: true }));
let seq = 0;
const pending = new Map();
const events = [];
ws.addEventListener("message", (m) => {
  const msg = JSON.parse(m.data);
  if (msg.id && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
  } else if (msg.method) events.push(msg.method);
});
const send = (method, params = {}) => new Promise((resolve, reject) => {
  const id = ++seq;
  pending.set(id, { resolve, reject });
  ws.send(JSON.stringify({ id, method, params }));
});
const evaluate = async (expression) => {
  const r = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails));
  return r.result.value;
};

await send("Page.enable");
await send("Emulation.setDeviceMetricsOverride", { width: W, height: H, deviceScaleFactor: 1, mobile: false });
const url = `${pathToFileURL(join(here, "scene.html")).href}?lang=${lang}&ratio=${ratio}`;
await send("Page.navigate", { url });
while (!events.includes("Page.loadEventFired")) await new Promise((r) => setTimeout(r, 50));
await evaluate("window.ready");
const dur = Number(args.dur || (await evaluate("window.DURATION")));

async function shot(t) {
  await evaluate(`render(${t}); new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))`);
  const { data } = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: false });
  return Buffer.from(data, "base64");
}

if (args.stills) {
  const outdir = args.outdir || ".";
  mkdirSync(outdir, { recursive: true });
  for (const t of args.stills.split(",").map(Number)) {
    writeFileSync(join(outdir, `${lang}-${ratio}-${t.toFixed(2)}.png`), await shot(t));
  }
} else {
  const out = args.out || `FoldGit-${lang}-${ratio}.mp4`;
  const ff = spawn("ffmpeg", [
    "-y", "-loglevel", "error", "-f", "image2pipe", "-framerate", String(fps), "-c:v", "png", "-i", "-",
    "-c:v", "libx264", "-preset", "slow", "-crf", "16", "-pix_fmt", "yuv420p", "-movflags", "+faststart", out,
  ], { stdio: ["pipe", "inherit", "inherit"] });
  const total = Math.round(fps * dur);
  for (let f = 0; f < total; f++) {
    const buf = await shot(f / fps);
    if (!ff.stdin.write(buf)) await new Promise((r) => ff.stdin.once("drain", r));
    if (f % 90 === 0) process.stderr.write(`${lang}-${ratio} ${f}/${total}\n`);
  }
  ff.stdin.end();
  await new Promise((r) => ff.on("close", r));
}

ws.close();
chrome.kill();
