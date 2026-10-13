#!/usr/bin/env node
// Rebuild the shared, transparent Codex PNGs from the flat OpenAI knot SVG.
// Requires sharp (or NODE_PATH pointing to a runtime that provides sharp).
const fs = require('node:fs');
const path = require('node:path');
const sharp = require('sharp');

const root = path.resolve(__dirname, '..');
const source = path.join(root, 'Assets/logos-src-codex.svg');
const model = fs.readFileSync(path.join(root, 'Sources/QuotaModel/Models.swift'), 'utf8');
const accent = model.match(/public var accentHex: String[\s\S]*?case \.codex:\s*"([0-9A-Fa-f]{6})"/)?.[1];
if (!accent) throw new Error('Could not read the central Codex accent colour.');
let svg = fs.readFileSync(source, 'utf8');
if (/<(?:linearGradient|radialGradient|filter|image)\b/.test(svg)) {
    throw new Error('The Codex mark must stay a flat vector knot.');
}
svg = svg.replace(/fill="#[0-9A-Fa-f]{6}"/g, `fill="#${accent}"`);
fs.writeFileSync(source, svg);

(async () => {
    for (const [file, size] of [
        ['Sources/QuotaBar/Resources/logos/codex.png', 128],
        ['Assets/logos-src-codex.png', 640],
    ]) {
        await sharp(Buffer.from(svg)).resize(size, size).png().toFile(path.join(root, file));
        console.log(`${file}: ${size} × ${size}, flat #${accent}, transparent background`);
    }
})().catch(error => { console.error(error); process.exitCode = 1; });
