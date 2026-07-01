#!/usr/bin/env node
// record-e2e.mjs — run one browser scenario with Playwright and record it to video.
//
// Portable, gstack-independent (gstack's `browse` daemon can't record video). Used by the
// --e2e step of /autodev and /autoship when qa.video.enabled is true: the agent derives a
// scenario, writes it as JSON, and invokes this runner, which walks the steps with
// recordVideo on and leaves a .webm (+ .mp4/.gif when ffmpeg is present).
//
// Usage:
//   node record-e2e.mjs <scenario.json|-> [--out-dir DIR] [--base-url URL]
//                       [--format mp4|gif|webm] [--gif] [--max-seconds N] [--headed]
//   echo '<scenario json>' | node record-e2e.mjs -
// --gif additionally emits a gif (for a PR body) alongside the primary --format output.
//
// Scenario shape:
//   { "name": "submit-contact",
//     "baseUrl": "http://localhost:5173",           // or --base-url; steps may use relative paths
//     "viewport": { "width": 1000, "height": 700 }, // optional
//     "steps": [
//       { "goto": "/contact" },
//       { "fill": "#email", "value": "a@b.com" },
//       { "click": "text=Submit" },
//       { "press": "Enter" },                        // optional "selector" to target
//       { "waitFor": "text=Thanks" },                // selector, or a number of ms
//       { "expect": "text=Thanks", "state": "visible" },   // state: visible|hidden|attached
//       { "screenshot": "after-submit" },            // saved as <name>-<label>.png
//       { "wait": 500 }                              // ms
//     ] }
//
// Exit codes: 0 = every step passed; 1 = a step failed (video still saved); 2 = Playwright
// unavailable → the caller falls back to the non-video browser pass (e2e never hard-blocked by a
// missing recorder); 3 = usage / scenario error (bad flags, missing/unparseable scenario, no
// steps) → FIX the scenario and re-run; do NOT fall back and do NOT mark the e2e green.
import { readFileSync, mkdirSync, existsSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';

// ---- args -----------------------------------------------------------------------------
const argv = process.argv.slice(2);
const USAGE = 'usage: node record-e2e.mjs <scenario.json|-> [--out-dir DIR] [--base-url URL] [--format mp4|gif|webm] [--gif] [--max-seconds N] [--headed]';
if (argv[0] === '--help' || argv[0] === '-h') { console.error(USAGE); process.exit(0); }
if (argv.length === 0) { console.error(USAGE); process.exit(3); }

const opts = { format: 'mp4', outDir: '.context/video', maxSeconds: 90, headed: false, baseUrl: '', gif: false };
const positional = [];
// value-taking flags must be followed by a real value (not end-of-args, not another --flag).
const val = (i, flag) => {
  const v = argv[i];
  if (v === undefined || v.startsWith('--')) { console.error(`record-e2e: ${flag} requires a value`); process.exit(3); }
  return v;
};
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--out-dir') opts.outDir = val(++i, a);
  else if (a === '--format') opts.format = val(++i, a);
  else if (a === '--base-url') opts.baseUrl = val(++i, a);
  else if (a === '--max-seconds') { const n = Number(val(++i, a)); opts.maxSeconds = Number.isFinite(n) && n > 0 ? n : 90; }
  else if (a === '--gif') opts.gif = true;
  else if (a === '--headed') opts.headed = true;
  else positional.push(a);
}
const scenarioArg = positional[0];
if (!scenarioArg) { console.error(`record-e2e: no scenario given\n${USAGE}`); process.exit(3); }

// ---- load scenario --------------------------------------------------------------------
let scenario;
try {
  const raw = scenarioArg === '-' ? readFileSync(0, 'utf8') : readFileSync(scenarioArg, 'utf8');
  scenario = JSON.parse(raw);
} catch (e) {
  console.error(`record-e2e: cannot read/parse scenario: ${e.message}`);
  process.exit(3);
}
const name = (scenario.name || 'scenario').replace(/[^a-zA-Z0-9._-]/g, '-');
const baseUrl = opts.baseUrl || scenario.baseUrl || '';
const steps = Array.isArray(scenario.steps) ? scenario.steps : [];
if (steps.length === 0) { console.error('record-e2e: scenario has no steps'); process.exit(3); }

// ---- resolve Playwright (soft dependency) ---------------------------------------------
let chromium;
try {
  ({ chromium } = await import('playwright'));
} catch {
  try { ({ chromium } = await import('playwright-core')); } catch {
    console.error(
      'record-e2e: Playwright not found. Install it once:\n' +
      '  npm i playwright && npx playwright install chromium   # in your project, or the autopilot plugin dir\n' +
      'Falling back: the caller runs the non-video browser pass instead.',
    );
    process.exit(2);
  }
}

// ---- output paths ---------------------------------------------------------------------
const outDir = path.resolve(opts.outDir);
mkdirSync(outDir, { recursive: true });
const webmPath = path.join(outDir, `${name}.webm`);
const viewport = scenario.viewport || { width: 1000, height: 700 };

