import { defineConfig, devices } from "@playwright/test";

// One smoke test against a fake app (e2e/fixture-server.ts) that serves the built
// web/dist: run `npm run build` first, then `npm run e2e`. Chromium only.
export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: 0,
  reporter: "list",
  use: { trace: "retain-on-failure" },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
});
