#!/usr/bin/env bash
# Sobe a nova versão na cor ociosa, espera ficar saudável e aponta o upstream do Nginx para ela.
set -euo pipefail
cd "$(dirname "$0")"

UPSTREAM=nginx/upstream.conf

case "$(grep -oE 'server (blue|green)_app:3000' "$UPSTREAM" 2>/dev/null | grep -oE 'blue|green' | head -1 || true)" in
  blue) CURRENT=blue; NEXT=green ;;
  green) CURRENT=green; NEXT=blue ;;
  *)
    if [ -s "$UPSTREAM" ]; then
      echo "Conteúdo inesperado em $UPSTREAM"
      exit 1
    fi
    CURRENT=""; NEXT=blue
    ;;
esac

PREVIOUS=$(cat "$UPSTREAM" 2>/dev/null || true)

abort() {
  echo "$1, abortando"
  docker logs --tail 30 "${NEXT}_app" 2>/dev/null || true
  if [ -n "$PREVIOUS" ]; then echo "$PREVIOUS" > "$UPSTREAM"; else rm -f "$UPSTREAM"; fi
  docker compose -f "docker-compose.$NEXT.yml" down
  exit 1
}

echo "Ativo: ${CURRENT:-nenhuma cor} -> subindo $NEXT"
docker network inspect web >/dev/null 2>&1 || docker network create web >/dev/null

# As duas versões usam o mesmo banco durante a troca: a migração precisa servir para ambas
docker compose run --rm --build migrate
docker compose -f "docker-compose.$NEXT.yml" up -d --build

STATUS=""
for _ in $(seq 1 60); do
  STATUS=$(docker inspect -f '{{.State.Health.Status}}' "${NEXT}_app")
  [ "$STATUS" = "healthy" ] || [ "$STATUS" = "unhealthy" ] && break
  sleep 2
done
[ "$STATUS" = "healthy" ] || abort "${NEXT}_app não ficou saudável ($STATUS)"

echo "upstream app { server ${NEXT}_app:3000; }" > "$UPSTREAM"

if [ "$(docker inspect -f '{{.State.Running}}' nginx 2>/dev/null)" = "true" ]; then
  { docker exec nginx nginx -t && docker exec nginx nginx -s reload; } || abort "Falha ao aplicar a configuração do Nginx"
else
  docker compose -f docker-compose.nginx.yml up -d || abort "O Nginx não subiu (a porta 80 está livre?)"
fi

if [ -n "$CURRENT" ]; then
  # Deixa terminar o que ainda está em andamento na versão antiga
  sleep 10
  docker compose -f "docker-compose.$CURRENT.yml" down
fi

echo "Deploy concluído: ${NEXT}_app ativo"
