import "server-only";

import { NextResponse } from "next/server";
import { isAdminRequest } from "@/lib/adminSession";
import { isPastelColor, PASTEL_COLORS } from "@/lib/colors";
import {
  hashPassword,
  isFourDigitPassword,
  verifyPassword,
} from "@/lib/password";
import {
  consumeRateLimit,
  isWithinRateLimit,
  RATE_RULES,
} from "@/lib/rateLimit";
import {
  getClientIp,
  isUuid,
  jsonError,
  readJsonObject,
  rejectIfCrossOrigin,
} from "@/lib/requestSecurity";
import { getSupabaseAdmin } from "@/lib/supabaseAdmin";

const TOO_MANY = "요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.";

export async function handleCreateMemo(request: Request) {
  const blocked = rejectIfCrossOrigin(request);
  if (blocked) return blocked;

  try {
    const ip = getClientIp(request);
    if (!(await consumeRateLimit("create", [ip], RATE_RULES.createMemo))) {
      return jsonError(TOO_MANY, 429);
    }

    const body = await readJsonObject(request);
    if (!body) return jsonError("잘못된 요청입니다.", 400);

    const title = typeof body.title === "string" ? body.title.trim() : "";
    const content = typeof body.content === "string" ? body.content.trim() : "";

    if (!title || !content) {
      return jsonError("제목과 내용을 모두 입력해 주세요.", 400);
    }
    if (title.length > 80 || content.length > 2000) {
      return jsonError("메모가 허용된 길이를 초과했습니다.", 400);
    }
    if (!isFourDigitPassword(body.password)) {
      return jsonError("삭제 비밀번호는 숫자 4자리여야 합니다.", 400);
    }
    if (body.color !== undefined && !isPastelColor(body.color)) {
      return jsonError("허용되지 않은 색상입니다.", 400);
    }

    const color =
      body.color ??
      PASTEL_COLORS[Math.floor(Math.random() * PASTEL_COLORS.length)];

    const passwordHash = await hashPassword(body.password);
    const { data, error } = await getSupabaseAdmin().rpc(
      "create_memo_with_credentials",
      {
        p_title: title,
        p_content: content,
        p_color: color,
        p_password_hash: passwordHash,
      },
    );
    if (error) throw error;

    return NextResponse.json({ memo: data }, { status: 201 });
  } catch (error) {
    console.error("create memo", error);
    return jsonError("메모를 저장하지 못했습니다.", 500);
  }
}

export async function handleUserDelete(request: Request, routeId?: string) {
  const blocked = rejectIfCrossOrigin(request);
  if (blocked) return blocked;

  try {
    const body = await readJsonObject(request);
    const id = routeId ?? body?.id;
    if (!body || !isUuid(id) || !isFourDigitPassword(body.password)) {
      return jsonError("메모와 숫자 4자리 비밀번호를 확인해 주세요.", 400);
    }

    const ip = getClientIp(request);
    if (!(await consumeRateLimit("delete", [ip], RATE_RULES.deleteRequest))) {
      return jsonError(TOO_MANY, 429);
    }
    const failureParts = [id, ip];
    if (!(await isWithinRateLimit("delete-fail", failureParts, RATE_RULES.deleteFailure))) {
      return jsonError(TOO_MANY, 429);
    }

    const supabase = getSupabaseAdmin();
    const { data: credential, error: readError } = await supabase
      .from("memo_credentials")
      .select("password_hash")
      .eq("memo_id", id)
      .maybeSingle();
    if (readError) throw readError;

    const matches = credential
      ? await verifyPassword(body.password, credential.password_hash)
      : false;

    if (!matches) {
      await consumeRateLimit("delete-fail", failureParts, RATE_RULES.deleteFailure);
      return credential
        ? jsonError("삭제 비밀번호가 일치하지 않습니다.", 403)
        : jsonError("메모를 찾을 수 없습니다.", 404);
    }

    const { error: deleteError } = await supabase.from("memos").delete().eq("id", id);
    if (deleteError) throw deleteError;

    return NextResponse.json({ ok: true });
  } catch (error) {
    console.error("delete memo", error);
    return jsonError("메모를 삭제하지 못했습니다.", 500);
  }
}

export async function handleAdminDelete(request: Request, routeId?: string) {
  const blocked = rejectIfCrossOrigin(request);
  if (blocked) return blocked;
  if (!(await isAdminRequest())) return jsonError("관리자 인증이 필요합니다.", 401);

  const id = routeId ?? (await readJsonObject(request))?.id;
  if (!isUuid(id)) return jsonError("잘못된 요청입니다.", 400);

  try {
    const { error } = await getSupabaseAdmin().from("memos").delete().eq("id", id);
    if (error) throw error;
    return NextResponse.json({ ok: true });
  } catch (error) {
    console.error("admin delete memo", error);
    return jsonError("메모를 강제 삭제하지 못했습니다.", 500);
  }
}

export async function handleAdminDeleteAll(request: Request) {
  const blocked = rejectIfCrossOrigin(request);
  if (blocked) return blocked;
  if (!(await isAdminRequest())) return jsonError("관리자 인증이 필요합니다.", 401);

  try {
    const { error } = await getSupabaseAdmin()
      .from("memos")
      .delete()
      .not("id", "is", null);
    if (error) throw error;
    return NextResponse.json({ ok: true });
  } catch (error) {
    console.error("admin delete all", error);
    return jsonError("전체 메모를 삭제하지 못했습니다.", 500);
  }
}
