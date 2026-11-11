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

  bash scaffold.sh --sistema siscon \
    --dominio-prod siscon.saoluis.ma.gov.br --dominio-hml hml-siscon.saoluis.ma.gov.br \
    --porta-app 3000 --health /api/health  /caminho/do/repositorio

Opções:
  --sistema NOME              obrigatório; o mesmo usado no setup-host.sh
  --dominio-prod DOMINIO      obrigatório
  --dominio-hml DOMINIO       obrigatório, a não ser com --sem-homologacao
  --sem-homologacao           só produção: sem o ambiente de homologação (nem porta 3001, nem
                              branch, nem job de deploy dele)
  --porta-app PORTA           porta da aplicação dentro do contêiner (padrão: 3000)
  --health CAMINHO            rota que responde 200 com a aplicação saudável (padrão: /api/health)
  --porta-hml PORTA           porta de homologação na VM (padrão: 3001)
  --prod-nome / --prod-branch padrão: production / main
  --hml-nome  / --hml-branch  padrão: developer / dev
  --ci github|gitlab          padrão: github
  --stack NOME                copia também os arquivos de examples/NOME (ex.: nextjs-prisma):
                              Dockerfile, .dockerignore, migração, rota de saúde, .env.example
  --substituir-ci             move um CI antigo (não gerado por este projeto) para .bak
  --volume PASTA              pasta onde a aplicação grava arquivos (ex.: public/uploads), montada
                              fora do contêiner para não se perder no deploy; repita para várias.
                              Sem --volume, o script procura no código (padrão: uploads)
  --sem-volume                nenhuma pasta montada
  --copiar PASTA              pasta lida em tempo de execução (ex.: data), copiada para a imagem
                              (stack Next.js); sem a opção, o script procura no código
  --limite-upload TAMANHO     maior envio aceito pelo Nginx (padrão: 25m)
  --ip-prod IP                o IP da VM na porta 80 abre a produção (padrão: acesso por IP recusado)
  --tag-runner TAG            tag do runner da VM no GitLab (padrão: o nome do sistema)
  -i, --interativo            pergunta o que faltar, mesmo com as opções obrigatórias informadas
  --nao-interativo            nunca pergunta: falta de opção obrigatória é erro

Modo interativo: sem as opções obrigatórias e num terminal, o script pergunta o que faltar.
Ele lê o repositório (remoto, branches, package.json, CI existente) para sugerir as respostas,
com listas de escolha, e no fim mostra o comando equivalente:

  bash scaffold.sh

Sem o repositório zero-downtime-deploy na máquina, pelo curl (baixa os modelos para uma pasta
temporária, apagada no fim; ZDD_REF escolhe a versão, ex.: ZDD_REF=v2.0.0):

  bash <(curl -fsSL https://raw.githubusercontent.com/kauacolins/zero-downtime-deploy/master/scaffold.sh)

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
INTERATIVO=auto SUBSTITUIR_CI=0
VOLUMES=() VOLUMES_DEF=0 COPIAR=() COPIAR_DEF=0 LIMITE_UPLOAD="" IP_PROD="" TAG_RUNNER=""

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
    --sem-homologacao) SEM_HML=1; SEM_HML_DEF=1; shift ;;
    --ci) CI="$2"; shift 2 ;;
    --stack) STACK="$2"; STACK_DEFINIDA=1; shift 2 ;;
    --substituir-ci) SUBSTITUIR_CI=1; shift ;;
    --volume) VOLUMES+=("$2"); VOLUMES_DEF=1; shift 2 ;;
    --sem-volume) VOLUMES=(); VOLUMES_DEF=1; shift ;;
    --copiar) COPIAR+=("$2"); COPIAR_DEF=1; shift 2 ;;
    --limite-upload) LIMITE_UPLOAD="$2"; shift 2 ;;
    --ip-prod) IP_PROD="$2"; shift 2 ;;
    --tag-runner) TAG_RUNNER="$2"; shift 2 ;;
    -i|--interativo) INTERATIVO=1; shift ;;
    --nao-interativo) INTERATIVO=0; shift ;;
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
  grep_fontes -hoE "process\.env\.[A-Z_][A-Z0-9_]*|process\.env\[$Q[A-Z_][A-Z0-9_]*$Q\]" \
    | sed -E 's/^process\.env(\.|\[.)//; s/[^A-Z0-9_].*$//' | sort -u \
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
  if [ "$IS_NEXT" = 1 ]; then mapfile -t NEXT_PUBLIC < <(grep_fontes -hoE 'NEXT_PUBLIC_[A-Z0-9_]+' | sort -u); fi
  mapfile -t ENV_CODIGO < <(detectar_env)
}

