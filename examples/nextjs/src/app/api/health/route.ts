// Usado pelo health check do contêiner. Responde 200 quando o servidor está de pé.
// Se o sistema depende de um banco ou de outra API, confira aqui também: com 503, o deploy
// não troca para a versão nova.
export const dynamic = "force-dynamic";

export function GET() {
  return Response.json({ status: "ok" }, { headers: { "Cache-Control": "no-store" } });
}
