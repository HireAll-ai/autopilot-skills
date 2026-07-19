// Factory-owned Playwright config: video recording is ALWAYS on.
// Hooks invoke it with env vars; product repos only supply e2e/*.spec.* files.
// Paths resolve against the repo (cwd), not this config file's location.
import path from 'node:path';

export default {
  testDir: path.resolve(process.cwd(), process.env.E2E_SPEC_DIR || 'e2e'),
  outputDir: path.resolve(process.cwd(), process.env.E2E_OUT_DIR || 'factory-artifacts/e2e-results'),
  timeout: 60_000,
  retries: 1,
  reporter: [['list'], ['./reporter.mjs']],
  use: {
    baseURL: process.env.E2E_BASE_URL,
    video: 'on',
    screenshot: 'on',
    trace: 'retain-on-failure',
  },
};
