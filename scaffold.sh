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
  --substituir-ci             move um CI antigo (não gerado por este projeto) para .bak
  -i, --interativo            pergunta o que faltar, mesmo com as opções obrigatórias informadas
  --nao-interativo            nunca pergunta: falta de opção obrigatória é erro

Modo interativo: sem as opções obrigatórias e num terminal, o script pergunta o que faltar.
Ele lê o repositório (remoto, branches, package.json, CI existente) para sugerir as respostas,
com listas de escolha, e no fim mostra o comando equivalente:

  bash scaffold.sh

Arquivos gerados: deploy.sh, compose.blue.yml, compose.green.yml, compose.nginx.yml,
nginx/default.conf, nginx/proxy.inc e .github/workflows/deploy.yml (ou .gitlab-ci.yml).
Sem --stack, o Dockerfile, a rota de saúde e a migração (compose.migrate.yml) dependem da
tecnologia do sistema e ficam com você: veja o README.
AJUDA
  exit "${1:-0}"
}

# Vazios até o fim da leitura: o modo interativo só pergunta o que não veio
SISTEMA="" DOMINIO_PROD="" DOMINIO_HML="" PORTA_APP="" HEALTH="" PORTA_HML=""
PROD_NOME="" PROD_BRANCH="" HML_NOME="" HML_BRANCH="" CI="" STACK="" STACK_DEFINIDA=0 DESTINO=""
INTERATIVO=auto SUBSTITUIR_CI=0

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
    --stack) STACK="$2"; STACK_DEFINIDA=1; shift 2 ;;
    --substituir-ci) SUBSTITUIR_CI=1; shift ;;
    -i|--interativo) INTERATIVO=1; shift ;;
    --nao-interativo) INTERATIVO=0; shift ;;
    -h|--help) uso ;;
    --versao|--version) echo "scaffold.sh $VERSAO"; exit 0 ;;
    -*) echo "Opção desconhecida: $1" >&2; uso 1 ;;
    *) DESTINO="$1"; shift ;;
  esac
done

