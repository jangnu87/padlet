import { handleUserDelete } from "@/lib/memoActions";

export const runtime = "nodejs";

export async function POST(request: Request) {
  return handleUserDelete(request);
}
