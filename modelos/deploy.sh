#!/usr/bin/env bash
# Sobe a nova versão na cor livre do ambiente, espera ficar saudável e aponta o Nginx para ela.
# Uso: bash deploy.sh {{PROD_NOME}}|{{HML_NOME}}
# Gerado pelo zero-downtime-deploy (modelos/deploy.sh); ajuste à vontade.
set -euo pipefail
cd "$(dirname "$0")"

SISTEMA={{SISTEMA}}
PORTA_APP={{PORTA_APP}}
ATIVOS=/opt/{{SISTEMA}}/nginx
NGINX_COMPOSE=/opt/{{SISTEMA}}/{{PROD_NOME}}/compose.nginx.yml

ENV_NAME="${1:-}"
case "$ENV_NAME" in
  {{PROD_NOME}}) PROJECT="$SISTEMA"; export APP_PREFIX="${SISTEMA}_" ;;
  {{HML_NOME}}) PROJECT="$SISTEMA-hml"; export APP_PREFIX="${SISTEMA}_hml_" ;;
  *)
    echo "Uso: bash deploy.sh {{PROD_NOME}}|{{HML_NOME}}"
    exit 1
    ;;
esac

if [ "$(basename "$PWD")" != "$ENV_NAME" ]; then
  echo "Esta pasta ($PWD) não é do ambiente $ENV_NAME"
  exit 1
fi
[ -f .env ] || { echo "Falta o .env desta pasta"; exit 1; }

# Um .env trocado entre os ambientes levaria a migração para o banco errado.
# Convenção: o banco de homologação termina em _hml.
for var in DATABASE_URL DIRECT_URL POSTGRES_DB DB_NAME; do
  valor="$(grep -E "^$var=" .env | head -1 | cut -d= -f2- | tr -d "\"'" || true)"
  [ -n "$valor" ] || continue
  if [[ "$valor" =~ _hml([?/[:space:]]|$) ]]; then banco=hml; else banco=prod; fi
  if [ "$ENV_NAME" = {{HML_NOME}} ] && [ "$banco" = prod ]; then
    echo "$var não aponta para um banco *_hml, mas o ambiente é de homologação"
    exit 1
  fi
  if [ "$ENV_NAME" = {{PROD_NOME}} ] && [ "$banco" = hml ]; then
    echo "$var aponta para um banco de homologação, mas o ambiente é de produção"
    exit 1
  fi
done

mkdir -p "$ATIVOS"
ACTIVE="$ATIVOS/$ENV_NAME.inc"

color() {
  local name="$1"
  shift
  docker compose -p "$PROJECT-$name" -f "compose.$name.yml" "$@"
}

case "$(grep -oE '(blue|green)_app:' "$ACTIVE" 2>/dev/null | grep -oE 'blue|green' | head -1 || true)" in
  blue) CURRENT=blue; NEXT=green ;;
  green) CURRENT=green; NEXT=blue ;;
  *)
    if [ -s "$ACTIVE" ]; then
      echo "Conteúdo inesperado em $ACTIVE"
      exit 1
    fi
    CURRENT=""; NEXT=blue
    ;;
esac

NEXT_APP="${APP_PREFIX}${NEXT}_app"
PREVIOUS=$(cat "$ACTIVE" 2>/dev/null || true)

abort() {
  echo "$1, abortando"
  docker logs --tail 30 "$NEXT_APP" 2>/dev/null || true
  if [ -n "$PREVIOUS" ]; then echo "$PREVIOUS" > "$ACTIVE"; else rm -f "$ACTIVE"; fi
  color "$NEXT" down --remove-orphans
  exit 1
}

echo "[$ENV_NAME] Ativo: ${CURRENT:-nenhuma cor} -> subindo $NEXT"
docker network inspect web >/dev/null 2>&1 || docker network create web >/dev/null

# Compila antes de migrar: um erro de build não pode deixar o banco à frente da versão no ar
color "$NEXT" build

# Migração opcional. As duas versões usam o mesmo banco durante a troca: ela precisa servir para ambas
if [ -f compose.migrate.yml ]; then
  docker compose -p "$PROJECT-migrate" -f compose.migrate.yml run --rm --build migrate
else
  # Sem compose.migrate.yml: o MIGRATE_CMD do deploy.conf roda na imagem nova, com o .env do ambiente
  MIGRATE_CMD="$(sed -n 's/^MIGRATE_CMD=//p' deploy.conf 2>/dev/null | tail -1 | sed -E "s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/" | tr -d '\r')"
  if [ -n "$MIGRATE_CMD" ]; then
    echo "[$ENV_NAME] Migração: $MIGRATE_CMD"
    color "$NEXT" run --rm --no-deps -T app sh -c "$MIGRATE_CMD" </dev/null || abort "A migração falhou"
  fi
fi

# {{CRIAR_PASTAS}}
color "$NEXT" up -d

STATUS=""
for _ in $(seq 1 60); do
  STATUS=$(docker inspect -f '{{.State.Health.Status}}' "$NEXT_APP")
  [ "$STATUS" = "healthy" ] || [ "$STATUS" = "unhealthy" ] && break
  sleep 2
done
[ "$STATUS" = "healthy" ] || abort "$NEXT_APP não ficou saudável ($STATUS)"

echo "set \$app_upstream ${NEXT_APP}:${PORTA_APP};" > "$ACTIVE"

if [ "$(docker inspect -f '{{.State.Running}}' nginx 2>/dev/null)" = "true" ]; then
  { docker exec nginx nginx -t && docker exec nginx nginx -s reload; } || abort "Falha ao aplicar a configuração do Nginx"
else
  docker compose -f "$NGINX_COMPOSE" up -d || abort "O Nginx não subiu (a porta 80 está livre?)"
fi

if [ -n "$CURRENT" ]; then
  # Deixa terminar o que ainda está em andamento na versão antiga
  sleep 10
  color "$CURRENT" down --remove-orphans
fi

echo "[$ENV_NAME] Deploy concluído: $NEXT_APP ativo"
