import "server-only";

import { NextResponse } from "next/server";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

export function jsonError(error: string, status: number) {
  return NextResponse.json({ error }, { status });
}

/**
 * Compares the browser-sent Origin with the origin of the request URL that
 * Next.js reconstructs from the platform-provided host. A missing Origin is
 * rejected as well, so every state-changing API gets the same check.
 */
export function rejectIfCrossOrigin(request: Request) {
  const origin = request.headers.get("origin");
  let expected: string;
  try {
    expected = new URL(request.url).origin;
  } catch {
    return jsonError("허용되지 않은 요청입니다.", 403);
  }

  if (!origin || origin !== expected) {
    return jsonError("허용되지 않은 요청입니다.", 403);
  }
  return null;
}

/**
 * Vercel overwrites X-Forwarded-For (and sends the identical
 * x-vercel-forwarded-for / x-real-ip) so external values cannot spoof it.
 * https://vercel.com/docs/headers/request-headers
 */
export function getClientIp(request: Request) {
  const raw =
    request.headers.get("x-vercel-forwarded-for") ??
    request.headers.get("x-real-ip") ??
    request.headers.get("x-forwarded-for") ??
    "";
  const first = raw.split(",")[0]?.trim();
  return first && first.length <= 64 ? first : "unknown";
}

export async function readJsonObject(
  request: Request,
): Promise<Record<string, unknown> | null> {
  try {
    const body: unknown = await request.json();
    return body && typeof body === "object" && !Array.isArray(body)
      ? (body as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}
