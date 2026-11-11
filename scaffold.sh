#!/usr/bin/env bash
# scaffold.sh: copia os arquivos de deploy blue-green da pasta modelos/ para o repositório
# de um sistema, já com os nomes dele. Nunca sobrescreve um arquivo que já existe.
# Ajuda: bash scaffold.sh --help
set -euo pipefail

# Tudo entre { e } é lido antes de rodar. Pelo curl ... | bash, o bash lê o script pela entrada
# padrão aos poucos, e um comando do meio que lesse a entrada comeria o resto do script.
{

VERSAO=2.0.0
# Pela entrada padrão (curl ... | bash) não há BASH_SOURCE: vale a pasta atual, e os modelos são baixados
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)"

uso() {
  echo "scaffold.sh $VERSAO"
  echo
  cat <<'AJUDA'
Copia os modelos para a raiz do repositório de um sistema (rode na sua máquina, não na VM).

  bash scaffold.sh --system siscon \
    --prod-domain siscon.saoluis.ma.gov.br --staging-domain hml-siscon.saoluis.ma.gov.br \
    --app-port 3000 --health /api/health  /caminho/do/repositorio

Opções:
  --system NOME               obrigatório; o mesmo usado no setup-host.sh
  --prod-domain DOMINIO       obrigatório
  --staging-domain DOMINIO    obrigatório, a não ser com --no-staging
  --no-staging                só produção: sem o ambiente de homologação (nem porta 3001, nem
                              branch, nem job de deploy dele)
  --app-port PORTA            porta da aplicação dentro do contêiner (padrão: 3000)
  --health CAMINHO            rota que responde 200 com a aplicação saudável (padrão: /api/health)
  --staging-port PORTA        porta de homologação na VM (padrão: 3001)
  --prod-name / --prod-branch
                              padrão: production / main
  --staging-name / --staging-branch
                              padrão: developer / dev
  --ci github|gitlab          padrão: github
  --stack NOME                copia também os arquivos de examples/NOME: nextjs-prisma, nextjs,
                              node, spa (Vite) ou dockerfile (o Dockerfile do próprio sistema).
                              Sem a opção, o script detecta a stack pelo repositório
  --migrate-cmd "COMANDO"     migração do banco, rodada na imagem nova antes da troca (ex.:
                              "php artisan migrate --force"); a stack nextjs-prisma já tem a sua
  --upgrade                   gera de novo os arquivos de deploy (os que têm "Gerado pelo
                              zero-downtime-deploy") a partir do deploy.conf do repositório
  --replace-ci                desativa os pipelines de deploy antigos (PM2, ssh, git pull...):
                              vão para .bak, que o CI não lê
  --force-dynamic             stack Next.js: acrescenta export const dynamic = "force-dynamic"
                              às páginas que consultam o banco e seriam pré-renderizadas no build
  --check-build               no fim, valida com docker build (precisa de Docker); no modo
                              interativo, pergunta. --no-check-build não pergunta
  --volume PASTA              pasta onde a aplicação grava arquivos (ex.: public/uploads), montada
                              fora do contêiner para não se perder no deploy; repita para várias.
                              Sem --volume, o script procura no código (padrão: uploads)
  --no-volume                 nenhuma pasta montada
  --copy PASTA                pasta lida em tempo de execução (ex.: data), copiada para a imagem
                              (stack Next.js); sem a opção, o script procura no código
  --upload-limit TAMANHO      maior envio aceito pelo Nginx (padrão: 25m)
  --prod-ip IP                o IP da VM na porta 80 abre a produção (padrão: acesso por IP recusado)
  --runner-tag TAG            tag do runner da VM no GitLab (padrão: o nome do sistema)
  -i, --interactive           pergunta o que faltar, mesmo com as opções obrigatórias informadas
  --non-interactive           nunca pergunta: falta de opção obrigatória é erro

Modo interativo: sem as opções obrigatórias e num terminal, o script pergunta o que faltar.
Ele lê o repositório (remoto, branches, package.json, CI existente) para sugerir as respostas,
com listas de escolha, e no fim mostra o comando equivalente:

  bash scaffold.sh

Sem o repositório zero-downtime-deploy na máquina, pelo curl (baixa os modelos para uma pasta
temporária, apagada no fim; ZDD_REF escolhe a versão, ex.: ZDD_REF=v2.0.0):

  bash <(curl -fsSL https://raw.githubusercontent.com/kauacolins/zero-downtime-deploy/master/scaffold.sh)

As respostas ficam no deploy.conf do repositório, que vai para o git: rodando de novo, o script
não pergunta o que já está lá. Para atualizar os arquivos de deploy depois de mudar o deploy.conf
ou de uma versão nova deste projeto: bash scaffold.sh --upgrade.

O script também lê o código: variáveis NEXT_PUBLIC_* viram argumentos de build, as usadas no
código e ausentes do .env.example entram nele, o job de teste sai do package.json e, na stack
Next.js, o next.config ganha output: "standalone" se faltar.

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
SEM_HML=0 SEM_HML_DEF=0
INTERATIVO=auto SUBSTITUIR_CI=0 FORCE_DYNAMIC=0 CHECK_BUILD=""
MIGRATE_CMD="" MIGRATE_DEF=0 UPGRADE=0 BUILD_ARGS_CONF=() BUILD_ARGS_DEF=0 CONF_LIDO=0
# Da stack escolhida (examples/<stack>/stack.conf)
STACK_NEXTJS=0 STACK_PREFIXO="" STACK_VOLUMES_PADRAO=uploads STACK_APP_PORT="" STACK_HEALTH=""
STACK_PERGUNTAR_APP=0 STACK_PERGUNTAR_MIGRACAO=0 STACK_HEALTH_PROPRIA=0
VOLUMES=() VOLUMES_DEF=0 COPIAR=() COPIAR_DEF=0 LIMITE_UPLOAD="" IP_PROD="" TAG_RUNNER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --system|--sistema) SISTEMA="$2"; shift 2 ;;
    --prod-domain|--dominio-prod) DOMINIO_PROD="$2"; shift 2 ;;
    --staging-domain|--dominio-hml) DOMINIO_HML="$2"; shift 2 ;;
    --app-port|--porta-app) PORTA_APP="$2"; shift 2 ;;
    --health) HEALTH="$2"; shift 2 ;;
    --staging-port|--porta-hml) PORTA_HML="$2"; shift 2 ;;
    --prod-name|--prod-nome) PROD_NOME="$2"; shift 2 ;;
    --prod-branch) PROD_BRANCH="$2"; shift 2 ;;
    --staging-name|--hml-nome) HML_NOME="$2"; shift 2 ;;
    --staging-branch|--hml-branch) HML_BRANCH="$2"; shift 2 ;;
    --no-staging|--sem-homologacao) SEM_HML=1; SEM_HML_DEF=1; shift ;;
    --ci) CI="$2"; shift 2 ;;
    --stack) STACK="$2"; STACK_DEFINIDA=1; shift 2 ;;
    --replace-ci|--substituir-ci) SUBSTITUIR_CI=1; shift ;;
    --force-dynamic) FORCE_DYNAMIC=1; shift ;;
    --migrate-cmd) MIGRATE_CMD="$2"; MIGRATE_DEF=1; shift 2 ;;
    --upgrade) UPGRADE=1; shift ;;
    --check-build) CHECK_BUILD=1; shift ;;
    --no-check-build) CHECK_BUILD=0; shift ;;
    --volume) VOLUMES+=("$2"); VOLUMES_DEF=1; shift 2 ;;
    --no-volume|--sem-volume) VOLUMES=(); VOLUMES_DEF=1; shift ;;
    --copy|--copiar) COPIAR+=("$2"); COPIAR_DEF=1; shift 2 ;;
    --upload-limit|--limite-upload) LIMITE_UPLOAD="$2"; shift 2 ;;
    --prod-ip|--ip-prod) IP_PROD="$2"; shift 2 ;;
    --runner-tag|--tag-runner) TAG_RUNNER="$2"; shift 2 ;;
    -i|--interactive|--interativo) INTERATIVO=1; shift ;;
    --non-interactive|--nao-interativo) INTERATIVO=0; shift ;;
    -h|--help) uso ;;
    --versao|--version) echo "scaffold.sh $VERSAO"; exit 0 ;;
    -*) echo "Opção desconhecida: $1" >&2; uso 1 ;;
    *) DESTINO="$1"; shift ;;
  esac
done

# ---------------------------------------------------------------------------
# Visual: cores só num terminal (NO_COLOR desliga); ícones Unicode só com locale UTF-8
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
  NEGRITO=$'\033[1m' FRACO=$'\033[2m' VERMELHO=$'\033[31m' VERDE=$'\033[32m'
  AMARELO=$'\033[33m' AZUL=$'\033[34m' CIANO=$'\033[36m' RESET=$'\033[0m'
else
  NEGRITO="" FRACO="" VERMELHO="" VERDE="" AMARELO="" AZUL="" CIANO="" RESET=""
fi
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}} $(locale charmap 2>/dev/null || true)" in
  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*)
    I_OK="✔" I_AVISO="⚠" I_ERRO="✖" I_SETA="❯" I_ETAPA="▸" I_LOGO="◆" I_INFO="ℹ"
    I_MARCADO="◉" I_VAZIO="○" I_ITEM="•" I_NOVO="+" I_MANTIDO="=" I_MOVIDO="↪" I_GIRO="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏" ;;
  *)
    I_OK="v" I_AVISO="!" I_ERRO="x" I_SETA=">" I_ETAPA="==>" I_LOGO="*" I_INFO="i"
    I_MARCADO="x" I_VAZIO=" " I_ITEM="-" I_NOVO="+" I_MANTIDO="=" I_MOVIDO="~" I_GIRO='|/-\' ;;
esac

# Cabeçalho do modo interativo
banner() {
  printf '\n  %s%s %s%s  %s%s%s\n' "$NEGRITO$AZUL" "$I_LOGO" "$1" "$RESET" "$FRACO" "$2" "$RESET" >/dev/tty
  printf '  %sEnter aceita a sugestão entre colchetes · Ctrl+C cancela%s\n' "$FRACO" "$RESET" >/dev/tty
}

# "? Pergunta [padrão] ❯ "
rotulo_pergunta() {
  printf '  %s?%s %s%s%s%s %s%s%s ' "$CIANO" "$RESET" "$NEGRITO" "$1" "$RESET" \
    "${2:+ $FRACO[$2]$RESET}" "$CIANO" "$I_SETA" "$RESET"
}
erro_entrada() { printf '    %s%s %s%s\n' "$VERMELHO" "$I_ERRO" "$1" "$RESET" >/dev/tty; }
escolhido() { printf '    %s%s%s %s%s%s\n' "$VERDE" "$I_OK" "$RESET" "$FRACO" "$1" "$RESET" >/dev/tty; }

falha() { printf '%s%s Erro:%s %s\n' "$VERMELHO" "$I_ERRO" "$RESET" "$1" >&2; exit 1; }

