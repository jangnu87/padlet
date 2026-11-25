import { handleAdminDeleteAll } from "@/lib/memoActions";

export const runtime = "nodejs";

export async function DELETE(request: Request) {
  return handleAdminDeleteAll(request);
}

export async function POST(request: Request) {
  return handleAdminDeleteAll(request);
}
