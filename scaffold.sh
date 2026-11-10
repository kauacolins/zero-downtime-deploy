#!/usr/bin/env bash
# scaffold.sh: copia os arquivos de deploy blue-green da pasta modelos/ para o repositório
# de um sistema, já com os nomes dele. Nunca sobrescreve um arquivo que já existe.
# Ajuda: bash scaffold.sh --help
set -euo pipefail

VERSAO=2.0.0
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

uso() {
  echo "scaffold.sh $VERSAO"
  echo
  cat <<'AJUDA'
Copia os modelos para a raiz do repositório de um sistema (rode na sua máquina, não na VM).

  bash scaffold.sh --sistema siscon \
    --dominio-prod siscon.saoluis.ma.gov.br --dominio-hml hml-siscon.saoluis.ma.gov.br \
    --porta-app 3000 --health /api/health  /caminho/do/repositorio

Opções:
  --sistema NOME              obrigatório; o mesmo usado no setup-host.sh
  --dominio-prod DOMINIO      obrigatório
  --dominio-hml DOMINIO       obrigatório
  --porta-app PORTA           porta da aplicação dentro do contêiner (padrão: 3000)
  --health CAMINHO            rota que responde 200 com a aplicação saudável (padrão: /api/health)
  --porta-hml PORTA           porta de homologação na VM (padrão: 3001)
  --prod-nome / --prod-branch padrão: production / main
  --hml-nome  / --hml-branch  padrão: developer / dev
  --ci github|gitlab          padrão: github
  --stack NOME                copia também os arquivos de examples/NOME (ex.: nextjs-prisma):
                              Dockerfile, .dockerignore, migração, rota de saúde, .env.example

Arquivos gerados: deploy.sh, compose.blue.yml, compose.green.yml, compose.nginx.yml,
nginx/default.conf, nginx/proxy.inc e .github/workflows/deploy.yml (ou .gitlab-ci.yml).
Sem --stack, o Dockerfile, a rota de saúde e a migração (compose.migrate.yml) dependem da
tecnologia do sistema e ficam com você: veja o README.
AJUDA
  exit "${1:-0}"
}

SISTEMA="" DOMINIO_PROD="" DOMINIO_HML="" PORTA_APP=3000 HEALTH=/api/health PORTA_HML=3001
PROD_NOME=production PROD_BRANCH=main HML_NOME=developer HML_BRANCH=dev CI=github STACK="" DESTINO=""

while [ $# -gt 0 ]; do
  case "$1" in
    --sistema) SISTEMA="$2"; shift 2 ;;
    --dominio-prod) DOMINIO_PROD="$2"; shift 2 ;;
    --dominio-hml) DOMINIO_HML="$2"; shift 2 ;;
    --porta-app) PORTA_APP="$2"; shift 2 ;;
    --health) HEALTH="$2"; shift 2 ;;
    --porta-hml) PORTA_HML="$2"; shift 2 ;;
    --prod-nome) PROD_NOME="$2"; shift 2 ;;
    --prod-branch) PROD_BRANCH="$2"; shift 2 ;;
    --hml-nome) HML_NOME="$2"; shift 2 ;;
    --hml-branch) HML_BRANCH="$2"; shift 2 ;;
    --ci) CI="$2"; shift 2 ;;
    --stack) STACK="$2"; shift 2 ;;
    -h|--help) uso ;;
    --versao|--version) echo "scaffold.sh $VERSAO"; exit 0 ;;
    -*) echo "Opção desconhecida: $1" >&2; uso 1 ;;
    *) DESTINO="$1"; shift ;;
  esac
done

[ -n "$SISTEMA" ] && [ -n "$DOMINIO_PROD" ] && [ -n "$DOMINIO_HML" ] && [ -n "$DESTINO" ] || uso 1
[[ "$SISTEMA" =~ ^[a-z0-9_]+$ ]] || { echo "--sistema aceita só minúsculas, números e _ (vira nome de contêiner)" >&2; exit 1; }
[[ "$CI" =~ ^(github|gitlab)$ ]] || { echo "--ci aceita github ou gitlab" >&2; exit 1; }
[ -d "$DESTINO" ] || { echo "Pasta não encontrada: $DESTINO" >&2; exit 1; }
[ -d "$AQUI/modelos" ] || { echo "Pasta modelos/ não encontrada ao lado do script" >&2; exit 1; }
if [ -n "$STACK" ] && [ ! -d "$AQUI/examples/$STACK" ]; then
  echo "Stack desconhecida: $STACK. Disponíveis: $(ls "$AQUI/examples" | tr '\n' ' ')" >&2
  exit 1