# Opções para escolher_varios, todas marcadas: define OPCOES e MARCADOS
todas_marcadas() {
  local v i=1
  OPCOES=() MARCADOS=""
  for v in "$@"; do OPCOES+=("$v|$v"); MARCADOS+="${MARCADOS:+ }$i"; i=$((i + 1)); done
}

# Faltou algo obrigatório e há terminal: pergunta em vez de parar
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

  analisar_repositorio
  if [ "$VOLUMES_DEF" = 0 ]; then
    extra=""
    if [ "${#DET_VOLUMES[@]}" -gt 0 ]; then
      todas_marcadas "${DET_VOLUMES[@]}"
      escolher_varios VOLUMES "Pastas onde a aplicação grava arquivos (montadas fora do contêiner, não se perdem no deploy)" "$MARCADOS" "${OPCOES[@]}"
      perguntar extra "Outras pastas, separadas por espaço (Enter: nenhuma)" "" '^[A-Za-z0-9._/ -]*$'
    else
      perguntar extra "Pastas onde a aplicação grava arquivos, separadas por espaço (0: nenhuma)" uploads '^([A-Za-z0-9._/ -]+|0)$'
      [ "$extra" != 0 ] || extra=""
    fi
    for v in $extra; do VOLUMES+=("$v"); done
    VOLUMES_DEF=1
  fi
  if [[ "$STACK" == nextjs* ]] && [ "$COPIAR_DEF" = 0 ]; then
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

  if sim_nao "Ajustar portas, rota de saúde, limite de upload ou nomes dos ambientes? (padrões: 3000, /api/health, 3001, 25m, production, developer)" n; then
    perguntar PORTA_APP "Porta da aplicação dentro do contêiner" "${PORTA_APP:-3000}" '^[0-9]+$'
    perguntar HEALTH "Rota de saúde (200 só com a aplicação pronta, sem login)" "${HEALTH:-/api/health}" '^/'
    if [ "$SEM_HML" = 0 ]; then perguntar PORTA_HML "Porta de homologação na VM" "${PORTA_HML:-3001}" '^[0-9]+$'; fi
    perguntar LIMITE_UPLOAD "Maior envio aceito pelo Nginx (um pouco acima do limite da aplicação)" "${LIMITE_UPLOAD:-25m}" '^[0-9]+[kKmMgG]?$'
    perguntar PROD_NOME "Nome do ambiente de produção (pasta na VM)" "${PROD_NOME:-production}" '^[a-z0-9_-]+$'
    if [ "$SEM_HML" = 0 ]; then perguntar HML_NOME "Nome do ambiente de homologação (pasta na VM)" "${HML_NOME:-developer}" '^[a-z0-9_-]+$'; fi
  fi
fi

PORTA_APP="${PORTA_APP:-3000}" HEALTH="${HEALTH:-/api/health}" PORTA_HML="${PORTA_HML:-3001}"
PROD_NOME="${PROD_NOME:-production}" PROD_BRANCH="${PROD_BRANCH:-main}"
HML_NOME="${HML_NOME:-developer}" HML_BRANCH="${HML_BRANCH:-dev}" CI="${CI:-github}"

[ -n "$SISTEMA" ] && [ -n "$DOMINIO_PROD" ] && { [ -n "$DOMINIO_HML" ] || [ "$SEM_HML" = 1 ]; } && [ -n "$DESTINO" ] || uso 1
[[ "$SISTEMA" =~ ^[a-z0-9_]+$ ]] || { echo "--sistema aceita só minúsculas, números e _ (vira nome de contêiner)" >&2; exit 1; }
[[ "$CI" =~ ^(github|gitlab)$ ]] || { echo "--ci aceita github ou gitlab" >&2; exit 1; }
[ -d "$DESTINO" ] || { echo "Pasta não encontrada: $DESTINO" >&2; exit 1; }
[ -d "$AQUI/modelos" ] || { echo "Pasta modelos/ não encontrada ao lado do script" >&2; exit 1; }
if [ -n "$STACK" ] && [ ! -d "$AQUI/examples/$STACK" ]; then
  echo "Stack desconhecida: $STACK. Disponíveis: $(ls "$AQUI/examples" | tr '\n' ' ')" >&2
  exit 1
