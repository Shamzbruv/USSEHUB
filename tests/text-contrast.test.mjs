import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

// Protect the foreground/surface pairings used across public and admin pages.
// Measurements use WCAG relative luminance; translucent badges are composited.
const css = fs.readFileSync('assets/usse-design.css', 'utf8');
const root = css.match(/:root\s*\{([\s\S]*?)\}/)[1];
const tokens = Object.fromEntries([...root.matchAll(/(--[\w-]+):\s*(#[\da-f]{3,8})\b/gi)].map((m) => [m[1], m[2]]));
function rgba(value) {
    if (value.startsWith('#')) {
        let h = value.slice(1);
        if (h.length === 3) h = [...h].map((c) => c + c).join('');
        return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16)).concat(h.length === 8 ? parseInt(h.slice(6), 16) / 255 : 1);
    }
    const channels = value.match(/[\d.]+/g).map(Number);
    return [...channels.slice(0, 3), channels[3] ?? 1];
}
function over(fg, bg) {
    const a = fg[3] ?? 1;
    return fg.slice(0, 3).map((v, i) => v * a + bg[i] * (1 - a)).concat(1);
}
function luminance(rgb) {
    const linear = rgb.slice(0, 3).map((c) => c / 255).map((c) => c <= .04045 ? c / 12.92 : ((c + .055) / 1.055) ** 2.4);
    return linear.reduce((sum, c, i) => sum + c * [.2126, .7152, .0722][i], 0);
}
let checks = 0;
function contrast(fg, bg, label, threshold = 4.5) {
    const a = luminance(fg), b = luminance(bg);
    const ratio = (Math.max(a, b) + .05) / (Math.min(a, b) + .05);
    assert.ok(ratio >= threshold, `${label}: ${ratio.toFixed(2)}:1 is below ${threshold}:1`);
    checks += 1;
}
const surfaces = ['#ffffff', '#f3f5fb', '#eaf0f7', '#edf2f8', '#e8f1f5'];
for (const foreground of ['--hub-ink', '--hub-muted', '--hub-positive', '--hub-warning', '--hub-danger', '--hub-info', '--green', '--blue', '--red', '--silver', '--gold', '--platinum']) {
    assert.ok(tokens[foreground], `Missing semantic foreground ${foreground}`);
    for (const background of surfaces) contrast(rgba(tokens[foreground]), rgba(background), `${foreground} on ${background}`);
}
contrast(rgba('#fff'), rgba(tokens['--hub-sea']), 'Primary action');
contrast(rgba('#fff'), rgba(tokens['--hub-purple']), 'Purple navigation');

const hub = fs.readFileSync('ajm-advertising-hub.html', 'utf8');
const themeSource = hub.match(/function advPackageTheme\(pkg\)\s*\{[\s\S]*?\n    \}/)?.[0];
assert.ok(themeSource, 'Advertising catalogue theme function is missing');
const context = vm.createContext({});
vm.runInContext(themeSource, context);
for (const code of ['silver', 'gold', 'platinum', 'basic', 'advanced', 'banner']) {
    const theme = context.advPackageTheme({code});
    const card = over(rgba(theme.bg), rgba('#fff'));
    const badge = over(rgba(theme.badgeBg), card);
    contrast(rgba(theme.badge), badge, `${code} package badge`);
    const price = hub.match(/\.pkg-tile-price\s*\{[^}]*\bcolor:\s*(#[\da-f]+)/i)?.[1];
    assert.ok(price, 'Package price foreground is missing');
    contrast(rgba(price), card, `${code} price`);
}
const template = hub.match(/function renderAdvPackages\(\)\s*\{[\s\S]*?\n    async function loadAdvPackages/)?.[0];
assert.ok(template, 'Advertising catalogue rendering function is missing');
for (const match of template.matchAll(/\bcolor:\s*(#[\da-f]{3,8})\b/gi)) {
    for (const surface of ['#fff', '#fffdf7', '#f5f9ff']) contrast(rgba(match[1]), rgba(surface), `Dynamic package description ${match[1]}`);
}
console.log(`Text contrast passed: ${checks} semantic foreground, reading surface and dynamic catalogue pairings meet WCAG AA.`);
