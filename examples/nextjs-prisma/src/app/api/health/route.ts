import { NextResponse } from "next/server";
import { isDatabaseReachable } from "@/lib/db/health";

export const dynamic = "force-dynamic";

// Usado pelo health check do contêiner. Só fica saudável com o banco acessível.
export async function GET() {
  const healthy = await isDatabaseReachable();

  return NextResponse.json(
    { status: healthy ? "ok" : "unavailable" },
    { status: healthy ? 200 : 503, headers: { "Cache-Control": "no-store" } },
  );
}
