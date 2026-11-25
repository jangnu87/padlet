import "server-only";

import { createHmac } from "node:crypto";
import { getSupabaseAdmin } from "@/lib/supabaseAdmin";
import { requireEnv } from "@/lib/env";

export type RateRule = { max: number; windowSeconds: number };

export const RATE_RULES = {
  createMemo: { max: 20, windowSeconds: 10 * 60 },
  deleteRequest: { max: 30, windowSeconds: 10 * 60 },
  deleteFailure: { max: 5, windowSeconds: 10 * 60 },
  adminLoginFailure: { max: 5, windowSeconds: 15 * 60 },
} as const satisfies Record<string, RateRule>;

// Raw IPs are not stored; the key is an HMAC of the scope and identifiers.
function bucketKey(scope: string, parts: string[]) {
  return createHmac("sha256", requireEnv("ADMIN_SESSION_SECRET"))
    .update([scope, ...parts].join("|"))
    .digest("hex");
}

/** Counts one attempt. Returns false when the limit has been exceeded. */
export async function consumeRateLimit(
  scope: string,
  parts: string[],
  rule: RateRule,
) {
  const { data, error } = await getSupabaseAdmin().rpc("rate_limit_hit", {
    p_key: bucketKey(scope, parts),
    p_max: rule.max,
    p_window_seconds: rule.windowSeconds,
  });
  if (error) throw error;
  return data === true;
}

/** Reads the bucket without counting. Returns false when already exhausted. */
export async function isWithinRateLimit(
  scope: string,
  parts: string[],
  rule: RateRule,
) {
  const { data, error } = await getSupabaseAdmin().rpc("rate_limit_check", {
    p_key: bucketKey(scope, parts),
    p_max: rule.max,
    p_window_seconds: rule.windowSeconds,
  });
  if (error) throw error;
  return data === true;
}
