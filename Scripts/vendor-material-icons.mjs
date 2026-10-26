import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Pin both the upstream version and archive integrity for reproducible imports.
const version = '5.39.0';
const integrity = 'sha512-6dUQXJgNBlklaILIOlCZXhSBTsBmLkt11XMoTY7Uyb4ZikelGgZHOY4AdOWBA+SXz51cVWfOVnTHrTwGM91eYw==';
const archiveURL = `https://registry.npmjs.org/material-icon-theme/-/material-icon-theme-${version}.tgz`;
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const resources = join(root, 'Platforms/macOS/Resources');
const assets = join(resources, 'MaterialFileIcons');
const temporary = await mkdtemp(join(tmpdir(), 'FoldGit-material-icons-'));
const writeJSON = async (path, value) => writeFile(path, `${JSON.stringify(value, null, 2)}\n`);
const sorted = (value) => Object.fromEntries(Object.entries(value).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0));
const normalize = (value) => {
  const result = {};
  for (const [key, icon] of Object.entries(value)) {
    const normalized = key.toLowerCase();
    if (result[normalized] && result[normalized] !== icon) {
      throw new Error(`Conflicting case-insensitive association: ${key}`);
    }
    result[normalized] = icon;
  }
  return sorted(result);
};

const archive = process.argv[2]
  ? await readFile(resolve(process.argv[2]))
  : await (async () => {
    const response = await fetch(archiveURL);
    if (!response.ok) throw new Error(`Download failed: ${response.status}`);
    return Buffer.from(await response.arrayBuffer());
  })();
const actualIntegrity = `sha512-${createHash('sha512').update(archive).digest('base64')}`;
if (actualIntegrity !== integrity) throw new Error('Material Icon Theme archive integrity mismatch');
const archivePath = join(temporary, 'package.tgz');
await writeFile(archivePath, archive);
execFileSync('tar', ['-xzf', archivePath, '-C', temporary]);
const packagePath = join(temporary, 'package');
const require = createRequire(import.meta.url);
const { generateManifest } = require(join(packagePath, 'dist/module/index.cjs'));
// Avoid enabling Angular-specific suffixes for every repository.
const manifest = generateManifest({ activeIconPack: 'none' });
const fileNames = normalize(manifest.fileNames);
const fileExtensions = normalize(manifest.fileExtensions);
const icons = [...new Set([manifest.file, ...Object.values(fileNames), ...Object.values(fileExtensions)])].sort();
const lightIcons = new Map();
for (const key of ['fileNames', 'fileExtensions']) {
  for (const [association, lightIcon] of Object.entries(manifest.light[key])) {
    const icon = manifest[key][association];
    if (!icon) throw new Error(`Light association has no base icon: ${association}`);
    if (lightIcons.has(icon) && lightIcons.get(icon) !== lightIcon) {
      throw new Error(`Conflicting light appearance: ${icon}`);
    }
    lightIcons.set(icon, lightIcon);
  }
}

// Verify every referenced SVG before replacing the generated assets.
const svgFiles = new Map();
for (const id of new Set([...icons, ...lightIcons.values()])) {
  const svgPath = resolve(packagePath, 'dist', manifest.iconDefinitions[id].iconPath);
  await readFile(svgPath);
  svgFiles.set(id, svgPath);
}
// Plain SVG files: an asset catalog would also store two raster copies of every icon.
await rm(assets, { recursive: true, force: true });
await mkdir(assets, { recursive: true });
let svgBytes = 0;
const copySVG = async (id, filename) => {
  await copyFile(svgFiles.get(id), join(assets, filename));
  svgBytes += (await readFile(svgFiles.get(id))).byteLength;
};
for (const icon of icons) {
  await copySVG(icon, `${icon}.svg`);
  // The app draws `<icon>.light.svg` in light appearances.
  if (lightIcons.has(icon)) await copySVG(lightIcons.get(icon), `${icon}.light.svg`);
}
await writeJSON(join(resources, 'MaterialFileIcons.json'), {
  version,
  defaultIcon: manifest.file,
  lightIcons: [...lightIcons.keys()].filter((icon) => icons.includes(icon)).sort(),
  fileNames,
  fileExtensions,
});
const licensesPath = join(root, 'Shared/Resources/Licenses/LICENSE.txt');
const licenseStart = '----- BEGIN MATERIAL ICON THEME -----';
const licenseEnd = '----- END MATERIAL ICON THEME -----';
const licenseSection = `${licenseStart}\nMaterial Icon Theme ${version}\nhttps://github.com/material-extensions/vscode-material-icon-theme\n\n${await readFile(join(packagePath, 'LICENSE'), 'utf8')}\n${licenseEnd}`;
const licenses = await readFile(licensesPath, 'utf8');
const start = licenses.indexOf(licenseStart);
const end = licenses.indexOf(licenseEnd);
if ((start < 0) !== (end < 0) || (start >= 0 && end < start)) {
  throw new Error('Invalid Material Icon Theme license section');
}
await writeFile(licensesPath, start < 0
  ? `${licenses.trimEnd()}\n\n${licenseSection}\n`
  : `${licenses.slice(0, start)}${licenseSection}${licenses.slice(end + licenseEnd.length)}`);
await rm(temporary, { recursive: true });
console.log(`Imported Material Icon Theme ${version}: ${icons.length} icons, ${lightIcons.size} light variants, ${Object.keys(fileExtensions).length} extensions, ${Object.keys(fileNames).length} filenames, ${svgBytes} SVG bytes.`);
