// Export README artwork with the same wallpaper layout as the website.
// Requires Playwright (with Chromium) and Sharp. See website/README.md.
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright");
const sharp = require("sharp");
const website = fileURLToPath(new URL("../", import.meta.url));
const destination = path.join(website, "assets/showcases");
const temporary = await mkdtemp(path.join(tmpdir(), "foldgit-showcases-"));
const document = path.join(temporary, "showcase.html");

await mkdir(destination, { recursive: true });
await writeFile(document, `<!doctype html>
<html lang="en" data-theme="light"><head><meta charset="utf-8">
<link rel="stylesheet" href="${pathToFileURL(path.join(website, "styles.css"))}">
<style>
  body { width: 2176px; }
  .screenshot-wallpaper { margin: 0; border-radius: 0; }
</style></head><body>
<figure class="screenshot-wallpaper"><img width="1920" height="988" alt=""></figure>
</body></html>`);

const browser = await chromium.launch({
  headless: true,
  executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH
});
const page = await browser.newPage({
  viewport: { width: 2176, height: 1244 },
  deviceScaleFactor: 2,
  reducedMotion: "reduce"
});
await page.goto(pathToFileURL(document).href);

for (const language of ["zh", "en"]) {
  for (const scheme of ["light", "dark"]) {
    const name = `main-${language}-${scheme}@2x.webp`;
    const source = pathToFileURL(path.join(website, "assets/screenshots", name)).href;
    await page.evaluate(async ({ source, scheme }) => {
      document.documentElement.dataset.theme = scheme;
      const image = document.querySelector("figure img");
      image.src = source;
      await image.decode();
      const wallpaper = new Image();
      wallpaper.src = getComputedStyle(document.querySelector("figure"))
        .backgroundImage.slice(5, -2);
      await wallpaper.decode();
    }, { source, scheme });
    const png = await page.locator("figure").screenshot();
    await sharp(png).webp({ quality: 90, effort: 6 }).toFile(path.join(destination, name));
    console.log(`Exported assets/showcases/${name}`);
  }
}

await browser.close();
await rm(temporary, { recursive: true });