const abs = (u) => (/^https?:\/\//.test(u) ? u : baseUrl.replace(/\/$/, '') + (u.startsWith('/') ? u : '/' + u));

// ---- run ------------------------------------------------------------------------------
const results = [];
let browser, context, page, video;
let ok = true;
const deadline = Date.now() + opts.maxSeconds * 1000;

try {
  browser = await chromium.launch({ headless: !opts.headed });
  context = await browser.newContext({ viewport, recordVideo: { dir: outDir, size: viewport } });
  page = await context.newPage();
  video = page.video();

  for (let i = 0; i < steps.length; i++) {
    const step = steps[i];
    const label = `step ${i + 1}: ${JSON.stringify(step)}`;
    if (Date.now() > deadline) { results.push({ i, step, ok: false, error: 'maxSeconds exceeded' }); ok = false; break; }
    try {
      const remaining = Math.max(1000, deadline - Date.now());
      if ('goto' in step) await page.goto(abs(step.goto), { waitUntil: step.waitUntil || 'load', timeout: remaining });
      else if ('fill' in step) await page.locator(step.fill).fill(String(step.value ?? ''), { timeout: remaining });
      else if ('click' in step) await page.locator(step.click).click({ timeout: remaining });
      else if ('press' in step) {
        if (step.selector) await page.locator(step.selector).press(step.press, { timeout: remaining });
        else await page.keyboard.press(step.press);
      }
      else if ('waitFor' in step) {
        if (typeof step.waitFor === 'number') await page.waitForTimeout(step.waitFor);
        else await page.locator(step.waitFor).first().waitFor({ state: step.state || 'visible', timeout: remaining });
      } else if ('expect' in step) {
        await page.locator(step.expect).first().waitFor({ state: step.state || 'visible', timeout: remaining });
      } else if ('screenshot' in step) {
        await page.screenshot({ path: path.join(outDir, `${name}-${String(step.screenshot).replace(/[^a-zA-Z0-9._-]/g, '-')}.png`) });
      } else if ('wait' in step) {
        await page.waitForTimeout(Number(step.wait) || 0);
      } else { throw new Error('unknown step'); }
      results.push({ i, step, ok: true });
      console.error(`  ✓ ${label}`);
    } catch (e) {
      results.push({ i, step, ok: false, error: e.message.split('\n')[0] });
      console.error(`  ✗ ${label} — ${e.message.split('\n')[0]}`);
      ok = false;
      break; // stop at first failure; video up to the failure is still saved
    }
  }
} catch (e) {
  console.error(`record-e2e: run error — ${e.message.split('\n')[0]}`);
  ok = false;
} finally {
  // Closing the context is what finalizes the Playwright video file.
  try { if (context) await context.close(); } catch {}
  try { if (video) await video.saveAs(webmPath); } catch (e) { console.error(`record-e2e: could not save video — ${e.message}`); }
  try { if (video) await video.delete(); } catch {}
  try { if (browser) await browser.close(); } catch {}
}

// ---- convert (optional, ffmpeg) -------------------------------------------------------
const artifacts = { webm: existsSync(webmPath) ? webmPath : null, mp4: null, gif: null };
const hasFfmpeg = spawnSync('ffmpeg', ['-version'], { stdio: 'ignore' }).status === 0;

function ffmpeg(args) { return spawnSync('ffmpeg', ['-y', '-loglevel', 'error', ...args], { stdio: 'inherit' }).status === 0; }

const wantMp4 = opts.format === 'mp4';
const wantGif = opts.format === 'gif' || opts.gif === true;   // --gif adds a gif alongside the primary output
if (artifacts.webm && (wantMp4 || wantGif)) {
  if (!hasFfmpeg) {
    console.error('record-e2e: ffmpeg not found — keeping .webm only (install ffmpeg for mp4/gif). GitHub and Chromium play webm.');
  } else {
    if (wantMp4) {
      const mp4 = path.join(outDir, `${name}.mp4`);
      if (ffmpeg(['-i', webmPath, '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', mp4])) artifacts.mp4 = mp4;
    }
    if (wantGif) {
      const gif = path.join(outDir, `${name}.gif`);
      const palette = path.join(outDir, `${name}.palette.png`);
      const vf = 'fps=12,scale=800:-1:flags=lanczos';
      const paletteOk = ffmpeg(['-i', webmPath, '-vf', `${vf},palettegen`, palette]);
      try {
        if (paletteOk &&
            ffmpeg(['-i', webmPath, '-i', palette, '-lavfi', `${vf} [x]; [x][1:v] paletteuse`, gif])) {
          artifacts.gif = gif;
        }
      } finally {
        try { rmSync(palette); } catch {}   // always clean the temp palette, even on a failed 2nd pass
      }
    }
  }
}

// ---- report ---------------------------------------------------------------------------
console.log(JSON.stringify({ scenario: name, baseUrl, passed: ok, steps: results, artifacts }, null, 2));
process.exit(ok ? 0 : 1);
