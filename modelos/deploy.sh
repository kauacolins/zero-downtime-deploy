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

# Valor de uma chave do deploy.conf (sem executar nada)
# (sem deploy.conf, vazio: com pipefail, o sed sem arquivo derrubaria o deploy)
ler_conf() { { sed -n "s/^$1=//p" deploy.conf 2>/dev/null || true; } | tail -1 | sed -E "s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/" | tr -d '\r'; }

# Serviços "nome:porta". Monorepo: um por app do APPS do deploy.conf ("nome:pasta:stack:porta:...");
# sem APPS, um só, chamado app. Trocam de cor juntos: front e API sempre na mesma versão.
SERVICOS=()
for a in $(ler_conf APPS); do SERVICOS+=("$(cut -d: -f1 <<<"$a"):$(cut -d: -f4 <<<"$a")"); done
[ "${#SERVICOS[@]}" -gt 0 ] || SERVICOS=("app:$PORTA_APP")

color() {
  local name="$1"
  shift
  docker compose -p "$PROJECT-$name" -f "compose.$name.yml" "$@"
}

case "$(grep -oE '_(blue|green)_[A-Za-z0-9_-]+:' "$ACTIVE" 2>/dev/null | grep -oE 'blue|green' | head -1 || true)" in
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

PREVIOUS=$(cat "$ACTIVE" 2>/dev/null || true)

abort() {
  local s
  echo "$1, abortando"
  for s in "${SERVICOS[@]}"; do
    echo "--- ${APP_PREFIX}${NEXT}_${s%%:*}"
    docker logs --tail 30 "${APP_PREFIX}${NEXT}_${s%%:*}" 2>/dev/null || true
  done
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
  MIGRATE_CMD="$(ler_conf MIGRATE_CMD)"
  if [ -n "$MIGRATE_CMD" ]; then
    echo "[$ENV_NAME] Migração: $MIGRATE_CMD"
    # Monorepo: roda no serviço MIGRATE_APP (ex.: a API); com um app só, no app
    MIGRATE_APP="$(ler_conf MIGRATE_APP)"
    color "$NEXT" run --rm --no-deps -T "${MIGRATE_APP:-${SERVICOS[0]%%:*}}" sh -c "$MIGRATE_CMD" </dev/null       || abort "A migração falhou"
  fi
fi

# {{CRIAR_PASTAS}}
color "$NEXT" up -d

# Todos os serviços da cor nova saudáveis, ou nada muda para o usuário
for s in "${SERVICOS[@]}"; do
  c="${APP_PREFIX}${NEXT}_${s%%:*}"
  STATUS=""
  for _ in $(seq 1 60); do
    STATUS=$(docker inspect -f '{{.State.Health.Status}}' "$c")
    [ "$STATUS" = "healthy" ] || [ "$STATUS" = "unhealthy" ] && break
    sleep 2
  done
  [ "$STATUS" = "healthy" ] || abort "$c não ficou saudável ($STATUS)"
done

# Destino do Nginx: um app só usa $app_upstream; monorepo, um $up_<nome> por serviço
if [ "${#SERVICOS[@]}" = 1 ] && [ "${SERVICOS[0]%%:*}" = app ]; then
  echo "set \$app_upstream ${APP_PREFIX}${NEXT}_app:${SERVICOS[0]#*:};" > "$ACTIVE"
else
  for s in "${SERVICOS[@]}"; do echo "set \$up_${s%%:*} ${APP_PREFIX}${NEXT}_${s%%:*}:${s#*:};"; done > "$ACTIVE"
fi

if [ "$(docker inspect -f '{{.State.Running}}' nginx 2>/dev/null)" = "true" ]; then
  { docker exec nginx nginx -t && docker exec nginx nginx -s reload; } || abort "Falha ao aplicar a configuração do Nginx"
else
  # Porta 80 com outro processo (o sistema antigo, o Nginx da máquina): o CI não o para, de propósito.
  # A troca do sistema antigo pelo novo é pelo setup-host.sh, que compila antes, pergunta e sabe voltar.
  if ss -ltnH '( sport = :80 )' 2>/dev/null | grep -q .; then
    abort "A porta 80 está ocupada por outro processo (o sistema antigo ou o Nginx da máquina?). O primeiro deploy, com um sistema antigo no ar, é pelo setup-host.sh na VM: rode-o, escolha continuar e fazer o primeiro deploy"
  fi
  docker compose -f "$NGINX_COMPOSE" up -d || abort "O Nginx não subiu (veja a mensagem acima)"
fi

if [ -n "$CURRENT" ]; then
  # Deixa terminar o que ainda está em andamento na versão antiga
  sleep 10
  color "$CURRENT" down --remove-orphans
fi

echo "[$ENV_NAME] Deploy concluído: cor $NEXT ativa (${SERVICOS[*]%%:*})"