# Pelo curl, sem o repositório ao lado do script: baixa modelos/ e examples/ da mesma versão
# (ZDD_REF: branch ou tag, padrão master) para uma pasta temporária, apagada no fim
BAIXADO="" CHAMADA="bash scaffold.sh" PROJETO_PAI="$(dirname "$AQUI")"
if [ ! -d "$AQUI/modelos" ]; then
  BAIXADO="$(mktemp -d)" PROJETO_PAI=""
  trap 'rm -rf "$BAIXADO"' EXIT
  printf '  %s%s Baixando os modelos do zero-downtime-deploy (%s)...%s\n' "$FRACO" "$I_INFO" "${ZDD_REF:-master}" "$RESET" >&2
  curl -fsSL "https://codeload.github.com/kauacolins/zero-downtime-deploy/tar.gz/${ZDD_REF:-master}" \
    | tar -xz -C "$BAIXADO" --strip-components=1 \
    || falha "não consegui baixar os modelos do GitHub (versão ${ZDD_REF:-master})"
  [ -d "$BAIXADO/modelos" ] || falha "o pacote baixado não tem a pasta modelos/"
  AQUI="$BAIXADO"
  CHAMADA="bash <(curl -fsSL https://raw.githubusercontent.com/kauacolins/zero-downtime-deploy/${ZDD_REF:-master}/scaffold.sh)"
fi

