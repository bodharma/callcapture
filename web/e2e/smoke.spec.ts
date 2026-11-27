import { expect, test as base } from "@playwright/test";
import { type FixtureServer, LOGIN_TOKEN, startFixtureServer } from "./fixture-server";

interface Fixtures {
  fixture: FixtureServer;
  /** Signs in the way the app's menu does: open /login with a token, land on `next`. */
  signIn: (next: string) => Promise<void>;
}

// Each test gets its own fake app (fresh sign-ins, secrets and live state).
const test = base.extend<Fixtures>({
  fixture: async ({}, use) => {
    const server = await startFixtureServer();
    await use(server);
    await server.close();
  },
  baseURL: async ({ fixture }, use) => use(fixture.url),
  signIn: async ({ page }, use) =>
    use(async (next) => {
      await page.goto(`/login?token=${LOGIN_TOKEN}&next=${encodeURIComponent(next)}`);
    }),
});

test("asks to sign in without a session, then the login link opens the archive", async ({ page, context }) => {
  await page.goto("/sessions");
  await expect(page.getByText("Open CallCapture from the menu bar to sign in again.")).toBeVisible();

  await page.goto(`/login?token=${LOGIN_TOKEN}&next=/sessions`);
  await expect(page).toHaveURL(/\/sessions$/);
  await expect(page.getByRole("link", { name: /Weekly sync, release plan/ })).toBeVisible();
  const [cookie] = await context.cookies();
  expect(cookie).toMatchObject({ name: "cc_session", httpOnly: true, sameSite: "Strict" });
});

test("opens a session from the list and seeks the audio from a transcript line", async ({ page, signIn }) => {
  await signIn("/sessions");
  await page.getByRole("link", { name: /Weekly sync, release plan/ }).click();
  await expect(page).toHaveURL(/\/sessions\/S1$/);
  await expect(page.getByRole("heading", { level: 1, name: "Weekly sync, release plan" })).toBeVisible();

  await page.getByRole("navigation", { name: "Session sections" }).getByRole("link", { name: "Transcript" }).click();
  await page.getByRole("button", { name: "Play from 00:12" }).click();

  const position = () => page.locator("audio").evaluate((audio: HTMLAudioElement) => audio.currentTime);
  await expect.poll(position).toBeGreaterThanOrEqual(12);
  expect(await position()).toBeLessThan(24);
  await expect(page.locator("li.line--active")).toContainText("Staging has to be green by Thursday.");
});

test("a saved settings key shows as set and is never shown back", async ({ page, signIn, fixture }) => {
  await signIn("/settings/ai-notes");
  const key = page.getByRole("textbox", { name: "OpenRouter key", exact: true });
  await expect(page.getByText("Not set.")).toBeVisible();

  await key.fill("sk-or-e2e-secret");
  await page.getByRole("button", { name: "Save OpenRouter key" }).click();

  await expect(page.getByText("Saved in the Keychain.")).toBeVisible();
  await expect(key).toHaveValue("");
  expect(fixture.savedSecrets.get("openrouter")).toBe("sk-or-e2e-secret");
  await expect(page.locator("body")).not.toContainText("sk-or-e2e-secret");
});

test("the live page shows a turn the app sends over the events stream", async ({ page, signIn, fixture }) => {
  await signIn("/live");
  await expect(page.getByText("Committed local speech shows up here.")).toBeVisible();
  await expect.poll(() => fixture.eventClients()).toBeGreaterThan(0);

  fixture.emitLiveTurn({ id: "e2e-1", source: "system", start: 61, end: 64, text: "Ship it on Friday.", language: "en" });

  await expect(page.getByText("Ship it on Friday.")).toBeVisible();
  await expect(page.getByRole("tab", { name: /1 committed turns/ })).toBeVisible();
});