fi
LIMITE_UPLOAD="${LIMITE_UPLOAD:-25m}" TAG_RUNNER="${TAG_RUNNER:-$SISTEMA}"
[[ "$LIMITE_UPLOAD" =~ ^[0-9]+[kKmMgG]?$ ]] || falha "--limite-upload aceita um tamanho como 12m"
[ -z "$IP_PROD" ] || [[ "$IP_PROD" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || falha "--ip-prod aceita um IPv4"
[[ "$TAG_RUNNER" =~ ^[A-Za-z0-9_.-]+$ ]] || falha "--tag-runner aceita letras, números, _, . e -"

[ -n "$FONTES" ] || analisar_repositorio
if [ "$VOLUMES_DEF" = 0 ]; then
  if [ "${#DET_VOLUMES[@]}" -gt 0 ]; then VOLUMES=("${DET_VOLUMES[@]}"); else VOLUMES=(uploads); fi
fi
# Caminhos relativos à raiz do repositório, sem ./ nem / no fim
for i in "${!VOLUMES[@]}"; do
  v="${VOLUMES[$i]#./}"; v="${v%/}"; VOLUMES[$i]="$v"
  [[ "$v" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "$v" != *..* ]] || falha "pasta inválida em --volume: $v"
done
if [[ "$STACK" == nextjs* ]] && [ "$COPIAR_DEF" = 0 ]; then mapfile -t COPIAR < <(detectar_copiar); fi
for v in "${COPIAR[@]}"; do
  [[ "$v" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "$v" != *..* ]] || falha "pasta inválida em --copiar: $v"
done

# CI que já existe e não foi gerado por este projeto (ex.: git pull + pm2 restart)
if [ "$CI" = gitlab ]; then ARQ_CI=.gitlab-ci.yml; else ARQ_CI=.github/workflows/deploy.yml; fi
CI_ANTIGO=0 CI_ANTIGO_TESTES=0
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
  cmd="$CHAMADA --sistema $SISTEMA --dominio-prod $DOMINIO_PROD"
  if [ "$SEM_HML" = 1 ]; then
    cmd+=" --sem-homologacao --prod-branch $PROD_BRANCH --ci $CI"
  else
    cmd+=" --dominio-hml $DOMINIO_HML --prod-branch $PROD_BRANCH --hml-branch $HML_BRANCH --ci $CI"
  fi
  if [ -n "$STACK" ]; then cmd+=" --stack $STACK"; fi
  if [ "$PORTA_APP" != 3000 ]; then cmd+=" --porta-app $PORTA_APP"; fi
  if [ "$HEALTH" != /api/health ]; then cmd+=" --health $HEALTH"; fi
  if [ "$PORTA_HML" != 3001 ] && [ "$SEM_HML" = 0 ]; then cmd+=" --porta-hml $PORTA_HML"; fi
  if [ "$PROD_NOME" != production ]; then cmd+=" --prod-nome $PROD_NOME"; fi
  if [ "$HML_NOME" != developer ] && [ "$SEM_HML" = 0 ]; then cmd+=" --hml-nome $HML_NOME"; fi
  if [ "$SUBSTITUIR_CI" = 1 ]; then cmd+=" --substituir-ci"; fi
  if [ "${#VOLUMES[@]}" -eq 0 ]; then cmd+=" --sem-volume"; fi
  for v in "${VOLUMES[@]}"; do cmd+=" --volume $v"; done
  for v in "${COPIAR[@]}"; do cmd+=" --copiar $v"; done
  if [ "$LIMITE_UPLOAD" != 25m ]; then cmd+=" --limite-upload $LIMITE_UPLOAD"; fi
  if [ -n "$IP_PROD" ]; then cmd+=" --ip-prod $IP_PROD"; fi
  if [ "$CI" = gitlab ] && [ "$TAG_RUNNER" != "$SISTEMA" ]; then cmd+=" --tag-runner $TAG_RUNNER"; fi
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
  linha CI "$CI$([ "$SUBSTITUIR_CI" = 1 ] && echo "  ${FRACO}(o atual vai para .bak)$RESET")"
  linha Stack "${STACK:-nenhuma}"
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

if [ "$CI_ANTIGO" = 1 ] && [ "$SUBSTITUIR_CI" = 1 ]; then
  mv "$DESTINO/$ARQ_CI" "$DESTINO/$ARQ_CI.bak"
  if grep -qiE 'jest|vitest|tsc|npm (run )?test|pytest|mvn|gradle' "$DESTINO/$ARQ_CI.bak"; then CI_ANTIGO_TESTES=1; fi
  printf '  %s%s%s %s antigo movido para %s.bak\n' "$AMARELO" "$I_MOVIDO" "$RESET" "$ARQ_CI" "$ARQ_CI"
fi

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

  if [ "${#VOLUMES[@]}" -gt 0 ]; then
    BLOCO_VOLUMES="    volumes:"
    for v in "${VOLUMES[@]}"; do BLOCO_VOLUMES+="$NL      - ./$v:/app/$v"; done
    BLOCO_CRIAR_PASTAS="# Pastas montadas como volume: criadas aqui, com o dono certo (o Docker as criaria como root)"
    BLOCO_CRIAR_PASTAS+="${NL}mkdir -p ${VOLUMES[*]}"
  else
    BLOCO_VOLUMES="    # Sem pastas montadas (--volume): o que a aplicação gravar se perde no deploy"
  fi

  if [ "${#NEXT_PUBLIC[@]}" -gt 0 ]; then
    BLOCO_BUILD_ARGS="      # NEXT_PUBLIC_* são gravadas no build: o valor vem do .env desta pasta${NL}      args:"
    BLOCO_BUILD_ARGS_DOCKERFILE="# NEXT_PUBLIC_* são gravadas no build; o compose as passa a partir do .env de cada pasta"
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
  export BLOCO_VOLUMES BLOCO_CRIAR_PASTAS BLOCO_BUILD_ARGS BLOCO_BUILD_ARGS_DOCKERFILE \
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
ajustar_next_config() {
  NEXT_CFG="$(ls "$DESTINO"/next.config.ts "$DESTINO"/next.config.mjs "$DESTINO"/next.config.js \
    "$DESTINO"/next.config.cjs 2>/dev/null | head -1 || true)"
  NEXT_STANDALONE=falta
  [ -n "$NEXT_CFG" ] || return 0
  if grep -q standalone "$NEXT_CFG"; then
    NEXT_STANDALONE=ok
  elif grep -qE "$RE_NEXT_CFG" "$NEXT_CFG"; then
    # Linha a linha, em vez de sed -i: preserva o CRLF, que o sed do Git Bash tira do arquivo todo
    local tmp linha feito=0
    tmp="$(mktemp)"
    while IFS= read -r linha || [ -n "$linha" ]; do
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
  local origem="$1" destino="$DESTINO/$2"
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
CRIADOS=0 MANTIDOS=0
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
      README.md) continue ;;
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

printf '%s%s Código%s\n' "$NEGRITO$AZUL" "$I_ETAPA" "$RESET"
completar_env_example
NEXT_STANDALONE=""
if [[ "$STACK" == nextjs* ]]; then ajustar_next_config; fi
if [ "$ENV_NOVAS" = 0 ] && [ "$NEXT_STANDALONE" != adicionado ]; then
  printf '  %s%s nada a ajustar%s\n' "$FRACO" "$I_MANTIDO" "$RESET"
fi

# Marcador esquecido em algum modelo
if grep -rnoE '\{\{[A-Z_]+\}\}' "$DESTINO"/deploy.sh "$DESTINO"/compose.*.yml "$DESTINO"/nginx 2>/dev/null; then
  printf '%s%s Atenção: sobraram marcadores acima sem valor%s\n' "$AMARELO" "$I_AVISO" "$RESET" >&2
fi

echo
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
fi
if [ "$NEXT_STANDALONE" = falta ]; then
  item "next.config: acrescentar output: \"standalone\" (não consegui fazer sozinho)"
fi
# Server Actions recusam pedidos de origem que não esteja em allowedOrigins: confere uma por uma
if [[ "$STACK" == nextjs* ]] && tem_no_codigo "${Q}use server$Q"; then
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
if [ "$CI_ANTIGO" = 1 ] && [ "$SUBSTITUIR_CI" = 1 ]; then
  if [ "$CI_ANTIGO_TESTES" = 1 ]; then
    item "o CI antigo rodava testes: confira se o job test novo cobre o mesmo, depois apague $ARQ_CI.bak"
  else
    item "apagar $ARQ_CI.bak depois de conferir"
  fi
  if [ -d "$DESTINO/.gitlab/ci" ]; then item "apagar .gitlab/ci/, se só o CI antigo a usava"; fi
fi
if [ "$CI" = gitlab ]; then
  item "o runner da VM precisa da tag $TAG_RUNNER (ou troque tags: no .gitlab-ci.yml)"
fi
if [ "$SEM_HML" = 1 ]; then
  item "commit e push na branch $PROD_BRANCH; depois, na VM: setup-host.sh com --sem-homologacao"
else
  item "commit e push nas branches $PROD_BRANCH e $HML_BRANCH; depois, na VM: bash setup-host.sh"
fi
}