# Roda FUNÇÃO com um indicador de progresso; a saída vai para o arquivo SAIDA
com_espera() {
  local saida="$1" msg="$2" pid i=0
  shift 2
  "$@" >"$saida" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s%s%s %s' "$CIANO" "${I_GIRO:i++%${#I_GIRO}:1}" "$RESET" "$msg" >/dev/tty
    sleep 0.1
  done
  wait "$pid" || true
  printf '\r%*s\r' $((${#msg} + 6)) '' >/dev/tty
}

# ---------------------------------------------------------------------------
# Perguntas do modo interativo (leem de /dev/tty). As opções são "valor|texto mostrado".

# perguntar VAR "Pergunta" [padrão] [regex]: sem regex, a resposta é obrigatória
perguntar() {
  local -n __resp_var="$1"
  local texto="$2" padrao="${3:-}" regex="${4:-.}" resp=""
  while true; do
    read -r -p "$(rotulo_pergunta "$texto" "$padrao")" resp </dev/tty || falha "sem resposta para: $texto"
    resp="${resp:-$padrao}"
    [[ "$resp" =~ $regex ]] && break
    erro_entrada "Valor inválido."
  done
  __resp_var="$resp"
}

# sim_nao "Pergunta" s|n
sim_nao() {
  local resp=""
  while true; do
    read -r -p "$(rotulo_pergunta "$1" "$([ "$2" = s ] && echo S/n || echo s/N)")" resp </dev/tty \
      || falha "sem resposta para: $1"
    resp="${resp:-$2}"
    case "$resp" in
      [sS]|[sS][iI][mM]) return 0 ;;
      [nN]|[nN][aAãÃ][oO]) return 1 ;;
    esac
    erro_entrada "Responda s ou n."
  done
}

# escolher VAR "Pergunta" N_PADRÃO "valor|texto" ...: uma opção, pelo número
escolher() {
  local -n __esc_var="$1"
  local texto="$2" padrao="$3" i=1 op resp
  shift 3
  printf '  %s?%s %s%s%s\n' "$CIANO" "$RESET" "$NEGRITO" "$texto" "$RESET" >/dev/tty
  for op in "$@"; do
    if [ "$i" = "$padrao" ]; then
      printf '  %s%s %2d)%s %s\n' "$CIANO" "$I_SETA" "$i" "$RESET" "${op#*|}" >/dev/tty
    else
      printf '    %s%2d)%s %s\n' "$FRACO" "$i" "$RESET" "${op#*|}" >/dev/tty
    fi
    i=$((i + 1))
  done
  while true; do
    read -r -p "    Escolha $FRACO[$padrao]$RESET $CIANO$I_SETA$RESET " resp </dev/tty || falha "sem resposta para: $texto"
    resp="${resp:-$padrao}"
    if [[ "$resp" =~ ^[0-9]+$ ]] && [ "$resp" -ge 1 ] && [ "$resp" -le $# ]; then
      op="${!resp}"
      __esc_var="${op%%|*}"
      [[ "$__esc_var" == __* ]] || escolhido "${op#*|}"  # "outra": a próxima pergunta já mostra
      return
    fi
    erro_entrada "Digite um número de 1 a $#."
  done
}

# escolher_varios ARRAY "Pergunta" "NÚMEROS MARCADOS" "valor|texto" ...: várias opções
escolher_varios() {
  local -n __varios_var="$1"
  local texto="$2" padrao="$3" i=1 op resp n valido nomes
  shift 3
  printf '  %s?%s %s%s%s\n' "$CIANO" "$RESET" "$NEGRITO" "$texto" "$RESET" >/dev/tty
  for op in "$@"; do
    if [[ " $padrao " == *" $i "* ]]; then
      printf '    %s%s%s %s%2d)%s %s\n' "$VERDE" "$I_MARCADO" "$RESET" "$FRACO" "$i" "$RESET" "${op#*|}" >/dev/tty
    else
      printf '    %s%s %2d)%s %s\n' "$FRACO" "$I_VAZIO" "$i" "$RESET" "${op#*|}" >/dev/tty
    fi
    i=$((i + 1))
  done
  while true; do
    read -r -p "    Números separados por espaço $FRACO(Enter: os marcados $I_MARCADO · 0: nenhum)$RESET $CIANO$I_SETA$RESET " resp </dev/tty \
      || falha "sem resposta para: $texto"
    resp="${resp:-$padrao}"
    __varios_var=()
    nomes=""
    valido=1
    for n in ${resp//,/ }; do
      if [ "$n" = 0 ]; then
        __varios_var=()
        nomes=""
        break
      elif [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $# ]; then
        op="${!n}"
        __varios_var+=("${op%%|*}")
        nomes+="${nomes:+, }${op#*|}"
      else
        valido=0
      fi
    done
    if [ "$valido" = 1 ]; then
      escolhido "${nomes:-nenhum}"
      return
    fi
    erro_entrada "Use números de 1 a $#."

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
  for raiz in "$PWD" "$(dirname "$PWD")" ${PROJETO_PAI:+"$PROJETO_PAI"} "$HOME" ${atual:+"$(dirname "$atual")"}; do
    [ -d "$raiz" ] && raizes+=("$(cd "$raiz" && pwd)")
  done
  printf '%s\n' "${raizes[@]}" | sort -u | while IFS= read -r raiz; do
    find "$raiz" -mindepth 1 -maxdepth 2 \( -name node_modules -o \( -name '.*' ! -name .git \) \) -prune \
      -o -name .git -print 2>/dev/null || true  # pasta sem permissão não interrompe a busca
  done | sed 's#/\.git$##' | grep -vxF "$AQUI" | sort -u | head -40
}

# ---------------------------------------------------------------------------
# Leitura do código do sistema: pastas de upload, pastas lidas em tempo de execução e variáveis
NL=$'\n'
Q="[\"'\`]"  # aspas de string em JS/TS
FONTES="" CODIGO=""
trap 'rm -f "$FONTES" "$CODIGO"; [ -z "$BAIXADO" ] || rm -rf "$BAIXADO"' EXIT

# Arquivos de código, sem dependências, saída de build nem testes
listar_fontes() {
  find "$DESTINO" \( -name node_modules -o -name .next -o -name .git -o -name dist -o -name build \
      -o -name coverage -o -name out -o -name graphify-out \) -prune -o -type f \
    \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.mjs' -o -name '*.cjs' \) \
    ! -name '*.d.ts' ! -name '*.test.*' ! -name '*.spec.*' -print 2>/dev/null || true
}
# grep no código todo, juntado num arquivo só ($CODIGO): uma busca por vez em todos os
# arquivos custaria segundos no Windows. Nunca falha.
grep_fontes() { grep "$@" "$CODIGO" 2>/dev/null || true; }
tem_no_codigo() { grep -qE "$1" "$CODIGO" 2>/dev/null; }

# Pastas onde a aplicação grava: existem no repositório ou aparecem no código como caminho
detectar_volumes() {
  local c
  for c in public/uploads public/arquivos uploads storage arquivos documentos; do
    if [[ "$c" == */* ]]; then
      if [ -d "$DESTINO/$c" ] || tem_no_codigo "$Q(\./|/)?$c($Q|/)|$Q${c%%/*}$Q *, *$Q${c#*/}$Q"; then echo "$c"; fi
    elif [ -d "$DESTINO/$c" ]; then
      echo "$c"
    # "uploads" dentro de public/uploads já foi contada acima
    elif tem_no_codigo "$Q(\./)?$c($Q|/)" && ! tem_no_codigo "${Q}public/$c|${Q}public$Q *, *$Q$c$Q"; then
      echo "$c"
    fi
  done
}

# Pastas da raiz lidas em tempo de execução (ex.: data/): o build standalone do Next não as copia
IGNORAR_COPIAR=" src app pages lib components public prisma node_modules tests test __tests__ e2e coverage scripts docs nginx volume volumes logs graphify-out dist build out types styles hooks utils services "
detectar_copiar() {
  local d nome v
  for d in "$DESTINO"/*/; do
    [ -d "$d" ] || continue
    nome="$(basename "$d")"
    [[ "$IGNORAR_COPIAR" == *" $nome "* ]] && continue
    for v in "${VOLUMES[@]}"; do [ "${v%%/*}" = "$nome" ] && continue 2; done
    if tem_no_codigo "$Q(\./|/)?$nome/|cwd\(\) *, *$Q$nome$Q"; then echo "$nome"; fi
  done
}

# Variáveis lidas pelo código (process.env.X), menos as que o ambiente já define
ENV_IGNORAR=" NODE_ENV PORT HOSTNAME NEXT_RUNTIME NEXT_PHASE NEXT_TELEMETRY_DISABLED CI TZ HOME PWD PATH JEST_WORKER_ID "
detectar_env() {
  grep_fontes -hoE "(process|import\.meta)\.env\.[A-Z_][A-Z0-9_]*|process\.env\[$Q[A-Z_][A-Z0-9_]*$Q\]" \
    | sed -E 's/^(process|import\.meta)\.env(\.|\[.)//; s/[^A-Z0-9_].*$//' | sort -u \
    | while IFS= read -r v; do
        [[ "$ENV_IGNORAR" == *" $v "* || "$v" == VERCEL* || "$v" == npm_* ]] || echo "$v"
      done
}

analisar_repositorio() {
  FONTES="$(mktemp)" CODIGO="$(mktemp)"
  listar_fontes >"$FONTES"
  if [ -s "$FONTES" ]; then tr '\n' '\0' <"$FONTES" | xargs -0 cat >"$CODIGO" 2>/dev/null || true; fi
  IS_NEXT=0
  if [ -f "$DESTINO/package.json" ] && grep -q '"next"' "$DESTINO/package.json"; then IS_NEXT=1; fi
  mapfile -t DET_VOLUMES < <(detectar_volumes)
  NEXT_PUBLIC=()
  prefixo="$STACK_PREFIXO"
  if [ -z "$prefixo" ] && [ "$IS_NEXT" = 1 ]; then prefixo=NEXT_PUBLIC_; fi
  if [ "$BUILD_ARGS_DEF" = 1 ]; then
    NEXT_PUBLIC=("${BUILD_ARGS_CONF[@]}")
  elif [ -n "$prefixo" ]; then
    mapfile -t NEXT_PUBLIC < <(grep_fontes -hoE "${prefixo}[A-Z0-9_]+" | sort -u)
  fi
  mapfile -t ENV_CODIGO < <(detectar_env)
}

# Opções para escolher_varios, todas marcadas: define OPCOES e MARCADOS
todas_marcadas() {
  local v i=1
  OPCOES=() MARCADOS=""
  for v in "$@"; do OPCOES+=("$v|$v"); MARCADOS+="${MARCADOS:+ }$i"; i=$((i + 1)); done
}

# ---------------------------------------------------------------------------
# Pipeline de deploy antigo (ex.: git pull + pm2 restart por ssh)

# Por que um arquivo de CI parece deploy antigo: os motivos, separados por vírgula (vazio: não parece)
motivos_deploy() {
  local m=()
  grep -qiE '\bpm2\b' "$1" && m+=("pm2")
  grep -qiE '\b(ssh|scp|rsync)\b|appleboy/' "$1" && m+=("ssh")
  grep -qiE 'git pull' "$1" && m+=("git pull")
  grep -qiE '(npm|yarn|pnpm) (run )?build|next build' "$1" && m+=("build")
  grep -qiE 'prisma migrate' "$1" && m+=("prisma migrate")
  local IFS=,
  echo "${m[*]}"
}

RE_DEPLOY=',(pm2|ssh|git pull),'

# CIS_ANTIGOS: CI do mesmo provedor que não é deste projeto e faz deploy (ou ocupa o arquivo que
# vai ser gerado), "arquivo|motivos". OBSOLETOS: o que o deploy novo deixa sem uso.
detectar_pipeline_antigo() {
  local f rel motivos
  CIS_ANTIGOS=() OBSOLETOS=()
  if [ "$CI" = gitlab ]; then
    set -- "$DESTINO/.gitlab-ci.yml"
  else
    set -- "$DESTINO"/.github/workflows/*.yml "$DESTINO"/.github/workflows/*.yaml
  fi
  for f in "$@"; do
    [ -f "$f" ] || continue
    grep -q zero-downtime-deploy "$f" && continue
    rel="${f#"$DESTINO"/}"
    motivos="$(motivos_deploy "$f")"
    # Build ou migração sozinhos são de um CI de testes; deploy é pm2, ssh ou git pull
    if [[ ",$motivos," =~ $RE_DEPLOY ]] || [ "$rel" = "$ARQ_CI" ]; then CIS_ANTIGOS+=("$rel|${motivos:-ocupa o arquivo do CI novo}"); fi
  done
  for f in ecosystem.config.js ecosystem.config.cjs ecosystem.config.mjs ecosystem.config.json \
    deploy.json Procfile .gitlab/ci; do
    [ -e "$DESTINO/$f" ] && OBSOLETOS+=("$f")
  done
  # CI do outro provedor com deploy: ninguém mais o roda, mas confunde
  if [ "$CI" = gitlab ]; then set -- "$DESTINO"/.github/workflows/*.y*ml; else set -- "$DESTINO/.gitlab-ci.yml"; fi
  for f in "$@"; do
    [ -f "$f" ] && ! grep -q zero-downtime-deploy "$f" && [[ ",$(motivos_deploy "$f")," =~ $RE_DEPLOY ]] && OBSOLETOS+=("${f#"$DESTINO"/}")
  done
  return 0
}

# ---------------------------------------------------------------------------
# Páginas do Next que consultam o banco e seriam pré-renderizadas no build (que não tem banco)

# Pastas app/ do projeto
pastas_app() { local d; for d in "$DESTINO/src/app" "$DESTINO/app"; do [ -d "$d" ] && echo "$d"; done; return 0; }

# Rota de uma page.tsx (sem grupos "(x)" nem slots "@x"): app/(admin)/painel/page.tsx -> /painel
rota_da_pagina() {
  local r="$1"
  r="${r#"$DESTINO"/src/app}" r="${r#"$DESTINO"/app}"
  r="$(dirname "$r" | sed -E 's#/\([^/]*\)##g; s#/@[^/]*##g')"
  [ "$r" = . ] || [ -z "$r" ] && r=/
  echo "$r"
}

# Detecção prévia: páginas e layouts de servidor que consultam o banco, sem dynamic/revalidate e sem
# APIs que já os tornam dinâmicos (cookies, headers, auth, searchParams) nem segmento [param]
detectar_paginas_com_banco() {
  local d f
  while IFS= read -r d; do
    while IFS= read -r f; do
      [[ "$f" == *"["* ]] && continue
      grep -qE "^[[:space:]]*['\"]use client['\"]" "$f" && continue
      grep -qE 'export const (dynamic|revalidate)|generateStaticParams' "$f" && continue
      grep -qE '\bprisma\.|\bdb\.[a-zA-Z]+\.(find|count|aggregate|groupBy)|from ['\''"]@/lib/(db|prisma)' "$f" || continue
      grep -qE '\b(cookies|headers|auth|getServerSession|draftMode|connection|noStore|unstable_noStore)\(|searchParams' "$f" && continue
      echo "${f#"$DESTINO"/}"
    done < <(find "$d" -type f \( -name 'page.tsx' -o -name 'page.ts' -o -name 'page.jsx' -o -name 'page.js' \
      -o -name 'layout.tsx' -o -name 'layout.jsx' \) 2>/dev/null | sort)
  done < <(pastas_app)
}

# Acrescenta export const dynamic = "force-dynamic" depois dos imports (mantém o CRLF do arquivo)
aplicar_force_dynamic() {
  local arq="$DESTINO/$1" cr="" tmp
  grep -q 'export const dynamic' "$arq" && return 0
  if [ -n "$(tr -dc '\r' <"$arq" | head -c1)" ]; then cr=$'\r'; fi
  tmp="$(mktemp)"
  CR="$cr" awk '
    BEGIN { feito = 0; noimport = 0; cr = ENVIRON["CR"] }
    feito { print; next }
    noimport { print; if ($0 ~ /from ["\047][^"\047]*["\047];?[ \t\r]*$/) noimport = 0; next }
    /^import[ \t]/ { print; if ($0 !~ /from ["\047][^"\047]*["\047];?[ \t\r]*$/ && $0 !~ /^import ["\047]/) noimport = 1; next }
    /^[ \t\r]*$/ || /^[ \t]*\/\// || /^["\047]use / { print; next }
    { print "// O build não tem acesso ao banco: renderiza a cada pedido, não no build" cr
      print "export const dynamic = \"force-dynamic\";" cr
      print cr
      print; feito = 1 }
  ' "$arq" >"$tmp" && cat "$tmp" >"$arq"
  rm -f "$tmp"
  printf '  %s~%s %s: export const dynamic = "force-dynamic"\n' "$AMARELO" "$RESET" "$1"
}

# Arquivo de cada rota que falhou na pré-renderização, lida da saída do next build
paginas_das_rotas() {
  local rota d f
  while IFS= read -r rota; do
    while IFS= read -r d; do
      while IFS= read -r f; do
        [ "$(rota_da_pagina "$f")" = "$rota" ] && echo "${f#"$DESTINO"/}"
      done < <(find "$d" -type f \( -name 'page.tsx' -o -name 'page.ts' -o -name 'page.jsx' -o -name 'page.js' \) 2>/dev/null)
    done < <(pastas_app)
  done
}

# docker build da imagem final, sem publicar nada. Saída em $BUILD_LOG
validar_build() {
  local alvo=()
  BUILD_LOG="$(mktemp)"
  grep -qiE '^FROM .* AS runner' "$DESTINO/Dockerfile" && alvo=(--target runner)
  printf '  %s%s Compilando a imagem (docker build); pode levar alguns minutos...%s\n' "$FRACO" "$I_INFO" "$RESET"
  if docker build "${alvo[@]}" --progress=plain -t "zdd-check-$SISTEMA" "$DESTINO" >"$BUILD_LOG" 2>&1; then
    docker image rm "zdd-check-$SISTEMA" >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

# Rotas que falharam na pré-renderização (Next 13 a 15)
rotas_com_erro() {
  { grep -oE 'Error occurred prerendering page "[^"]+"' "$BUILD_LOG" | sed -E 's/.*"([^"]+)"/\1/'
    grep -oE 'Export encountered an error on [^ ,]+' "$BUILD_LOG" | sed -E 's/.* on //; s#/page:?$##'
    grep -oE '^[#0-9. ]*/[^ :]*/page: /[^ ]*' "$BUILD_LOG" | sed -E 's/.*: //'
  } | sed -E 's#/\([^/]*\)##g; s#^$#/#' | sort -u  # sem grupos: /(painel)/usuarios é /usuarios
}

# ---------------------------------------------------------------------------
# deploy.conf e stack.conf: arquivos CHAVE=valor, lidos sem executar nada

# valor_conf ARQUIVO CHAVE: o valor, sem as aspas de fora
valor_conf() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1 | sed -E "s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/" | tr -d '\r'
}
tem_chave() { grep -q "^$2=" "$1" 2>/dev/null; }

# Valores do deploy.conf como padrão: as opções do comando ganham
carregar_conf() {
  local c="$DESTINO/deploy.conf" v
  [ -f "$c" ] || return 0
  CONF_LIDO=1
  [ -n "$SISTEMA" ] || SISTEMA="$(valor_conf "$c" SYSTEM)"
  [ -n "$DOMINIO_PROD" ] || DOMINIO_PROD="$(valor_conf "$c" PROD_DOMAIN)"
  [ -n "$DOMINIO_HML" ] || DOMINIO_HML="$(valor_conf "$c" STAGING_DOMAIN)"
  [ -n "$PROD_BRANCH" ] || PROD_BRANCH="$(valor_conf "$c" PROD_BRANCH)"
  [ -n "$HML_BRANCH" ] || HML_BRANCH="$(valor_conf "$c" STAGING_BRANCH)"
  [ -n "$PROD_NOME" ] || PROD_NOME="$(valor_conf "$c" PROD_NAME)"
  [ -n "$HML_NOME" ] || HML_NOME="$(valor_conf "$c" STAGING_NAME)"
  [ -n "$PORTA_APP" ] || PORTA_APP="$(valor_conf "$c" APP_PORT)"
  [ -n "$PORTA_HML" ] || PORTA_HML="$(valor_conf "$c" STAGING_PORT)"
  [ -n "$HEALTH" ] || HEALTH="$(valor_conf "$c" HEALTH)"
  [ -n "$CI" ] || CI="$(valor_conf "$c" CI)"
  [ -n "$LIMITE_UPLOAD" ] || LIMITE_UPLOAD="$(valor_conf "$c" UPLOAD_LIMIT)"
  [ -n "$IP_PROD" ] || IP_PROD="$(valor_conf "$c" PROD_IP)"
  [ -n "$TAG_RUNNER" ] || TAG_RUNNER="$(valor_conf "$c" RUNNER_TAG)"
  if [ "$SEM_HML_DEF" = 0 ] && tem_chave "$c" NO_STAGING; then
    [ "$(valor_conf "$c" NO_STAGING)" = 1 ] && SEM_HML=1
    SEM_HML_DEF=1
  fi
  if [ "$STACK_DEFINIDA" = 0 ] && tem_chave "$c" STACK; then STACK="$(valor_conf "$c" STACK)"; STACK_DEFINIDA=1; fi
  if [ "$VOLUMES_DEF" = 0 ] && tem_chave "$c" VOLUMES; then read -ra VOLUMES <<<"$(valor_conf "$c" VOLUMES)"; VOLUMES_DEF=1; fi
  if [ "$COPIAR_DEF" = 0 ] && tem_chave "$c" COPY; then read -ra COPIAR <<<"$(valor_conf "$c" COPY)"; COPIAR_DEF=1; fi
  if tem_chave "$c" BUILD_ARGS; then read -ra BUILD_ARGS_CONF <<<"$(valor_conf "$c" BUILD_ARGS)"; BUILD_ARGS_DEF=1; fi
  if [ "$MIGRATE_DEF" = 0 ] && tem_chave "$c" MIGRATE_CMD; then MIGRATE_CMD="$(valor_conf "$c" MIGRATE_CMD)"; MIGRATE_DEF=1; fi
  printf '  %s%s Lendo %s: o que já está lá não é perguntado%s\n' "$FRACO" "$I_INFO" "deploy.conf" "$RESET" >&2
}

# Pontos de uma stack para o repositório (0: não bate). Cada regra arquivo:texto precisa bater;
# regra com texto vale 2, só com arquivo vale 1: a stack mais específica ganha
pontuar_stack() {
  local conf="$1/stack.conf" regra arq texto pontos=0
  for regra in $(valor_conf "$conf" DETECTA); do
    arq="${regra%%:*}" texto="${regra#*:}"
    [ -f "$DESTINO/$arq" ] || { echo 0; return 0; }
    if [ -n "$texto" ]; then
      grep -qF -- "$texto" "$DESTINO/$arq" || { echo 0; return 0; }
      pontos=$((pontos + 2))
    else
      pontos=$((pontos + 1))
    fi
  done
  echo "$pontos"
}

# Stack mais provável: mais pontos; no empate, maior PRIORIDADE
detectar_stack() {
  local d nome pontos prio melhor="" mp=0 mprio=-1
  for d in "$AQUI"/examples/*/; do
    [ -f "$d/stack.conf" ] || continue
    nome="$(basename "$d")"
    pontos="$(pontuar_stack "$d")"
    prio="$(valor_conf "$d/stack.conf" PRIORIDADE)"
    prio="${prio:-0}"
    if [ "$pontos" -gt "$mp" ] || { [ "$pontos" -gt 0 ] && [ "$pontos" = "$mp" ] && [ "$prio" -gt "$mprio" ]; }; then
      melhor="$nome" mp="$pontos" mprio="$prio"
    fi
  done
  echo "$melhor"
}

# Padrões e comportamentos da stack escolhida
carregar_stack() {
  local conf="$AQUI/examples/$STACK/stack.conf"
  STACK_NEXTJS=0 STACK_PREFIXO="" STACK_VOLUMES_PADRAO=uploads STACK_APP_PORT="" STACK_HEALTH=""
  STACK_PERGUNTAR_APP=0 STACK_PERGUNTAR_MIGRACAO=0 STACK_HEALTH_PROPRIA=0
  [ -n "$STACK" ] && [ -f "$conf" ] || return 0
  STACK_NEXTJS="$(valor_conf "$conf" NEXTJS)"; STACK_NEXTJS="${STACK_NEXTJS:-0}"
  STACK_PREFIXO="$(valor_conf "$conf" BUILD_ARGS_PREFIXO)"
  STACK_VOLUMES_PADRAO="$(valor_conf "$conf" VOLUMES_PADRAO)"
  STACK_APP_PORT="$(valor_conf "$conf" APP_PORT)"
  STACK_HEALTH="$(valor_conf "$conf" HEALTH)"
  STACK_PERGUNTAR_APP="$(valor_conf "$conf" PERGUNTAR_APP)"; STACK_PERGUNTAR_APP="${STACK_PERGUNTAR_APP:-0}"
  STACK_PERGUNTAR_MIGRACAO="$(valor_conf "$conf" PERGUNTAR_MIGRACAO)"; STACK_PERGUNTAR_MIGRACAO="${STACK_PERGUNTAR_MIGRACAO:-0}"
  STACK_HEALTH_PROPRIA="$(valor_conf "$conf" HEALTH_PROPRIA)"; STACK_HEALTH_PROPRIA="${STACK_HEALTH_PROPRIA:-0}"
  # Dockerfile próprio: a porta vem dele (EXPOSE, ou --port / 0.0.0.0:PORTA no CMD)
  if [ "$STACK_PERGUNTAR_APP" = 1 ] && [ -f "$DESTINO/Dockerfile" ]; then
    local p
    p="$(grep -m1 -iE '^[[:space:]]*EXPOSE[[:space:]]+[0-9]+' "$DESTINO/Dockerfile" | grep -oE '[0-9]+' | head -1 || true)"
    if [ -z "$p" ]; then
      p="$(grep -iE '^[[:space:]]*(CMD|ENTRYPOINT)' "$DESTINO/Dockerfile" \
        | grep -oE '(--port|-p)"?,? *"?[0-9]{2,5}|0\.0\.0\.0:[0-9]{2,5}' | grep -oE '[0-9]{2,5}$' | head -1 || true)"
    fi
    if [ -n "$p" ]; then STACK_APP_PORT="$p"; fi
  fi
}

# Grava o deploy.conf com as respostas desta execução
escrever_conf() {
  local c="$DESTINO/deploy.conf" novo=1
  [ -f "$c" ] && novo=0
  aspas() { if [[ "$1" == *'"'* ]]; then printf "'%s'" "$1"; else printf '"%s"' "$1"; fi; }
  {
    echo "# zero-downtime-deploy: configuração do deploy deste sistema. Vai no git, sem segredos"
    echo "# (os segredos ficam no .env de cada pasta na VM). Depois de mudar algo aqui, gere de novo"
    echo "# os arquivos de deploy: bash scaffold.sh --upgrade"
    echo "SYSTEM=$SISTEMA"
    echo "PROD_DOMAIN=$DOMINIO_PROD"
    echo "PROD_BRANCH=$PROD_BRANCH"
    echo "PROD_NAME=$PROD_NOME"
    echo "# 1: só produção, sem homologação"
    echo "NO_STAGING=$SEM_HML"
    echo "STAGING_DOMAIN=$DOMINIO_HML"
    echo "STAGING_BRANCH=$HML_BRANCH"
    echo "STAGING_NAME=$HML_NOME"
    echo "STAGING_PORT=$PORTA_HML"
    echo "APP_PORT=$PORTA_APP"
    echo "HEALTH=$HEALTH"
    echo "CI=$CI"
    echo "RUNNER_TAG=$TAG_RUNNER"
    echo "# Pasta de examples/ no zero-downtime-deploy; vazio: nenhuma"
    echo "STACK=$STACK"
    echo "# Pastas onde a aplicação grava arquivos, montadas fora do contêiner"
    echo "VOLUMES=$(aspas "${VOLUMES[*]}")"
    echo "# Pastas lidas em tempo de execução, copiadas para a imagem"
    echo "COPY=$(aspas "${COPIAR[*]}")"
    echo "# Variáveis gravadas no build, com o valor do .env de cada pasta"
    echo "BUILD_ARGS=$(aspas "${NEXT_PUBLIC[*]}")"
    echo "# Migração do banco, rodada na imagem nova antes da troca (o deploy.sh lê daqui)"
    echo "MIGRATE_CMD=$(aspas "$MIGRATE_CMD")"
    echo "UPLOAD_LIMIT=$LIMITE_UPLOAD"
    echo "PROD_IP=$IP_PROD"
  } >"$c"
  if [ "$novo" = 1 ]; then
    printf '  %s%s%s deploy.conf\n' "$VERDE" "$I_NOVO" "$RESET"
  else
    printf '  %s↻%s deploy.conf\n' "$CIANO" "$RESET"
  fi
}

# Faltou algo obrigatório e há terminal: pergunta em vez de parar
if [ -n "$DESTINO" ]; then DESTINO="${DESTINO/#\~/$HOME}"; carregar_conf; fi
if [ "$INTERATIVO" = auto ]; then
  if { [ -z "$SISTEMA" ] || [ -z "$DOMINIO_PROD" ] || { [ -z "$DOMINIO_HML" ] && [ "$SEM_HML" = 0 ]; } || [ -z "$DESTINO" ]; } \
    && { : </dev/tty; } 2>/dev/null; then
    INTERATIVO=1
  else
    INTERATIVO=0
  fi
fi

if [ "$INTERATIVO" = 1 ]; then
  { : </dev/tty; } 2>/dev/null || falha "o modo interativo precisa de um terminal"
  trap 'printf "\n\n  %s%s Cancelado: nada foi alterado.%s\n" "$AMARELO" "$I_AVISO" "$RESET" >/dev/tty; exit 130' INT
  banner "scaffold.sh $VERSAO" "arquivos de deploy blue-green para o repositório"
  echo >/dev/tty

  if [ -z "$DESTINO" ]; then
    atual=""
    if git rev-parse --show-toplevel >/dev/null 2>&1; then atual="$(git rev-parse --show-toplevel)"; fi
    lista="$(mktemp)"
    com_espera "$lista" "Procurando repositórios git..." listar_repos "$atual"
    mapfile -t repos <"$lista"
    rm -f "$lista"
    if [ "${#repos[@]}" -eq 0 ]; then
      perguntar DESTINO "Pasta do repositório do sistema" "${atual:-.}"
    else
      opcoes=() n=1 i=1
      for r in "${repos[@]}"; do
        rotulo="${r/#$HOME/\~}"
        ramo="$(git -C "$r" symbolic-ref --short -q HEAD 2>/dev/null || true)"
        [ -n "$ramo" ] && rotulo="$rotulo  $FRACO$ramo$RESET"
        [ "$r" = "$atual" ] && { rotulo="$rotulo  $CIANO← pasta atual$RESET"; n=$i; }
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
  [ "$CONF_LIDO" = 1 ] || carregar_conf

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
  if [ "$CI" = gitlab ] && [ -z "$TAG_RUNNER" ]; then
    perguntar TAG_RUNNER "Tag do runner da VM (se ela já tem um runner registrado, use a tag dele)" "$SISTEMA" '^[A-Za-z0-9_.-]+$'
  fi

  if [ "$SEM_HML_DEF" = 0 ] && [ -z "$HML_BRANCH" ] && [ -z "$DOMINIO_HML" ]; then
    escolher ambientes "Ambientes" 1 \
      "ambos|produção e homologação (homologação na porta 3001 da mesma VM, com banco próprio)" \
      "prod|só produção"
    if [ "$ambientes" = prod ]; then SEM_HML=1; fi
    SEM_HML_DEF=1
  fi

  if [ -z "$PROD_BRANCH" ]; then
    escolher_branch PROD_BRANCH "Branch de produção" "$branches" main main master production prod
  fi
  if [ -z "$HML_BRANCH" ] && [ "$SEM_HML" = 0 ]; then
    escolher_branch HML_BRANCH "Branch de homologação" "$branches" dev dev develop developer homolog homologacao staging hml
    if ! grep -qx "$HML_BRANCH" <<<"$branches"; then
      echo "    A branch $HML_BRANCH ainda não existe: crie-a a partir de $PROD_BRANCH (git checkout -b $HML_BRANCH)."
    fi
  fi

  if [ -z "$DOMINIO_PROD" ]; then
    perguntar DOMINIO_PROD "Domínio de produção" "$SISTEMA.saoluis.ma.gov.br" '^[A-Za-z0-9.-]+$'
  fi
  if [ -z "$DOMINIO_HML" ] && [ "$SEM_HML" = 0 ]; then
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
    detectada="$(detectar_stack)"
    opcoes=() n=0 i=1
    for d in "$AQUI"/examples/*/; do
      [ -f "$d/stack.conf" ] || continue
      nome="$(basename "$d")"
      desc="$(valor_conf "$d/stack.conf" DESCRICAO)"
      if [ "$nome" = "$detectada" ]; then
        opcoes+=("$nome|$nome: $desc  $CIANO(detectada)$RESET")
        n=$i
      else
        opcoes+=("$nome|$nome: $FRACO$desc$RESET")
      fi
      i=$((i + 1))
    done
    opcoes+=("|nenhuma (Dockerfile, rota de saúde e migração ficam com você)")
    [ "$n" = 0 ] && n=$i
    escolher STACK "Stack do sistema" "$n" "${opcoes[@]}"
  fi
  carregar_stack
  # Dockerfile próprio: porta e rota de saúde vêm do sistema
  if [ "$STACK_PERGUNTAR_APP" = 1 ]; then
    perguntar PORTA_APP "Porta em que a aplicação ouve dentro do contêiner" "${PORTA_APP:-$STACK_APP_PORT}" '^[0-9]+$'
    perguntar HEALTH "Rota de saúde (200 só com a aplicação pronta, sem login)" "${HEALTH:-$STACK_HEALTH}" '^/'
  fi
  if [ "$STACK_PERGUNTAR_MIGRACAO" = 1 ] && [ "$MIGRATE_DEF" = 0 ]; then
    perguntar MIGRATE_CMD "Comando de migração do banco, rodado na imagem nova antes da troca (Enter: nenhum)" "" '^.*$'
    MIGRATE_DEF=1
  fi

  analisar_repositorio
  if [ "$VOLUMES_DEF" = 0 ]; then
    extra=""
    if [ "${#DET_VOLUMES[@]}" -gt 0 ]; then
      todas_marcadas "${DET_VOLUMES[@]}"
      escolher_varios VOLUMES "Pastas onde a aplicação grava arquivos (montadas fora do contêiner, não se perdem no deploy)" "$MARCADOS" "${OPCOES[@]}"
      perguntar extra "Outras pastas, separadas por espaço (Enter: nenhuma)" "" '^[A-Za-z0-9._/ -]*$'
    else
      perguntar extra "Pastas onde a aplicação grava arquivos, separadas por espaço (0: nenhuma)" "${STACK_VOLUMES_PADRAO:-0}" '^([A-Za-z0-9._/ -]+|0)$'
      [ "$extra" != 0 ] || extra=""
    fi
    for v in $extra; do VOLUMES+=("$v"); done
    VOLUMES_DEF=1
  fi
  if [ "$STACK_NEXTJS" = 1 ] && [ "$COPIAR_DEF" = 0 ]; then
    mapfile -t det_copiar < <(detectar_copiar)
    if [ "${#det_copiar[@]}" -gt 0 ]; then
      todas_marcadas "${det_copiar[@]}"
      escolher_varios COPIAR "Pastas lidas pela aplicação em tempo de execução (copiadas para a imagem)" "$MARCADOS" "${OPCOES[@]}"
    fi
    COPIAR_DEF=1
  fi
  if [[ "$DOMINIO_HML" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && [ -z "$IP_PROD" ]; then
    if sim_nao "Abrir a produção também por http://$DOMINIO_HML (porta 80)? Não: o acesso por IP é recusado" n; then
      IP_PROD="$DOMINIO_HML"
    fi
  fi

  if sim_nao "Ajustar portas, rota de saúde, limite de upload ou nomes dos ambientes? (agora: ${PORTA_APP:-${STACK_APP_PORT:-3000}}, ${HEALTH:-${STACK_HEALTH:-/api/health}}, ${PORTA_HML:-3001}, ${LIMITE_UPLOAD:-25m}, ${PROD_NOME:-production}, ${HML_NOME:-developer})" n; then
    perguntar PORTA_APP "Porta da aplicação dentro do contêiner" "${PORTA_APP:-${STACK_APP_PORT:-3000}}" '^[0-9]+$'
    perguntar HEALTH "Rota de saúde (200 só com a aplicação pronta, sem login)" "${HEALTH:-${STACK_HEALTH:-/api/health}}" '^/'
    if [ "$SEM_HML" = 0 ]; then perguntar PORTA_HML "Porta de homologação na VM" "${PORTA_HML:-3001}" '^[0-9]+$'; fi
    perguntar LIMITE_UPLOAD "Maior envio aceito pelo Nginx (um pouco acima do limite da aplicação)" "${LIMITE_UPLOAD:-25m}" '^[0-9]+[kKmMgG]?$'
    perguntar PROD_NOME "Nome do ambiente de produção (pasta na VM)" "${PROD_NOME:-production}" '^[a-z0-9_-]+$'
    if [ "$SEM_HML" = 0 ]; then perguntar HML_NOME "Nome do ambiente de homologação (pasta na VM)" "${HML_NOME:-developer}" '^[a-z0-9_-]+$'; fi
  fi
fi

PORTA_HML="${PORTA_HML:-3001}"
PROD_NOME="${PROD_NOME:-production}" PROD_BRANCH="${PROD_BRANCH:-main}"
HML_NOME="${HML_NOME:-developer}" HML_BRANCH="${HML_BRANCH:-dev}" CI="${CI:-github}"

if [ "$UPGRADE" = 1 ] && [ "$CONF_LIDO" = 0 ] && [ "$INTERATIVO" = 0 ]; then
  echo "--upgrade: $DESTINO/deploy.conf não existe. Rode num terminal (o script pergunta) ou passe as opções." >&2
fi
[ -n "$SISTEMA" ] && [ -n "$DOMINIO_PROD" ] && { [ -n "$DOMINIO_HML" ] || [ "$SEM_HML" = 1 ]; } && [ -n "$DESTINO" ] || uso 1
[[ "$SISTEMA" =~ ^[a-z0-9_]+$ ]] || { echo "--system aceita só minúsculas, números e _ (vira nome de contêiner)" >&2; exit 1; }
[[ "$CI" =~ ^(github|gitlab)$ ]] || { echo "--ci aceita github ou gitlab" >&2; exit 1; }
[ -d "$DESTINO" ] || { echo "Pasta não encontrada: $DESTINO" >&2; exit 1; }
[ -d "$AQUI/modelos" ] || { echo "Pasta modelos/ não encontrada ao lado do script" >&2; exit 1; }
if [ -n "$STACK" ] && [ ! -f "$AQUI/examples/$STACK/stack.conf" ]; then
  echo "Stack desconhecida: $STACK. Disponíveis: $(ls "$AQUI/examples" | tr '\n' ' ')" >&2
  exit 1
fi
carregar_stack
PORTA_APP="${PORTA_APP:-${STACK_APP_PORT:-3000}}" HEALTH="${HEALTH:-${STACK_HEALTH:-/api/health}}"
LIMITE_UPLOAD="${LIMITE_UPLOAD:-25m}" TAG_RUNNER="${TAG_RUNNER:-$SISTEMA}"
[[ "$LIMITE_UPLOAD" =~ ^[0-9]+[kKmMgG]?$ ]] || falha "--upload-limit aceita um tamanho como 12m"
[ -z "$IP_PROD" ] || [[ "$IP_PROD" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || falha "--prod-ip aceita um IPv4"
[[ "$TAG_RUNNER" =~ ^[A-Za-z0-9_.-]+$ ]] || falha "--runner-tag aceita letras, números, _, . e -"

[ -n "$FONTES" ] || analisar_repositorio
if [ "$VOLUMES_DEF" = 0 ]; then
  if [ "${#DET_VOLUMES[@]}" -gt 0 ]; then VOLUMES=("${DET_VOLUMES[@]}"); else read -ra VOLUMES <<<"$STACK_VOLUMES_PADRAO"; fi
fi
# Caminhos relativos à raiz do repositório, sem ./ nem / no fim
for i in "${!VOLUMES[@]}"; do
  v="${VOLUMES[$i]#./}"; v="${v%/}"; VOLUMES[$i]="$v"
  [[ "$v" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "$v" != *..* ]] || falha "pasta inválida em --volume: $v"
done
if [ "$STACK_NEXTJS" = 1 ] && [ "$COPIAR_DEF" = 0 ]; then mapfile -t COPIAR < <(detectar_copiar); fi
for v in "${COPIAR[@]}"; do
  [[ "$v" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "$v" != *..* ]] || falha "pasta inválida em --copy: $v"
done

# Pipelines de deploy antigos (ex.: git pull + pm2 restart): sem desativá-los, cada push faria
# dois deploys, o antigo e o novo
if [ "$CI" = gitlab ]; then ARQ_CI=.gitlab-ci.yml; else ARQ_CI=.github/workflows/deploy.yml; fi
detectar_pipeline_antigo
DESATIVAR=()
if [ "${#CIS_ANTIGOS[@]}" -gt 0 ]; then
  if [ "$SUBSTITUIR_CI" = 1 ]; then
    for e in "${CIS_ANTIGOS[@]}"; do DESATIVAR+=("${e%%|*}"); done
  elif [ "$INTERATIVO" = 1 ]; then
    opcoes=() marcados="" i=1
    for e in "${CIS_ANTIGOS[@]}"; do
      opcoes+=("${e%%|*}|${e%%|*}  ${FRACO}(${e#*|})$RESET")
      marcados+="${marcados:+ }$i"
      i=$((i + 1))
    done
    escolher_varios DESATIVAR "Pipelines de deploy antigos (os marcados vão para .bak e deixam de rodar)" "$marcados" "${opcoes[@]}"
    if [ "${#DESATIVAR[@]}" -eq "${#CIS_ANTIGOS[@]}" ]; then SUBSTITUIR_CI=1; fi
  fi
fi

# Páginas que consultam o banco e quebrariam o next build
FORCE_PAGINAS=() PAGINAS_BANCO=()
if [ "$STACK_NEXTJS" = 1 ]; then
  mapfile -t PAGINAS_BANCO < <(detectar_paginas_com_banco)
  if [ "${#PAGINAS_BANCO[@]}" -gt 0 ]; then
    if [ "$FORCE_DYNAMIC" = 1 ]; then
      FORCE_PAGINAS=("${PAGINAS_BANCO[@]}")
    elif [ "$INTERATIVO" = 1 ]; then
      todas_marcadas "${PAGINAS_BANCO[@]}"
      escolher_varios FORCE_PAGINAS "Páginas que consultam o banco e seriam geradas no build, sem banco (marcadas: renderizar a cada pedido)" "$MARCADOS" "${OPCOES[@]}"
      if [ "${#FORCE_PAGINAS[@]}" -eq "${#PAGINAS_BANCO[@]}" ]; then FORCE_DYNAMIC=1; fi
    fi
  fi
fi

# Validação com docker build no fim
if [ -z "$CHECK_BUILD" ]; then
  CHECK_BUILD=0
  if [ "$INTERATIVO" = 1 ] && command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    if sim_nao "No fim, validar com docker build? (alguns minutos; acha páginas que quebram o build)" s; then CHECK_BUILD=1; fi
  fi
fi

if [ "$INTERATIVO" = 1 ]; then
  cmd="$CHAMADA --system $SISTEMA --prod-domain $DOMINIO_PROD"
  if [ "$SEM_HML" = 1 ]; then
    cmd+=" --no-staging --prod-branch $PROD_BRANCH --ci $CI"
  else
    cmd+=" --staging-domain $DOMINIO_HML --prod-branch $PROD_BRANCH --staging-branch $HML_BRANCH --ci $CI"
  fi
  if [ -n "$STACK" ]; then cmd+=" --stack $STACK"; fi
  if [ "$PORTA_APP" != 3000 ]; then cmd+=" --app-port $PORTA_APP"; fi
  if [ "$HEALTH" != /api/health ]; then cmd+=" --health $HEALTH"; fi
  if [ "$PORTA_HML" != 3001 ] && [ "$SEM_HML" = 0 ]; then cmd+=" --staging-port $PORTA_HML"; fi
  if [ "$PROD_NOME" != production ]; then cmd+=" --prod-name $PROD_NOME"; fi
  if [ "$HML_NOME" != developer ] && [ "$SEM_HML" = 0 ]; then cmd+=" --staging-name $HML_NOME"; fi
  if [ "$SUBSTITUIR_CI" = 1 ]; then cmd+=" --replace-ci"; fi
  if [ "$FORCE_DYNAMIC" = 1 ]; then cmd+=" --force-dynamic"; fi
  if [ -n "$MIGRATE_CMD" ]; then cmd+=" --migrate-cmd $(printf '%q' "$MIGRATE_CMD")"; fi
  if [ "$UPGRADE" = 1 ]; then cmd+=" --upgrade"; fi
  if [ "$CHECK_BUILD" = 1 ]; then cmd+=" --check-build"; fi
  if [ "${#VOLUMES[@]}" -eq 0 ]; then cmd+=" --no-volume"; fi
  for v in "${VOLUMES[@]}"; do cmd+=" --volume $v"; done
  for v in "${COPIAR[@]}"; do cmd+=" --copy $v"; done
  if [ "$LIMITE_UPLOAD" != 25m ]; then cmd+=" --upload-limit $LIMITE_UPLOAD"; fi
  if [ -n "$IP_PROD" ]; then cmd+=" --prod-ip $IP_PROD"; fi
  if [ "$CI" = gitlab ] && [ "$TAG_RUNNER" != "$SISTEMA" ]; then cmd+=" --runner-tag $TAG_RUNNER"; fi
  # Alinha pelo número de letras: o %-13s do printf conta bytes e desalinha com acentos
  linha() { printf '    %s%s%*s%s %s\n' "$FRACO" "$1" $((13 - ${#1})) '' "$RESET" "$2" >/dev/tty; }
  printf '\n  %s%s Resumo%s\n' "$NEGRITO$AZUL" "$I_ETAPA" "$RESET" >/dev/tty
  linha Repositório "${DESTINO/#$HOME/\~}"
  linha Sistema "$SISTEMA"
  linha Produção "$DOMINIO_PROD  ${FRACO}branch $PROD_BRANCH$RESET"
  if [ "$SEM_HML" = 1 ]; then
    linha Homologação "${FRACO}não usa (só produção)$RESET"
  else
    linha Homologação "$DOMINIO_HML  ${FRACO}porta $PORTA_HML na VM · branch $HML_BRANCH$RESET"
  fi
  linha CI "$CI$([ "${#DESATIVAR[@]}" -gt 0 ] && echo "  ${FRACO}(${#DESATIVAR[@]} pipeline(s) antigo(s) vão para .bak)$RESET")"
  if [ "${#FORCE_PAGINAS[@]}" -gt 0 ]; then linha "Páginas" "${#FORCE_PAGINAS[@]} com force-dynamic"; fi
  if [ "$CHECK_BUILD" = 1 ]; then linha "Validação" "docker build no fim"; fi
  linha Stack "${STACK:-nenhuma}"
  if [ -n "$MIGRATE_CMD" ]; then linha Migração "$MIGRATE_CMD"; elif [ -f "$AQUI/examples/$STACK/compose.migrate.yml" ]; then linha Migração "da stack (compose.migrate.yml)"; fi
  if [ "$UPGRADE" = 1 ]; then linha Upgrade "arquivos gerados pelo zero-downtime-deploy são refeitos"; fi
  linha Volumes "${VOLUMES[*]:-nenhum}  ${FRACO}(montados fora do contêiner)$RESET"
  if [ "${#COPIAR[@]}" -gt 0 ]; then linha "Na imagem" "${COPIAR[*]}"; fi
  if [ "${#NEXT_PUBLIC[@]}" -gt 0 ]; then linha "Build args" "${NEXT_PUBLIC[*]}"; fi
  linha Upload "até $LIMITE_UPLOAD"
  if [ -n "$IP_PROD" ]; then linha "IP na 80" "abre a produção"; fi
  if [ "$CI" = gitlab ]; then linha "Tag runner" "$TAG_RUNNER"; fi
  printf '\n  %s%s Para repetir sem perguntas:%s\n    %s%s %s%s\n\n' "$FRACO" "$I_INFO" "$RESET" "$CIANO" "$cmd" "$DESTINO" "$RESET" >/dev/tty
  sim_nao "Gerar os arquivos?" s || { printf '  %s%s Nada foi alterado.%s\n' "$AMARELO" "$I_AVISO" "$RESET"; exit 0; }
  trap - INT
  echo
fi

CI_ANTIGO_TESTES=0
for f in "${DESATIVAR[@]}"; do
  mv "$DESTINO/$f" "$DESTINO/$f.bak"
  if grep -qiE 'jest|vitest|tsc|npm (run )?test|pytest|mvn|gradle' "$DESTINO/$f.bak"; then CI_ANTIGO_TESTES=1; fi
  printf '  %s%s%s %s antigo movido para %s.bak (não roda mais)\n' "$AMARELO" "$I_MOVIDO" "$RESET" "$f" "$f"
done

# Job de teste a partir do package.json: define TESTE_IMAGEM, TESTE_NODE, TESTE_GESTOR e TESTE_CMDS
montar_testes() {
  local pj="$DESTINO/package.json" v scripts instalar rodar
  TESTE_IMAGEM="alpine:3.20" TESTE_NODE="" TESTE_GESTOR="" TESTE_CMDS=()
  [ -f "$pj" ] || return 0
  v="$(tr -dc '0-9.\n' 2>/dev/null <"$DESTINO/.nvmrc" | head -1 | cut -d. -f1 || true)"
  if [ -z "$v" ]; then
    v="$(tr -d '\r\n' <"$pj" | grep -oE '"engines" *: *\{[^}]*\}' | grep -oE '"node" *: *"[^"]*"' \
      | sed -E 's/.*: *"//' | grep -oE '[0-9]+' | head -1 || true)"
  fi
  TESTE_NODE="${v:-20}" TESTE_IMAGEM="node:${v:-20}"
  if [ -f "$DESTINO/pnpm-lock.yaml" ]; then
    TESTE_GESTOR=pnpm instalar="corepack enable && pnpm install --frozen-lockfile" rodar="pnpm"
  elif [ -f "$DESTINO/yarn.lock" ]; then
    TESTE_GESTOR=yarn instalar="corepack enable && yarn install --frozen-lockfile" rodar="yarn"
  elif [ -f "$DESTINO/package-lock.json" ]; then
    TESTE_GESTOR=npm instalar="npm ci" rodar="npm run"
  else
    TESTE_GESTOR="" instalar="npm install" rodar="npm run"
  fi
  TESTE_CMDS=("$instalar")
  scripts="$(tr -d '\r\n' <"$pj" | grep -oE '"scripts" *: *\{[^}]*\}' || true)"
  if grep -q '"prisma"' "$pj"; then TESTE_CMDS+=("npx prisma generate"); fi
  if grep -qE '"typecheck" *:' <<<"$scripts"; then
    TESTE_CMDS+=("$rodar typecheck")
  elif grep -qE '"type-check" *:' <<<"$scripts"; then
    TESTE_CMDS+=("$rodar type-check")
  elif [ -f "$DESTINO/tsconfig.json" ]; then
    TESTE_CMDS+=("npx tsc --noEmit")
  fi
  if grep -qE '"test" *:' <<<"$scripts" && ! grep -qE '"test" *: *"[^"]*no test specified' <<<"$scripts"; then
    TESTE_CMDS+=("$rodar test")
  fi
}

# Blocos de várias linhas: cada um substitui a linha "# {{NOME}}" do modelo (vazio apaga a linha)
montar_blocos() {
  local v
  BLOCO_VOLUMES="" BLOCO_CRIAR_PASTAS="" BLOCO_BUILD_ARGS="" BLOCO_BUILD_ARGS_DOCKERFILE=""
  BLOCO_COPIAR_PASTAS="" BLOCO_HML_PORTA_80="" BLOCO_TESTE_SCRIPT="" BLOCO_TESTE_PASSOS=""

  BLOCO_CRIAR_PASTAS_DOCKERFILE=""
  if [ "${#VOLUMES[@]}" -gt 0 ]; then
    BLOCO_CRIAR_PASTAS_DOCKERFILE="# Pastas montadas: o compose escolhe o UID (dono delas no host), então qualquer um grava"
    BLOCO_CRIAR_PASTAS_DOCKERFILE+="${NL}RUN mkdir -p ${VOLUMES[*]} && chmod -R a+rwX ${VOLUMES[*]}"
    BLOCO_VOLUMES="    volumes:"
    for v in "${VOLUMES[@]}"; do BLOCO_VOLUMES+="$NL      - ./$v:/app/$v"; done
    BLOCO_CRIAR_PASTAS="# Pastas montadas como volume: criadas aqui, com o dono certo (o Docker as criaria como root)"
    BLOCO_CRIAR_PASTAS+="${NL}mkdir -p ${VOLUMES[*]}"
  else
    BLOCO_VOLUMES="    # Sem pastas montadas (--volume): o que a aplicação gravar se perde no deploy"
  fi

  if [ "${#NEXT_PUBLIC[@]}" -gt 0 ]; then
    BLOCO_BUILD_ARGS="      # Variáveis gravadas no build: o valor vem do .env desta pasta${NL}      args:"
    BLOCO_BUILD_ARGS_DOCKERFILE="# Variáveis gravadas no build; o compose as passa a partir do .env de cada pasta"
    for v in "${NEXT_PUBLIC[@]}"; do
      BLOCO_BUILD_ARGS+="$NL        $v: \${$v:-}"
      BLOCO_BUILD_ARGS_DOCKERFILE+="${NL}ARG $v"
    done
  fi

  if [ "${#COPIAR[@]}" -gt 0 ]; then
    BLOCO_COPIAR_PASTAS="# Lidas pela aplicação em tempo de execução: o build standalone não as inclui"
    for v in "${COPIAR[@]}"; do BLOCO_COPIAR_PASTAS+="${NL}COPY --from=builder /app/$v ./$v"; done
  fi

  if [[ "$DOMINIO_HML" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    BLOCO_HML_PORTA_80="    # Sem domínio próprio, só a porta $PORTA_HML. Quando houver um, acrescente:"
    BLOCO_HML_PORTA_80+="$NL    #   listen 80;$NL    #   server_name hml.exemplo.gov.br;"
  else
    BLOCO_HML_PORTA_80="    # E na porta 80 pelo domínio próprio$NL    listen 80;$NL    server_name $DOMINIO_HML;"
  fi

  if [ "${#TESTE_CMDS[@]}" -gt 0 ]; then
    BLOCO_TESTE_PASSOS="      - uses: actions/setup-node@v4$NL        with:$NL          node-version: $TESTE_NODE"
    if [ "$TESTE_GESTOR" = npm ]; then BLOCO_TESTE_PASSOS+="$NL          cache: npm"; fi
    for v in "${TESTE_CMDS[@]}"; do
      BLOCO_TESTE_SCRIPT+="${BLOCO_TESTE_SCRIPT:+$NL}    - $v"
      BLOCO_TESTE_PASSOS+="$NL      - run: $v"
    done
  else
    BLOCO_TESTE_SCRIPT="    # Testes do sistema aqui (ex.: ./mvnw verify)$NL    - echo \"sem testes configurados\""
    BLOCO_TESTE_PASSOS="      # Testes do sistema aqui (ex.: ./mvnw verify)$NL      - run: echo \"sem testes configurados\""
  fi
  export BLOCO_VOLUMES BLOCO_CRIAR_PASTAS BLOCO_BUILD_ARGS BLOCO_BUILD_ARGS_DOCKERFILE BLOCO_CRIAR_PASTAS_DOCKERFILE \
    BLOCO_COPIAR_PASTAS BLOCO_HML_PORTA_80 BLOCO_TESTE_SCRIPT BLOCO_TESTE_PASSOS
}

# Troca só os marcadores conhecidos: as expressões {{ ... }} do GitHub e do Docker ficam intactas
preencher() {
  awk '{
    # Trechos só com homologação (COM_HML), só sem ela (SEM_HML, o "senão") e o fim deles
    if ($0 ~ /^[ \t]*# \{\{COM_HML\}\}[ \t]*$/) { pular = (ENVIRON["SEM_HML"] == "1"); next }
    if ($0 ~ /^[ \t]*# \{\{SEM_HML\}\}[ \t]*$/) { pular = (ENVIRON["SEM_HML"] != "1"); next }
    if ($0 ~ /^[ \t]*# \{\{FIM\}\}[ \t]*$/) { pular = 0; next }
    if (pular) next
    if (match($0, /# \{\{[A-Z_0-9]+\}\}/) && substr($0, 1, RSTART - 1) ~ /^[ \t]*$/) {
      v = ENVIRON["BLOCO_" substr($0, RSTART + 4, RLENGTH - 6)]
      if (v != "") print v
      next
    }
    print
  }' | sed -e "s|{{SISTEMA}}|$SISTEMA|g" \
      -e "s|{{DOMINIO_PROD}}|$DOMINIO_PROD|g" \
      -e "s|{{DOMINIO_HML}}|$DOMINIO_HML|g" \
      -e "s|{{PORTA_APP}}|$PORTA_APP|g" \
      -e "s|{{HEALTH}}|$HEALTH|g" \
      -e "s|{{PORTA_HML}}|$PORTA_HML|g" \
      -e "s|{{PROD_NOME}}|$PROD_NOME|g" \
      -e "s|{{PROD_BRANCH}}|$PROD_BRANCH|g" \
      -e "s|{{HML_NOME}}|$HML_NOME|g" \
      -e "s|{{HML_BRANCH}}|$HML_BRANCH|g" \
      -e "s|{{BRANCHES}}|$BRANCHES|g" \
      -e "s|{{LIMITE_UPLOAD}}|$LIMITE_UPLOAD|g" \
      -e "s|{{IP_PROD}}|${IP_PROD:+ $IP_PROD}|g" \
      -e "s|{{TAG_RUNNER}}|$TAG_RUNNER|g" \
      -e "s|{{TESTE_IMAGEM}}|$TESTE_IMAGEM|g" \
      -e "s|{{PASTAS_VOLUME}}|${VOLUMES[*]}|g" \
      -e "s|{{COR}}|${COR:-}|g"
}

# Acrescenta LINHAS ao fim de ARQUIVO com a mesma quebra de linha dele (CRLF se for de Windows)
acrescentar() {
  local arq="$1" cr="" l
  shift
  # tr em vez de grep: o grep do Git Bash não enxerga o \r
  if [ -f "$arq" ] && [ -n "$(tr -dc '\r' <"$arq" | head -c1)" ]; then cr=$'\r'; fi
  if [ -s "$arq" ] && [ -n "$(tail -c1 "$arq" | tr -d '\r')" ]; then printf '%s\n' "$cr" >>"$arq"; fi
  for l in "$@"; do printf '%s%s\n' "$l" "$cr"; done >>"$arq"
}

# Acrescenta PADRÃO ao ARQUIVO (.gitignore, .dockerignore) se ainda não estiver lá em nenhuma
# das formas equivalentes (x, /x, x/, /x/). Ignora o CRLF de arquivos editados no Windows.
garantir_ignorado() {
  local arq="$DESTINO/$1" padrao="$2" norm conteudo=""
  norm="$(sed -E 's#^/##; s#/+$##' <<<"$padrao")"
  if [ -f "$arq" ]; then conteudo="$(tr -d '\r' <"$arq" | sed -E 's#^/##; s#/+$##')"; fi
  grep -qxF "$norm" <<<"$conteudo" && return 0
  acrescentar "$arq" "$padrao"
  printf '  %s%s%s %s: %s\n' "$VERDE" "$I_NOVO" "$RESET" "$1" "$padrao"
}

# Variáveis usadas no código e ausentes do .env.example: o setup-host.sh cria o .env a partir dele
ENV_NOVAS=0
completar_env_example() {
  local ex="$DESTINO/.env.example" existentes="" v novos=() linhas
  [ "${#ENV_CODIGO[@]}" -gt 0 ] || return 0
  if [ -f "$ex" ]; then
    existentes="$(tr -d '\r' <"$ex" | sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p')"
  fi
  for v in "${ENV_CODIGO[@]}"; do grep -qxF "$v" <<<"$existentes" || novos+=("$v"); done
  [ "${#novos[@]}" -gt 0 ] || return 0
  linhas=()
  if [ -s "$ex" ]; then linhas+=(""); fi
  linhas+=("# Usadas no código e ausentes deste modelo (acrescentadas pelo scaffold.sh): preencha ou apague")
  for v in "${novos[@]}"; do linhas+=("$v="); done
  acrescentar "$ex" "${linhas[@]}"
  printf '  %s%s%s .env.example: %s\n' "$VERDE" "$I_NOVO" "$RESET" "${novos[*]}"
  ENV_NOVAS=${#novos[@]}
}

# next.config com output: "standalone" (o Dockerfile da stack copia .next/standalone)
RE_NEXT_CFG='((const|let|var) +(nextConfig|config)([[:space:]]*:[^=]*)?[[:space:]]*=[[:space:]]*|export +default +|module\.exports *= *)\{[[:space:]]*$'
RE_NEXT_CFG_VAZIO='((const|let|var) +(nextConfig|config)([[:space:]]*:[^=]*)?[[:space:]]*=[[:space:]]*|export +default +|module\.exports *= *)\{ ?\}'
ajustar_next_config() {
  NEXT_CFG="$(ls "$DESTINO"/next.config.ts "$DESTINO"/next.config.mjs "$DESTINO"/next.config.js \
    "$DESTINO"/next.config.cjs 2>/dev/null | head -1 || true)"
  NEXT_STANDALONE=falta
  [ -n "$NEXT_CFG" ] || return 0
  if grep -q standalone "$NEXT_CFG"; then
    NEXT_STANDALONE=ok
  elif grep -qE "$RE_NEXT_CFG|$RE_NEXT_CFG_VAZIO" "$NEXT_CFG"; then
    # Linha a linha, em vez de sed -i: preserva o CRLF, que o sed do Git Bash tira do arquivo todo
    local tmp linha feito=0
    tmp="$(mktemp)"
    while IFS= read -r linha || [ -n "$linha" ]; do
      # Objeto vazio numa linha só: const nextConfig = {};
      if [ "$feito" = 0 ] && [[ "$linha" =~ $RE_NEXT_CFG_VAZIO ]]; then
        linha="${linha/\{\}/\{ output: \"standalone\" \}}"
        linha="${linha/\{ \}/\{ output: \"standalone\" \}}"
        feito=1
      fi
      printf '%s\n' "$linha"
      if [ "$feito" = 0 ] && [[ "$linha" =~ $RE_NEXT_CFG ]]; then
        printf '  output: "standalone",%s\n' "$([[ "$linha" == *$'\r' ]] && printf '\r')"
        feito=1
      fi
    done <"$NEXT_CFG" >"$tmp"
    cat "$tmp" >"$NEXT_CFG"
    rm -f "$tmp"
    NEXT_STANDALONE=adicionado
    printf '  %s~%s %s: output: "standalone" acrescentado\n' "$AMARELO" "$RESET" "$(basename "$NEXT_CFG")"
  fi
}

gerar() {
  local origem="$1" destino="$DESTINO/$2" tmp
  # --upgrade: refaz só o que este projeto gerou (tem a marca); o resto é do sistema
  if [ -e "$destino" ] && [ "$UPGRADE" = 1 ] && grep -q "Gerado pelo zero-downtime-deploy" "$destino"; then
    tmp="$(mktemp)"
    preencher < "$AQUI/modelos/$origem" > "$tmp"
    if cmp -s "$tmp" "$destino"; then
      printf '  %s%s %s  (igual)%s\n' "$FRACO" "$I_MANTIDO" "$2" "$RESET"
      MANTIDOS=$((MANTIDOS + 1))
    else
      cat "$tmp" > "$destino"
      printf '  %s↻%s %s  (atualizado)\n' "$CIANO" "$RESET" "$2"
      ATUALIZADOS=$((ATUALIZADOS + 1))
    fi
    rm -f "$tmp"
    return
  fi
  if [ -e "$destino" ]; then
    printf '  %s%s %s  (já existe, mantido)%s\n' "$FRACO" "$I_MANTIDO" "$2" "$RESET"
    MANTIDOS=$((MANTIDOS + 1))
    return
  fi
  mkdir -p "$(dirname "$destino")"
  preencher < "$AQUI/modelos/$origem" > "$destino"
  printf '  %s%s%s %s\n' "$VERDE" "$I_NOVO" "$RESET" "$2"
  CRIADOS=$((CRIADOS + 1))
}

montar_testes
montar_blocos
export SEM_HML
if [ "$SEM_HML" = 1 ]; then BRANCHES="$PROD_BRANCH"; else BRANCHES="$PROD_BRANCH, $HML_BRANCH"; fi
CRIADOS=0 MANTIDOS=0 ATUALIZADOS=0
printf '%s%s Gerando em %s%s\n' "$NEGRITO$AZUL" "$I_ETAPA" "$DESTINO" "$RESET"
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
  printf '%s%s Stack %s%s\n' "$NEGRITO$AZUL" "$I_ETAPA" "$STACK" "$RESET"
  ex="$AQUI/examples/$STACK"
  while IFS= read -r arquivo; do
    rel="${arquivo#"$ex"/}"
    case "$rel" in
      README.md | stack.conf) continue ;;
      src/*)
        # Projeto sem src/ (app/ e lib/ na raiz): o Next ignoraria src/app, e a rota de saúde não existiria
        if [ ! -d "$DESTINO/src" ] && { [ -d "$DESTINO/app" ] || [ -d "$DESTINO/lib" ]; }; then rel="${rel#src/}"; fi
        # Projeto em JavaScript: um .ts faria o Next exigir TypeScript e parar o build. Os arquivos
        # das stacks não têm anotação de tipo, então servem como .js
        if [ ! -f "$DESTINO/tsconfig.json" ]; then
          case "$rel" in *.tsx) rel="${rel%.tsx}.jsx" ;; *.ts) rel="${rel%.ts}.js" ;; esac
        fi
        ;;
      gitignore)
        # Linhas que faltam no .gitignore do sistema
        while IFS= read -r linha; do
          [[ -z "$linha" || "$linha" == \#* ]] && continue
          garantir_ignorado .gitignore "$linha"
        done < "$arquivo"
        continue
        ;;
    esac
    if [ -e "$DESTINO/$rel" ]; then
      printf '  %s%s %s  (já existe, mantido)%s\n' "$FRACO" "$I_MANTIDO" "$rel" "$RESET"
      MANTIDOS=$((MANTIDOS + 1))
    else
      mkdir -p "$(dirname "$DESTINO/$rel")"
      preencher <"$arquivo" >"$DESTINO/$rel"
      printf '  %s%s%s %s\n' "$VERDE" "$I_NOVO" "$RESET" "$rel"
      CRIADOS=$((CRIADOS + 1))
    fi
  done < <(find "$ex" -type f | sort)
fi

# Pastas montadas: fora do git e fora da imagem (documentos de usuários não podem ir para a imagem)
if [ "${#VOLUMES[@]}" -gt 0 ]; then
  printf '%s%s Pastas montadas%s\n' "$NEGRITO$AZUL" "$I_ETAPA" "$RESET"
  for v in "${VOLUMES[@]}"; do
    garantir_ignorado .gitignore "/$v/"
    garantir_ignorado .dockerignore "$v"
  done
fi

printf '%s%s Configuração%s\n' "$NEGRITO$AZUL" "$I_ETAPA" "$RESET"
escrever_conf
if [ -f "$DESTINO/.dockerignore" ]; then garantir_ignorado .dockerignore deploy.conf; fi

printf '%s%s Código%s\n' "$NEGRITO$AZUL" "$I_ETAPA" "$RESET"
completar_env_example
NEXT_STANDALONE=""
if [ "$STACK_NEXTJS" = 1 ]; then ajustar_next_config; fi
for f in "${FORCE_PAGINAS[@]}"; do aplicar_force_dynamic "$f"; done
if [ "$ENV_NOVAS" = 0 ] && [ "$NEXT_STANDALONE" != adicionado ]; then
  printf '  %s%s nada a ajustar%s\n' "$FRACO" "$I_MANTIDO" "$RESET"
fi

# Validação: o Dockerfile compila? O next build pré-renderiza páginas, e no build não há banco
BUILD_OK="" BUILD_LOG=""
if [ "$CHECK_BUILD" = 1 ]; then
  printf '%s%s Validação%s\n' "$NEGRITO$AZUL" "$I_ETAPA" "$RESET"
  if ! command -v docker >/dev/null || ! docker info >/dev/null 2>&1; then
    printf '  %s%s Docker indisponível nesta máquina: a validação fica para o primeiro deploy%s\n' "$AMARELO" "$I_AVISO" "$RESET"
  elif [ ! -f "$DESTINO/Dockerfile" ]; then
    printf '  %s%s Sem Dockerfile: nada a validar%s\n' "$AMARELO" "$I_AVISO" "$RESET"
  else
    # O next build para na primeira página que falha: cada volta revela a seguinte
    tentativas=5
    while [ "$tentativas" -gt 0 ]; do
      tentativas=$((tentativas - 1))
      if validar_build; then
        BUILD_OK=1
        printf '  %s%s%s A imagem compila\n' "$VERDE" "$I_OK" "$RESET"
        break
      fi
      BUILD_OK=0
      mapfile -t rotas < <(rotas_com_erro)
      mapfile -t paginas < <(printf '%s\n' "${rotas[@]}" | grep -v '^$' | paginas_das_rotas | sort -u)
      if [ "${#paginas[@]}" -eq 0 ] || [ "$tentativas" -eq 0 ]; then
        printf '  %s%s A imagem não compila. Últimas linhas (log completo em %s):%s\n' "$VERMELHO" "$I_ERRO" "$BUILD_LOG" "$RESET"
        tail -20 "$BUILD_LOG" | sed 's/^/      /'
        break
      fi
      printf '  %s%s O build quebrou ao gerar %s (sem banco no build)%s\n' "$AMARELO" "$I_AVISO" "${rotas[*]}" "$RESET"
      aplicar=0
      if [ "$FORCE_DYNAMIC" = 1 ]; then
        aplicar=1
      elif [ "$INTERATIVO" = 1 ] && sim_nao "Acrescentar force-dynamic em ${paginas[*]} e compilar de novo?" s; then
        aplicar=1
      fi
      [ "$aplicar" = 1 ] || break
      for f in "${paginas[@]}"; do aplicar_force_dynamic "$f"; FORCE_PAGINAS+=("$f"); done
    done
  fi
fi

# Marcador esquecido em algum modelo
if grep -rnoE '\{\{[A-Z_]+\}\}' "$DESTINO"/deploy.sh "$DESTINO"/compose.*.yml "$DESTINO"/nginx 2>/dev/null; then
  printf '%s%s Atenção: sobraram marcadores acima sem valor%s\n' "$AMARELO" "$I_AVISO" "$RESET" >&2
fi

echo
if [ "$ATUALIZADOS" -gt 0 ]; then
  printf '%s%s %d arquivo(s) atualizado(s) pelo --upgrade: revise com git diff%s\n' "$CIANO" "$I_OK" "$ATUALIZADOS" "$RESET"
fi
printf '%s%s %d arquivo(s) criado(s)%s%s\n' "$VERDE" "$I_OK" "$CRIADOS" "$RESET" \
  "$([ "$MANTIDOS" -gt 0 ] && echo "$FRACO, $MANTIDOS já existiam e foram mantidos$RESET")"
echo
printf '%s%s Falta fazer no repositório:%s\n' "$NEGRITO$AZUL" "$I_ETAPA" "$RESET"
item() { printf '  %s%s%s %s\n' "$AMARELO" "$I_ITEM" "$RESET" "$1"; }
if [ -z "$STACK" ]; then
  item "Dockerfile, se ainda não houver (com WORKDIR /app: os volumes montam em /app/<pasta>)"
  item "a rota $HEALTH, respondendo 200 só com a aplicação pronta (e sem exigir login)"
  item "compose.migrate.yml, se o sistema tiver migração de banco (veja o README)"
  if [ "${#NEXT_PUBLIC[@]}" -gt 0 ]; then
    item "no Dockerfile, ARG ${NEXT_PUBLIC[*]} no estágio do build (o compose já as passa)"
  fi
else
  item "revisar os arquivos copiados de examples/$STACK (veja o README da stack)"
  if [ "$STACK_HEALTH_PROPRIA" = 1 ]; then
    item "a rota $HEALTH, respondendo 200 só com a aplicação pronta, na porta $PORTA_APP (e sem exigir login)"
  fi
  if [ "$STACK" = dockerfile ]; then
    item "no Dockerfile: WORKDIR /app (os volumes montam em /app/<pasta>) e wget, curl ou node na imagem (health check)"
  fi
fi
if [ "$NEXT_STANDALONE" = falta ]; then
  item "next.config: acrescentar output: \"standalone\" (não consegui fazer sozinho)"
fi
# Server Actions recusam pedidos de origem que não esteja em allowedOrigins: confere uma por uma
if [ "$STACK_NEXTJS" = 1 ] && tem_no_codigo "${Q}use server$Q"; then
  necessarias=("$DOMINIO_PROD")
  if [ "$SEM_HML" = 0 ]; then
    necessarias+=("$DOMINIO_HML:$PORTA_HML")
    [[ "$DOMINIO_HML" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || necessarias+=("$DOMINIO_HML")
  fi
  if [ -n "$IP_PROD" ]; then necessarias+=("$IP_PROD"); fi
  faltam=""
  for o in "${necessarias[@]}"; do
    grep -qsF "$o" "${NEXT_CFG:-/dev/null}" || faltam+="${faltam:+, }\"$o\""
  done
  if [ -n "$faltam" ]; then
    item "next.config: incluir $faltam em experimental.serverActions.allowedOrigins (o código usa Server Actions)"
  fi
fi
if [ "$ENV_NOVAS" -gt 0 ]; then
  item "preencher ou apagar as $ENV_NOVAS variáveis acrescentadas ao .env.example (o .env da VM sai dele)"
fi
outros_env="$(cd "$DESTINO" && ls -d .env.exemple .env.sample .env.dist example.env env.example 2>/dev/null | tr '\n' ' ' || true)"
if [ -n "$outros_env" ] && [ -f "$DESTINO/.env.example" ]; then
  item "apagar ${outros_env% }: o setup-host.sh usa o .env.example, deixe um modelo só"
fi
if [ "${#TESTE_CMDS[@]}" -gt 0 ]; then
  testes="$(printf '%s · ' "${TESTE_CMDS[@]}")"
  item "conferir o job test gerado (Node $TESTE_NODE): ${testes% · }"
else
  item 'os testes no job "test" do CI'
fi
if [ "${#DESATIVAR[@]}" -gt 0 ]; then
  if [ "$CI_ANTIGO_TESTES" = 1 ]; then
    item "o pipeline antigo rodava testes: confira se o job test novo cobre o mesmo, depois apague os .bak"
  else
    item "apagar os .bak dos pipelines antigos depois de conferir: $(printf '%s.bak ' "${DESATIVAR[@]}")"
  fi
fi
for e in "${CIS_ANTIGOS[@]}"; do
  f="${e%%|*}"
  printf '%s\n' "${DESATIVAR[@]}" | grep -qxF "$f" && continue
  if [ "$f" = "$ARQ_CI" ]; then
    item "$f é o pipeline antigo (${e#*|}) e o CI novo não foi gerado no lugar dele: rode de novo com --replace-ci"
  else
    item "$f continua ativo e faz deploy antigo (${e#*|}): cada push faria dois deploys. Desative-o (--replace-ci)"
  fi
done
if [ "${#OBSOLETOS[@]}" -gt 0 ]; then
  item "obsoletos com o deploy novo, apague depois da troca na VM: ${OBSOLETOS[*]}"
fi
if [ "$STACK_NEXTJS" = 1 ]; then
  for f in "${PAGINAS_BANCO[@]}"; do
    printf '%s\n' "${FORCE_PAGINAS[@]}" | grep -qxF "$f" && continue
    item "$f consulta o banco e seria gerada no build (sem banco): use export const dynamic = \"force-dynamic\" (--force-dynamic)"
  done
fi
if [ "$BUILD_OK" = 0 ]; then
  item "a imagem não compila: corrija e valide com docker build (log em $BUILD_LOG)"
elif [ "$CHECK_BUILD" != 1 ] && [ -f "$DESTINO/Dockerfile" ]; then
  item "validar a imagem antes do push: docker build $( grep -qiE '^FROM .* AS runner' "$DESTINO/Dockerfile" && echo '--target runner ')."
fi
if [ "$CI" = gitlab ]; then
  item "o runner da VM precisa da tag $TAG_RUNNER (ou troque tags: no .gitlab-ci.yml)"
fi
if [ "$SEM_HML" = 1 ]; then
  item "commit e push na branch $PROD_BRANCH; depois, na VM: setup-host.sh com --no-staging"
else
  item "commit e push nas branches $PROD_BRANCH e $HML_BRANCH; depois, na VM: bash setup-host.sh"
fi
}
