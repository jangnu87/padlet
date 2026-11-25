import { NextResponse } from "next/server";
import {
  ADMIN_COOKIE,
  ADMIN_SESSION_SECONDS,
  adminCookieOptions,
  createAdminSession,
} from "@/lib/adminSession";
import { requireEnv } from "@/lib/env";
import { verifyPassword } from "@/lib/password";
import {
  consumeRateLimit,
  isWithinRateLimit,
  RATE_RULES,
} from "@/lib/rateLimit";
import {
  getClientIp,
  jsonError,
  readJsonObject,
  rejectIfCrossOrigin,
} from "@/lib/requestSecurity";

export const runtime = "nodejs";

export async function POST(request: Request) {
  const blocked = rejectIfCrossOrigin(request);
  if (blocked) return blocked;

  try {
    const body = await readJsonObject(request);
    if (
      !body ||
      typeof body.password !== "string" ||
      body.password.length === 0 ||
      body.password.length > 200
    ) {
      return jsonError("잘못된 요청입니다.", 400);
    }

    const ip = getClientIp(request);
    const rule = RATE_RULES.adminLoginFailure;
    if (!(await isWithinRateLimit("admin-login", [ip], rule))) {
      return jsonError("요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.", 429);
    }

    const matches = await verifyPassword(
      body.password,
      requireEnv("ADMIN_PASSWORD_HASH"),
    );
    if (!matches) {
      await consumeRateLimit("admin-login", [ip], rule);
      return jsonError("관리자 비밀번호가 일치하지 않습니다.", 401);
    }

    const token = await createAdminSession();
    const response = NextResponse.json({ ok: true });
    response.cookies.set(ADMIN_COOKIE, token, {
      ...adminCookieOptions,
      maxAge: ADMIN_SESSION_SECONDS,
    });
    return response;
  } catch (error) {
    console.error("POST /api/admin/login", error);
    return jsonError("관리자 로그인에 실패했습니다.", 500);
  }
}