fi

# Troca só os marcadores conhecidos: as expressões {{ ... }} do GitHub e do Docker ficam intactas
preencher() {
  sed -e "s|{{SISTEMA}}|$SISTEMA|g" \
      -e "s|{{DOMINIO_PROD}}|$DOMINIO_PROD|g" \
      -e "s|{{DOMINIO_HML}}|$DOMINIO_HML|g" \
      -e "s|{{PORTA_APP}}|$PORTA_APP|g" \
      -e "s|{{HEALTH}}|$HEALTH|g" \
      -e "s|{{PORTA_HML}}|$PORTA_HML|g" \
      -e "s|{{PROD_NOME}}|$PROD_NOME|g" \
      -e "s|{{PROD_BRANCH}}|$PROD_BRANCH|g" \
      -e "s|{{HML_NOME}}|$HML_NOME|g" \
      -e "s|{{HML_BRANCH}}|$HML_BRANCH|g" \
      -e "s|{{COR}}|${COR:-}|g"
}

gerar() {
  local origem="$1" destino="$DESTINO/$2"
  if [ -e "$destino" ]; then
    echo "  = $2 já existe, mantido"
    return
  fi
  mkdir -p "$(dirname "$destino")"
  preencher < "$AQUI/modelos/$origem" > "$destino"
  echo "  + $2"
}

echo "Gerando em $DESTINO:"
gerar deploy.sh deploy.sh
chmod +x "$DESTINO/deploy.sh" 2>/dev/null || true
COR=blue gerar compose.cor.yml compose.blue.yml
COR=green gerar compose.cor.yml compose.green.yml
gerar compose.nginx.yml compose.nginx.yml
gerar nginx/default.conf nginx/default.conf
gerar nginx/proxy.inc nginx/proxy.inc
if [ "$CI" = gitlab ]; then
  gerar gitlab-ci.yml .gitlab-ci.yml
else
  gerar github-deploy.yml .github/workflows/deploy.yml
fi

# Arquivos da stack: copiados como estão, sem sobrescrever
if [ -n "$STACK" ]; then
  echo "Stack $STACK:"
  ex="$AQUI/examples/$STACK"
  while IFS= read -r arquivo; do
    rel="${arquivo#"$ex"/}"
    case "$rel" in
      README.md) continue ;;
      gitignore)
        # Linhas que faltam no .gitignore do sistema
        touch "$DESTINO/.gitignore"
        while IFS= read -r linha; do
          [[ -z "$linha" || "$linha" == \#* ]] && continue
          grep -qxF "$linha" "$DESTINO/.gitignore" || { echo "$linha" >> "$DESTINO/.gitignore"; echo "  + .gitignore: $linha"; }
        done < "$arquivo"
        continue
        ;;
    esac
    if [ -e "$DESTINO/$rel" ]; then
      echo "  = $rel já existe, mantido"
    else
      mkdir -p "$(dirname "$DESTINO/$rel")"
      cp "$arquivo" "$DESTINO/$rel"
      echo "  + $rel"
    fi
  done < <(find "$ex" -type f | sort)
fi

# Marcador esquecido em algum modelo
if grep -rnoE '\{\{[A-Z_]+\}\}' "$DESTINO"/deploy.sh "$DESTINO"/compose.*.yml "$DESTINO"/nginx 2>/dev/null; then
  echo "Atenção: sobraram marcadores acima sem valor" >&2
fi

echo
echo "Falta fazer no repositório:"
if [ -z "$STACK" ]; then
  cat <<EOF
  - Dockerfile, se ainda não houver
  - a rota $HEALTH, respondendo 200 só com a aplicação pronta (e sem exigir login)
  - compose.migrate.yml, se o sistema tiver migração de banco (veja o README)
  - .env.example com as variáveis do sistema
EOF
else
  echo "  - revisar os arquivos copiados de examples/$STACK (veja o README da stack)"
fi
echo '  - os testes no job "test" do CI'
