import { afterEach, describe, expect, it, vi } from "@effect/vitest";
import { Effect } from "effect";

import { AccountUnauthorized } from "@executor-js/api";
import { AccountProvider } from "@executor-js/api/server";

import * as access from "../auth/cloudflare-access";
import { loadConfig } from "../config";
import { cloudflareAccountProvider } from "./account-provider";

const config = loadConfig({
  ENABLE_DEV_AUTH: "true",
  EXECUTOR_SECRET_KEY: "test-secret-key-0123456789abcdef",
  ADMIN_EMAILS: "admin@example.com",
  ACCESS_SERVICE_TOKEN_SUBJECTS: '{"service.access":"admin-subject"}',
});

afterEach(() => vi.restoreAllMocks());

const membersFor = (claims: Record<string, unknown>) => {
  // Test the account projection at its verified-identity boundary. JWT
  // verification and allowlist mapping have their own auth tests.
  vi.spyOn(access, "makeAccessVerifier").mockReturnValue({
    verify: () => Effect.succeed(access.principalFromAccessClaims(claims, config)),
  });
  return Effect.gen(function* () {
    const provider = yield* AccountProvider;
    return yield* provider.listMembers({});
  }).pipe(Effect.provide(cloudflareAccountProvider(config)));
};

describe("Cloudflare account membership", () => {
  it.effect("exposes the authenticated admin to the shared console", () =>
    Effect.gen(function* () {
      const result = yield* membersFor({ sub: "admin-subject", email: "admin@example.com" });
      expect(result.members).toEqual([
        expect.objectContaining({
          userId: "admin-subject",
          email: "admin@example.com",
          role: "admin",
          status: "active",
          isCurrentUser: true,
        }),
      ]);
    }),
  );

  it.effect("does not promote a member whose Access groups include admin", () =>
    Effect.gen(function* () {
      const result = yield* membersFor({
        sub: "member",
        email: "member@example.com",
        groups: ["admin"],
      });
      expect(result.members).toEqual([
        expect.objectContaining({ role: "member", isCurrentUser: true }),
      ]);
    }),
  );

  it.effect("does not copy admin privileges to a mapped service token", () =>
    Effect.gen(function* () {
      const result = yield* membersFor({
        type: "app",
        common_name: "service.access",
        email: "admin@example.com",
        groups: ["admin"],
      });
      expect(result.members).toEqual([
        expect.objectContaining({ userId: "admin-subject", role: "member", email: null }),
      ]);
    }),
  );

  it.effect("rejects requests without a verified identity", () =>
    Effect.gen(function* () {
      const error = yield* membersFor({}).pipe(Effect.flip);
      expect(error).toBeInstanceOf(AccountUnauthorized);
    }),
  );
});
