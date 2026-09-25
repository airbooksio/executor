import { expect } from "@effect/vitest";
import { Effect } from "effect";

import { scenario } from "../src/scenario";
import { Browser, Target } from "../src/services";
import { visit } from "../src/surfaces/browser";

scenario(
  "Cloudflare · an authenticated admin can open Add integration",
  { timeout: 120_000 },
  Effect.gen(function* () {
    const target = yield* Target;
    const browser = yield* Browser;
    const identity = yield* target.newIdentity();

    yield* browser.session(identity, async ({ page, step }) => {
      await step("Open the workspace as an admin", async () => {
        await visit(page, "/");
        await page.getByRole("heading", { name: "Integrations", exact: true }).waitFor();
      });

      await step("Add an integration with the restored admin controls", async () => {
        const add = page.getByRole("link", { name: "Add integration", exact: true });
        await add.waitFor({ timeout: 15_000 });
        await add.click();
        await page.waitForURL("**/integrations/browse");
        await page.getByRole("heading", { name: "Add an integration", exact: true }).waitFor();
        expect(new URL(page.url()).pathname).toMatch(/\/integrations\/browse$/);
      });
    });
  }),
);