falha() { echo "Erro: $1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Perguntas do modo interativo (leem de /dev/tty). As opções são "valor|texto mostrado".

# perguntar VAR "Pergunta" [padrão] [regex]: sem regex, a resposta é obrigatória
perguntar() {
  local -n __resp_var="$1"
  local texto="$2" padrao="${3:-}" regex="${4:-.}" resp=""
  while true; do
    read -r -p "  $texto${padrao:+ [$padrao]}: " resp </dev/tty || falha "sem resposta para: $texto"
    resp="${resp:-$padrao}"
    [[ "$resp" =~ $regex ]] && break
    echo "    Valor inválido." >/dev/tty
  done
  __resp_var="$resp"
}

# sim_nao "Pergunta" s|n
sim_nao() {
  local resp=""
  read -r -p "  $1 [$([ "$2" = s ] && echo S/n || echo s/N)] " resp </dev/tty || falha "sem resposta para: $1"
  resp="${resp:-$2}"
  [[ "$resp" =~ ^[sS]$ ]]
}

# escolher VAR "Pergunta" N_PADRÃO "valor|texto" ...
escolher() {
  local -n __esc_var="$1"
  local texto="$2" padrao="$3" i=1 op resp
  shift 3
  echo "  $texto" >/dev/tty
  for op in "$@"; do
    printf '    %d) %s\n' "$i" "${op#*|}" >/dev/tty
    i=$((i + 1))
  done
  while true; do
    read -r -p "  Escolha [$padrao]: " resp </dev/tty || falha "sem resposta para: $texto"
    resp="${resp:-$padrao}"
    if [[ "$resp" =~ ^[0-9]+$ ]] && [ "$resp" -ge 1 ] && [ "$resp" -le $# ]; then
      op="${!resp}"
      __esc_var="${op%%|*}"
      return
    fi
    echo "    Digite um número de 1 a $#." >/dev/tty
  done
}

# Opções de branch: as candidatas que existem no repositório, na ordem dada, mais "outra"
escolher_branch() {
  local __destino="$1" texto="$2" existentes="$3" padrao_novo="$4"
  shift 4
  local opcoes=() b escolha
  for b in "$@"; do
    grep -qx "$b" <<<"$existentes" && opcoes+=("$b|$b")
  done
  if [ "${#opcoes[@]}" -eq 0 ]; then
    perguntar "$__destino" "$texto" "$padrao_novo" '^[A-Za-z0-9._/-]+$'
    return
  fi
  opcoes+=("__outra|outra (digitar o nome)")
  escolher escolha "$texto" 1 "${opcoes[@]}"
  if [ "$escolha" = __outra ]; then
    perguntar escolha "Nome da branch" "$padrao_novo" '^[A-Za-z0-9._/-]+$'
  fi
  printf -v "$__destino" '%s' "$escolha"
}

# Repositórios git perto de onde o usuário está: dentro da pasta atual e da de cima, da pasta
# vizinha a este projeto e da home (um nível abaixo de cada uma). Pula pastas ocultas e
# node_modules, e o próprio zero-downtime-deploy. Um caminho absoluto por linha, até 40.
listar_repos() {
  local atual="$1" raiz raizes=()
  for raiz in "$PWD" "$(dirname "$PWD")" "$(dirname "$AQUI")" "$HOME" ${atual:+"$(dirname "$atual")"}; do
    [ -d "$raiz" ] && raizes+=("$(cd "$raiz" && pwd)")
  done
  printf '%s\n' "${raizes[@]}" | sort -u | while IFS= read -r raiz; do
    find "$raiz" -mindepth 1 -maxdepth 2 \( -name node_modules -o \( -name '.*' ! -name .git \) \) -prune \
      -o -name .git -print 2>/dev/null || true  # pasta sem permissão não interrompe a busca
  done | sed 's#/\.git$##' | grep -vxF "$AQUI" | sort -u | head -40
}

# Faltou algo obrigatório e há terminal: pergunta em vez de parar
if [ "$INTERATIVO" = auto ]; then
  if { [ -z "$SISTEMA" ] || [ -z "$DOMINIO_PROD" ] || [ -z "$DOMINIO_HML" ] || [ -z "$DESTINO" ]; } \
    && { : </dev/tty; } 2>/dev/null; then
    INTERATIVO=1
  else
    INTERATIVO=0
  fi
fi

if [ "$INTERATIVO" = 1 ]; then
  { : </dev/tty; } 2>/dev/null || falha "o modo interativo precisa de um terminal"
  echo "scaffold.sh $VERSAO: gera os arquivos de deploy no repositório (Enter aceita o valor entre colchetes)"
  echo

  if [ -z "$DESTINO" ]; then
    atual=""
    if git rev-parse --show-toplevel >/dev/null 2>&1; then atual="$(git rev-parse --show-toplevel)"; fi
    echo "  Procurando repositórios git..." >/dev/tty
    mapfile -t repos < <(listar_repos "$atual")
    if [ "${#repos[@]}" -eq 0 ]; then
      perguntar DESTINO "Pasta do repositório do sistema" "${atual:-.}"
    else
      opcoes=() n=1 i=1
      for r in "${repos[@]}"; do
        rotulo="${r/#$HOME/\~}"
        ramo="$(git -C "$r" symbolic-ref --short -q HEAD 2>/dev/null || true)"
        [ -n "$ramo" ] && rotulo="$rotulo  ($ramo)"
        [ "$r" = "$atual" ] && { rotulo="$rotulo  <- pasta atual"; n=$i; }
        opcoes+=("$r|$rotulo")
        i=$((i + 1))
      done
      opcoes+=("__outra|outra pasta (digitar o caminho)")
      escolher DESTINO "Pasta do repositório do sistema" "$n" "${opcoes[@]}"
      if [ "$DESTINO" = __outra ]; then
        perguntar DESTINO "Caminho do repositório" "${atual:-.}"
      fi
    fi
  fi
  DESTINO="${DESTINO/#\~/$HOME}"
  [ -d "$DESTINO" ] || falha "pasta não encontrada: $DESTINO"

  # O que dá para descobrir no próprio repositório
  remoto="$(git -C "$DESTINO" remote get-url origin 2>/dev/null || true)"
  branches="$(git -C "$DESTINO" for-each-ref --format='%(refname:lstrip=-1)' refs/heads refs/remotes 2>/dev/null \
    | grep -vx HEAD | sort -u || true)"

  if [ -z "$SISTEMA" ]; then
    sugestao="$(basename "${remoto:-$(cd "$DESTINO" && pwd)}" .git | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_]+/_/g')"
    perguntar SISTEMA "Nome do sistema (o mesmo do setup-host.sh; minúsculas, números e _)" "$sugestao" '^[a-z0-9_]+$'
  fi

  if [ -z "$CI" ]; then
    n=1
    [[ "$remoto" == *gitlab* ]] && n=2
    escolher CI "CI do repositório" "$n" \
      "github|GitHub Actions (.github/workflows/deploy.yml)" \
      "gitlab|GitLab CI (.gitlab-ci.yml)"
  fi

  if [ -z "$PROD_BRANCH" ]; then
    escolher_branch PROD_BRANCH "Branch de produção" "$branches" main main master production prod
  fi
  if [ -z "$HML_BRANCH" ]; then
    escolher_branch HML_BRANCH "Branch de homologação" "$branches" dev dev develop developer homolog homologacao staging hml
    if ! grep -qx "$HML_BRANCH" <<<"$branches"; then
      echo "    A branch $HML_BRANCH ainda não existe: crie-a a partir de $PROD_BRANCH (git checkout -b $HML_BRANCH)."
    fi
  fi

  if [ -z "$DOMINIO_PROD" ]; then
    perguntar DOMINIO_PROD "Domínio de produção" "$SISTEMA.saoluis.ma.gov.br" '^[A-Za-z0-9.-]+$'
  fi
  if [ -z "$DOMINIO_HML" ]; then
    escolher tipo "Endereço de homologação (a porta ${PORTA_HML:-3001} da VM sempre atende homologação)" 1 \
      "dominio|domínio próprio (ex.: hml-$DOMINIO_PROD)" \
      "ip|só o IP da VM (http://IP:${PORTA_HML:-3001})"
    if [ "$tipo" = ip ]; then
      perguntar DOMINIO_HML "IP da VM" "" '^[0-9]+(\.[0-9]+){3}$'
    else
      perguntar DOMINIO_HML "Domínio de homologação" "hml-$DOMINIO_PROD" '^[A-Za-z0-9.-]+$'
    fi
  fi

  if [ "$STACK_DEFINIDA" = 0 ]; then
    detectada=""
    if [ -f "$DESTINO/package.json" ] && grep -q '"next"' "$DESTINO/package.json" \
      && grep -q '"prisma"' "$DESTINO/package.json"; then
      detectada=nextjs-prisma
    fi
    opcoes=() n=0 i=1
    for d in "$AQUI"/examples/*/; do
      nome="$(basename "$d")"
      if [ "$nome" = "$detectada" ]; then
        opcoes+=("$nome|$nome (detectada no repositório)")
        n=$i
      else
        opcoes+=("$nome|$nome")
      fi
      i=$((i + 1))
    done
    opcoes+=("|nenhuma (Dockerfile, rota de saúde e migração ficam com você)")
    [ "$n" = 0 ] && n=$i
    escolher STACK "Stack do sistema (copia Dockerfile, migração e rota de saúde prontos)" "$n" "${opcoes[@]}"
  fi

  if sim_nao "Ajustar portas, rota de saúde ou nomes dos ambientes? (padrões: 3000, /api/health, 3001, production, developer)" n; then
    perguntar PORTA_APP "Porta da aplicação dentro do contêiner" "${PORTA_APP:-3000}" '^[0-9]+$'
    perguntar HEALTH "Rota de saúde (200 só com a aplicação pronta, sem login)" "${HEALTH:-/api/health}" '^/'
    perguntar PORTA_HML "Porta de homologação na VM" "${PORTA_HML:-3001}" '^[0-9]+$'
    perguntar PROD_NOME "Nome do ambiente de produção (pasta na VM)" "${PROD_NOME:-production}" '^[a-z0-9_-]+$'
    perguntar HML_NOME "Nome do ambiente de homologação (pasta na VM)" "${HML_NOME:-developer}" '^[a-z0-9_-]+$'
  fi
fi

PORTA_APP="${PORTA_APP:-3000}" HEALTH="${HEALTH:-/api/health}" PORTA_HML="${PORTA_HML:-3001}"
PROD_NOME="${PROD_NOME:-production}" PROD_BRANCH="${PROD_BRANCH:-main}"
HML_NOME="${HML_NOME:-developer}" HML_BRANCH="${HML_BRANCH:-dev}" CI="${CI:-github}"

[ -n "$SISTEMA" ] && [ -n "$DOMINIO_PROD" ] && [ -n "$DOMINIO_HML" ] && [ -n "$DESTINO" ] || uso 1
[[ "$SISTEMA" =~ ^[a-z0-9_]+$ ]] || { echo "--sistema aceita só minúsculas, números e _ (vira nome de contêiner)" >&2; exit 1; }
[[ "$CI" =~ ^(github|gitlab)$ ]] || { echo "--ci aceita github ou gitlab" >&2; exit 1; }
[ -d "$DESTINO" ] || { echo "Pasta não encontrada: $DESTINO" >&2; exit 1; }
[ -d "$AQUI/modelos" ] || { echo "Pasta modelos/ não encontrada ao lado do script" >&2; exit 1; }
if [ -n "$STACK" ] && [ ! -d "$AQUI/examples/$STACK" ]; then
  echo "Stack desconhecida: $STACK. Disponíveis: $(ls "$AQUI/examples" | tr '\n' ' ')" >&2
  exit 1
fi

# CI que já existe e não foi gerado por este projeto (ex.: git pull + pm2 restart)
if [ "$CI" = gitlab ]; then ARQ_CI=.gitlab-ci.yml; else ARQ_CI=.github/workflows/deploy.yml; fi
CI_ANTIGO=0
if [ -f "$DESTINO/$ARQ_CI" ] && ! grep -q zero-downtime-deploy "$DESTINO/$ARQ_CI"; then
  CI_ANTIGO=1
  if [ "$INTERATIVO" = 1 ] && [ "$SUBSTITUIR_CI" = 0 ]; then
    escolher acao "$ARQ_CI já existe e não foi gerado pelo zero-downtime-deploy" 1 \
      "manter|manter (o deploy novo não roda pelo CI até você ajustá-lo)" \
      "substituir|substituir (o atual fica em $ARQ_CI.bak, que o CI não lê)"
    [ "$acao" = substituir ] && SUBSTITUIR_CI=1
  fi
fi

if [ "$INTERATIVO" = 1 ]; then
  cmd="bash scaffold.sh --sistema $SISTEMA --dominio-prod $DOMINIO_PROD --dominio-hml $DOMINIO_HML"
  cmd+=" --prod-branch $PROD_BRANCH --hml-branch $HML_BRANCH --ci $CI"
  if [ -n "$STACK" ]; then cmd+=" --stack $STACK"; fi
  if [ "$PORTA_APP" != 3000 ]; then cmd+=" --porta-app $PORTA_APP"; fi
  if [ "$HEALTH" != /api/health ]; then cmd+=" --health $HEALTH"; fi
  if [ "$PORTA_HML" != 3001 ]; then cmd+=" --porta-hml $PORTA_HML"; fi
  if [ "$PROD_NOME" != production ]; then cmd+=" --prod-nome $PROD_NOME"; fi
  if [ "$HML_NOME" != developer ]; then cmd+=" --hml-nome $HML_NOME"; fi
  if [ "$SUBSTITUIR_CI" = 1 ]; then cmd+=" --substituir-ci"; fi
  printf '\n  Comando equivalente, para repetir sem perguntas:\n    %s %s\n\n' "$cmd" "$DESTINO"
  sim_nao "Gerar os arquivos?" s || { echo "Nada foi alterado."; exit 0; }
fi

if [ "$CI_ANTIGO" = 1 ] && [ "$SUBSTITUIR_CI" = 1 ]; then
  mv "$DESTINO/$ARQ_CI" "$DESTINO/$ARQ_CI.bak"
  echo "  ~ $ARQ_CI antigo movido para $ARQ_CI.bak"
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
