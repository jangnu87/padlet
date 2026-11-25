import "server-only";

import { createHmac, randomBytes } from "node:crypto";
import { cookies } from "next/headers";
import { requireEnv } from "@/lib/env";
import { getSupabaseAdmin } from "@/lib/supabaseAdmin";

export const ADMIN_COOKIE = "mindlet_admin";
export const ADMIN_SESSION_SECONDS = 60 * 60 * 8;

export const adminCookieOptions = {
  httpOnly: true,
  secure: process.env.NODE_ENV === "production",
  sameSite: "strict" as const,
  path: "/",
};

function verifierFor(token: string) {
  return createHmac("sha256", requireEnv("ADMIN_SESSION_SECRET"))
    .update(token)
    .digest("hex");
}

export async function createAdminSession() {
  const token = randomBytes(32).toString("base64url");
  const supabase = getSupabaseAdmin();

  await supabase
    .from("admin_sessions")
    .delete()
    .lt("expires_at", new Date().toISOString());

  const { error } = await supabase.from("admin_sessions").insert({
    token_hash: verifierFor(token),
    expires_at: new Date(Date.now() + ADMIN_SESSION_SECONDS * 1000).toISOString(),
  });
  if (error) throw error;

  return token;
}

export async function isAdminRequest() {
  const token = (await cookies()).get(ADMIN_COOKIE)?.value;
  if (!token || token.length > 128) return false;

  try {
    const { data, error } = await getSupabaseAdmin()
      .from("admin_sessions")
      .select("expires_at")
      .eq("token_hash", verifierFor(token))
      .maybeSingle();
    if (error) throw error;
    return Boolean(data && new Date(data.expires_at).getTime() > Date.now());
  } catch (error) {
    console.error("admin session check failed", error);
    return false;
  }
}

export async function destroyAdminSession() {
  const token = (await cookies()).get(ADMIN_COOKIE)?.value;
  if (!token || token.length > 128) return;
  const { error } = await getSupabaseAdmin()
    .from("admin_sessions")
    .delete()
    .eq("token_hash", verifierFor(token));
  if (error) throw error;
}
