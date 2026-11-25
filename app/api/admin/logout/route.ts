import { NextResponse } from "next/server";
import {
  ADMIN_COOKIE,
  adminCookieOptions,
  destroyAdminSession,
} from "@/lib/adminSession";
import { jsonError, rejectIfCrossOrigin } from "@/lib/requestSecurity";

export const runtime = "nodejs";

export async function POST(request: Request) {
  const blocked = rejectIfCrossOrigin(request);
  if (blocked) return blocked;

  try {
    await destroyAdminSession();
  } catch (error) {
    console.error("POST /api/admin/logout", error);
    return jsonError("로그아웃에 실패했습니다.", 500);
  }

  const response = NextResponse.json({ ok: true });
  response.cookies.set(ADMIN_COOKIE, "", { ...adminCookieOptions, maxAge: 0 });
  return response;
}
