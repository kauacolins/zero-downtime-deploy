#!/usr/bin/env bash
# setup-host.sh: prepara uma VM Ubuntu para deploy blue-green de qualquer sistema,
# com homologação e produção na mesma máquina. Ajuda: bash setup-host.sh --help
# Documentação: README.md do repositório.
set -euo pipefail

# Tudo entre { e } é lido antes de rodar. Pelo curl ... | bash, o bash lê o script pela entrada
# padrão aos poucos, e um comando do meio que lesse a entrada comeria o resto do script.
{

# ---------------------------------------------------------------------------
# Parâmetros
FORGE=github GIT_HOST=github.com FORGE_DEFINIDO=0
# Branches e --deploy vazios até o fim da leitura: o modo interativo só pergunta o que não veio
SISTEMA="" PROD_NOME=production PROD_BRANCH="" HML_NOME=developer HML_BRANCH=""
SEGREDOS="" PG_HML="" PG_URL="" PG_URL_USADA=0 CLONAR=1 DEPLOY="" SIM=0 INTERATIVO=auto
REPOS=() PG_ACESSOS=() ENV_TODOS=() ENV_PROD=() ENV_HML=()
SEGREDOS_PERGUNTADO=0 RETOMADO=0 ESTADO_ATIVO=0
# Só produção (--no-staging): sem clone, .env, banco nem deploy de homologação
SEM_HML=0 SEM_HML_DEF=0
# Instalação atual de cada repositório (deploy antigo): "DONO/REPO=/pasta" ou só "/pasta"
ORIGENS=()

VERSAO=2.0.0
# Como chamar de novo: pelo arquivo, ou pelo curl quando veio de bash <(curl ...) ou curl ... | bash
case "$0" in
  *setup-host.sh) CHAMADA="bash $0" ;;
  *) CHAMADA="bash <(curl -fsSL https://raw.githubusercontent.com/kauacolins/zero-downtime-deploy/${ZDD_REF:-master}/setup-host.sh)" ;;
esac

# Texto embutido: funciona também quando o script vem direto do curl, sem arquivo
uso() {
  echo "setup-host.sh $VERSAO"
  echo
  cat <<'AJUDA'
Prepara uma VM Ubuntu para deploy blue-green de qualquer sistema, com homologação e
produção na mesma máquina. Pode ser rodado de novo: cada etapa pula o que já está feito.

Rode com o usuário do deploy (não como root), que precisa de sudo. Exemplos:

  # Um repositório (Siscon): /opt/siscon/{production,developer}
  bash setup-host.sh --system siscon --repo SEMIT-SUAS/siscon \
    --pg-staging siscon_hml --secrets "AUTH_SECRET NEXTAUTH_SECRET JWT_SECRET APP_ENCRYPTION_KEY" \
    --env NODE_ENV=production --env-prod NEXTAUTH_URL=https://siscon.saoluis.ma.gov.br \
    --env-staging NEXTAUTH_URL=http://10.0.0.160:3001

  # Vários repositórios (CIS): /opt/cis/{api,frontend}/{production,homolog}
  bash setup-host.sh --system cis --staging-name homolog --staging-branch homolog \
    --repo SEMIT-SUAS/cis-api:api --repo SEMIT-SUAS/cis-frontend:frontend:front

  # GitLab (subgrupos valem): deploy key e runner ficam manuais, com passo a passo
  bash setup-host.sh --system sisx --gitlab gitlab.saoluis.ma.gov.br --repo semit/sisx

Opções:
  --system NOME           obrigatório; as pastas ficam em /opt/NOME
  --no-staging            só produção (o repositório gerado com scaffold.sh --no-staging):
                          sem clone, .env, banco nem deploy de homologação, e só a porta 80
  --repo DONO/REPO[:PASTA[:LABELS]]
                          repetível. PASTA é a subpasta em /opt/NOME (padrão: nenhuma com
                          um repositório, o nome do repositório com vários). LABELS são as
                          labels extras do runner, separadas por vírgula (ex.: front)
  --prod-name / --prod-branch
                          padrão: production / main
  --staging-name / --staging-branch
                          padrão: developer / dev
  --secrets "CHAVE ..."   chaves do .env que recebem segredo aleatório, se ainda
                          estiverem com o valor do arquivo de exemplo
  --env CHAVE=VALOR       repetível; grava no .env dos dois ambientes (ex.: NODE_ENV=production)
  --env-prod / --env-staging CHAVE=VALOR
                          repetíveis; gravam só no .env daquele ambiente (ex.: NEXTAUTH_URL)
  --pg-staging NOME       cria banco e usuário NOME no PostgreSQL da máquina
  --pg-access BANCO:USUARIO
                          repetível; libera o banco para a rede Docker no pg_hba.conf. Os bancos
                          do DATABASE_URL/DIRECT_URL de cada .env já são liberados sem a opção
  --source [DONO/REPO=]PASTA
                          instalação atual do sistema na VM (ex.: o deploy antigo pelo PM2 em
                          /home/suas/sistema). A produção nasce dela: a pasta é copiada (menos
                          node_modules, builds e caches) e o código vai para a versão da branch;
                          .env, credenciais, uploads e o resto que está fora do git vão junto. Os
                          uploads são sincronizados de novo a cada execução. A homologação vem de
                          um clone limpo e recebe o .env sem banco nem URLs. Sem a opção, o modo
                          interativo procura e pergunta
  --gitlab HOST           repositórios no GitLab (gitlab.com ou um servidor próprio). A deploy
                          key e o runner ficam manuais: o script mostra o passo a passo
  --no-clone              não clona (o workflow do sistema cria as pastas sozinho)
  --deploy                roda deploy.sh de cada pasta no final, homologação primeiro
  --yes                   não pergunta antes de parar o PM2 ou o Nginx que ocupa as portas 80/3001
  -i, --interactive       pergunta o que faltar, mesmo com --system e --repo informados
  --non-interactive       nunca pergunta (CI, ssh sem terminal): falta de opção é erro

Modo interativo: sem --system ou --repo e com terminal, o script pergunta o que faltar,
com listas de escolha para branches, bancos do PostgreSQL, segredos e valores do .env.
No fim mostra o comando equivalente, para repetir sem perguntas:

  bash setup-host.sh

Sem baixar o arquivo (ZDD_REF escolhe a versão, ex.: ZDD_REF=v2.0.0); opções vão depois:

  bash <(curl -fsSL https://raw.githubusercontent.com/kauacolins/zero-downtime-deploy/master/setup-host.sh)

As respostas e onde a execução parou ficam em ~/.local/state/zero-downtime-deploy/ (sem o
GH_TOKEN nem os valores do .env). Rodando de novo sem opções, o script oferece continuar com as
mesmas respostas, mostrando as pendências da última vez, ou começar do zero.

Acesso ao GitHub (cadastrar deploy keys e registrar runners; não vale para o GitLab):
  GH_TOKEN   token com escopo repo e admin nos repositórios. Na sua máquina: gh auth token.
             Na VM, cole sem deixar no histórico: read -rs GH_TOKEN && export GH_TOKEN
             Sem ele, o script mostra o que cadastrar à mão e lista como pendência.
AJUDA
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --system|--sistema) SISTEMA="$2"; shift 2 ;;
    --repo) REPOS+=("$2"); shift 2 ;;
    --prod-name|--prod-nome) PROD_NOME="$2"; shift 2 ;;
    --prod-branch) PROD_BRANCH="$2"; shift 2 ;;
    --staging-name|--hml-nome) HML_NOME="$2"; shift 2 ;;
    --staging-branch|--hml-branch) HML_BRANCH="$2"; shift 2 ;;
    --no-staging|--sem-homologacao) SEM_HML=1; SEM_HML_DEF=1; shift ;;
    --secrets|--segredos) SEGREDOS="$2"; shift 2 ;;
    --env) ENV_TODOS+=("$2"); shift 2 ;;
    --env-prod) ENV_PROD+=("$2"); shift 2 ;;
    --env-staging|--env-hml) ENV_HML+=("$2"); shift 2 ;;
    --pg-staging|--pg-hml) PG_HML="$2"; shift 2 ;;
    --pg-access|--pg-acesso) PG_ACESSOS+=("$2"); shift 2 ;;
    --source|--origem) ORIGENS+=("$2"); shift 2 ;;
    --gitlab)
      FORGE=gitlab FORGE_DEFINIDO=1
      GIT_HOST="${2#*://}"
      GIT_HOST="${GIT_HOST%%/*}"
      shift 2
      ;;
    --no-clone|--sem-clone) CLONAR=0; shift ;;
    --deploy) DEPLOY=1; shift ;;
    --yes|--sim) SIM=1; shift ;;
    -i|--interactive|--interativo) INTERATIVO=1; shift ;;
    --non-interactive|--nao-interativo) INTERATIVO=0; shift ;;
    -h|--help) uso ;;
    --versao|--version) echo "setup-host.sh $VERSAO"; exit 0 ;;
    *) echo "Opção desconhecida: $1" >&2; uso 1 ;;
  esac
done

# Faltou --system ou --repo e há terminal: pergunta em vez de parar (-i força, --non-interactive desliga)
if [ "$INTERATIVO" = auto ]; then
  if { [ -z "$SISTEMA" ] || [ "${#REPOS[@]}" -eq 0 ]; } && { : </dev/tty; } 2>/dev/null; then
    INTERATIVO=1
  else
    INTERATIVO=0
  fi
fi
if [ "$INTERATIVO" = 0 ]; then
  [ -n "$SISTEMA" ] || { echo "Falta --system (ou rode num terminal para responder às perguntas)" >&2; uso 1; }
  [ "${#REPOS[@]}" -gt 0 ] || { echo "Falta ao menos um --repo (ou rode num terminal)" >&2; uso 1; }
fi

USUARIO="$(id -un)"
GRUPO="$(id -gn)"
PENDENCIAS=()

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

ETAPA_ATUAL=""
etapa() {
  ETAPA_ATUAL="$1"
  if [ "$ESTADO_ATIVO" = 1 ]; then salvar_estado andamento; fi
  printf '\n%s%s %s%s\n' "$NEGRITO$AZUL" "$I_ETAPA" "$1" "$RESET"
}
ok() { printf '    %s%s%s %s\n' "$VERDE" "$I_OK" "$RESET" "$1"; }
aviso() { printf '    %s%s %s%s\n' "$AMARELO" "$I_AVISO" "$1" "$RESET"; PENDENCIAS+=("$1"); }
# Atenção que não impede o deploy: aparece no resumo, separada das pendências
NOTAS=()
nota() { printf '    %s%s %s%s\n' "$AMARELO" "$I_AVISO" "$1" "$RESET"; NOTAS+=("$1"); }
falha() { printf '\n%s%s Erro:%s %s\n' "$VERMELHO" "$I_ERRO" "$RESET" "$1" >&2; exit 1; }

confirmar() {
  [ "$SIM" = 1 ] && return 0
  local resp=""
  # Sem terminal (ssh sem -t, CI), a resposta é não. Não dá para silenciar o stderr do read:
  # o read -p escreve a pergunta no stderr, e ela sumia da tela (parecia travado)
  { : </dev/tty; } 2>/dev/null || return 1
  read -r -p "  $(rotulo_pergunta "$1" s/N)" resp </dev/tty || return 1
  [[ "$resp" =~ ^([sS]|[sS][iI][mM])$ ]]
}

# ---------------------------------------------------------------------------
# Perguntas do modo interativo. Leem de /dev/tty: funcionam também com curl ... | bash.
# As opções de escolher/escolher_varios são "valor|texto mostrado".

# read com edição de linha (setas, Home, End). Os códigos de cor do prompt vão entre \001 e \002,
# senão o readline erra a largura da linha. Caracteres de controle saem da resposta: sem isso, uma
# seta apertada sem querer gravava "^[[A" no valor.
ler_linha() {
  local -n __ll="$1"
  local prompt
  prompt="$(sed $'s/\033\\[[0-9;]*m/\001&\002/g' <<<"$2")"
  read -e -r -p "$prompt" __ll </dev/tty || return 1
  __ll="$(tr -d '\000-\037\177' <<<"$__ll")"
}

# perguntar VAR "Pergunta" [padrão] [regex]: sem regex, a resposta é obrigatória
perguntar() {
  local -n __resp_var="$1"
  local texto="$2" padrao="${3:-}" regex="${4:-.}" resp=""
  while true; do
    ler_linha resp "$(rotulo_pergunta "$texto" "$padrao")" || falha "sem resposta para: $texto"
    resp="${resp:-$padrao}"
    [[ "$resp" =~ $regex ]] && break
    erro_entrada "Valor inválido."
  done
  __resp_var="$resp"
}

# sim_nao "Pergunta" s|n: pergunta de configuração, que o --yes não responde sozinho
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

# perguntar_segredo VAR "Pergunta": não mostra o que é digitado; Enter deixa vazio
perguntar_segredo() {
  local -n __seg_var="$1"
  local resp=""
  read -rs -p "$(rotulo_pergunta "$2" "oculto")" resp </dev/tty || true
  echo >/dev/tty
  # Sem edição de linha aqui (-s): uma seta chega como sequência inteira (ESC [ A), que sai toda
  resp="$(sed $'s/\033\\[[0-9;?]*[A-Za-z~]//g; s/\033O[A-Za-z]//g' <<<"$resp" | tr -d '\000-\037\177')"
  if [ -n "$resp" ]; then
    escolhido "recebido (${#resp} caracteres, não exibido)"
  else
    printf '    %s%s vazio%s\n' "$FRACO" "$I_ITEM" "$RESET" >/dev/tty
  fi
  __seg_var="$resp"
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

# Opções de branch: as candidatas que existem, na ordem dada, mais "outra"
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

# Runners do GitHub Actions na VM inteira, de qualquer usuário e pasta: os serviços actions.runner.*
# e as pastas com .runner. Um por linha: "pasta|repositório|nome|dono|serviço ativo (1/0)"
listar_runners_vm() {
  local d url nome dono ativo svc
  {
    for svc in $(systemctl list-unit-files --type=service --no-legend 'actions.runner.*' 2>/dev/null | awk '{print $1}'); do
      systemctl show -p ExecStart --value "$svc" 2>/dev/null | grep -oE 'path=[^ ;]+' | head -1 | cut -d= -f2 | xargs -r dirname
    done
    sudo find /home /root /opt -maxdepth 3 -name .runner -type f 2>/dev/null | xargs -r -n1 dirname
  } | sort -u | while IFS= read -r d; do
    sudo test -f "$d/.runner" || continue
    url="$(sudo cat "$d/.runner" | tr -d '\r\000\357\273\277' | grep -oE '"gitHubUrl": *"[^"]+"' | cut -d'"' -f4)"
    nome="$(sudo cat "$d/.runner" | tr -d '\r\000\357\273\277' | grep -oE '"agentName": *"[^"]+"' | cut -d'"' -f4)"
    dono="$(stat -c %U "$d" 2>/dev/null || echo ?)"
    ativo=0
    svc="$(sudo cat "$d/.service" 2>/dev/null || true)"
    if [ -n "$svc" ] && systemctl is-active --quiet "$svc" 2>/dev/null; then ativo=1; fi
    echo "$d|$url|$nome|$dono|$ativo"
  done
  return 0
}

# Remove um runner: para e desinstala o serviço e tira o registro do GitHub (precisa do GH_TOKEN)
remover_runner() {
  local d="$1" dono="$2" token
  token="$(gh_api POST "repos/$SLUG/actions/runners/remove-token" 2>/dev/null | grep -oE '"token": *"[^"]+"' | cut -d'"' -f4 || true)"
  sudo bash -c "cd '$d' && ./svc.sh stop; ./svc.sh uninstall" >/dev/null 2>&1 || true
  if [ -n "$token" ] && sudo -u "$dono" bash -c "cd '$d' && ./config.sh remove --token '$token'" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Chamada à API do GitHub com o GH_TOKEN
gh_api() {
  curl -fsS -X "$1" -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/$2" ${3:+-d "$3"}
}

# Grava CHAVE=valor no .env sem interpretar caracteres especiais do valor
set_env() {
  local arquivo="$1" chave="$2" valor="$3"
  if grep -qE "^${chave}=" "$arquivo"; then
    CHAVE="$chave" VALOR="$valor" awk -F= '
      $1 == ENVIRON["CHAVE"] { print ENVIRON["CHAVE"] "=" ENVIRON["VALOR"]; next } { print }
    ' "$arquivo" > "$arquivo.tmp" && cat "$arquivo.tmp" > "$arquivo" && rm -f "$arquivo.tmp"
  else
    printf '%s=%s\n' "$chave" "$valor" >> "$arquivo"
  fi
}
get_env() { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- || true; }

# Lê "dono/repo[:pasta[:labels]]" e define SLUG, NOME_REPO, PASTA, LABELS, RAIZ, CHAVE_SSH, HOST_SSH
ler_repo() {
  local spec="$1"
  IFS=: read -r SLUG PASTA LABELS <<<"$spec"
  [[ "$SLUG" == */* ]] || falha "--repo $spec: use DONO/REPO"
  # Último trecho: no GitLab, o caminho pode ter subgrupos (grupo/subgrupo/projeto)
  NOME_REPO="${SLUG##*/}"
  if [ -z "$PASTA" ] && [ "${#REPOS[@]}" -gt 1 ]; then PASTA="$NOME_REPO"; fi
  RAIZ="$BASE${PASTA:+/$PASTA}"
  # Uma deploy key só vale para um repositório: cada um tem chave e host SSH próprios
  CHAVE_SSH="$HOME/.ssh/deploy_${SISTEMA}_${NOME_REPO}"
  HOST_SSH="${FORGE}-${SISTEMA}-${NOME_REPO}"
}

[ "$(id -u)" -ne 0 ] || falha "rode com o usuário do deploy, não como root"
# sudo -n true antes: com NOPASSWD numa regra e senha em outra, o sudo -v pede senha mesmo assim
sudo -n true 2>/dev/null || sudo -v || falha "o usuário $USUARIO precisa de sudo"

# ---------------------------------------------------------------------------
# Sistema atual: o que já atende as portas 80/3001 (Nginx da máquina, contêineres de outros
# sistemas) e os processos do PM2. Nada é parado ao detectar: só no primeiro deploy, depois de
# compiladas as imagens novas, para o site ficar fora do ar o mínimo possível. Se o deploy
# falhar, o que foi parado é religado.

ATUAL_PM2=()          # "dono|pm2_home|node|pm2|ids online separados por espaço"
ATUAL_NGINX_HOST=0    # Nginx da máquina ativo (systemd)
ATUAL_NGINX_SOLTO=0   # nginx fora do systemd nas portas
ATUAL_CONTEINERES=()  # contêineres de outros sistemas nas portas 80/3001
REVERTER=()           # comandos que religam o que foi parado, na ordem em que foi parado

# Portas que o Nginx deste sistema publica: 80, e 3001 com homologação (definir_portas)
PORTAS_SS='( sport = :80 or sport = :3001 )' PORTAS_RE=':(80|3001)$' PORTAS_TXT="80 e 3001"
definir_portas() {
  if [ "$SEM_HML" = 1 ]; then
    PORTAS_SS='( sport = :80 )' PORTAS_RE=':80$' PORTAS_TXT="80"
  fi
}
portas_ocupadas() { sudo ss -ltnpH "$PORTAS_SS" | grep -v docker-proxy || true; }

pm2_como() {
  local dono="$1" home="$2" node_bin="$3" pm2_bin="$4"
  shift 4
  sudo -u "$dono" env PATH="$(dirname "$node_bin"):/usr/local/bin:/usr/bin:/bin" PM2_HOME="$home" "$pm2_bin" "$@"
}

detectar_sistema_atual() {
  local pid dono home node_bin pm2_bin ids c portas d
  ATUAL_PM2=() ATUAL_NGINX_HOST=0 ATUAL_NGINX_SOLTO=0 ATUAL_CONTEINERES=()
  for pid in $(pgrep -f 'PM2 v[0-9.]+: God Daemon' || true); do
    dono="$(ps -o user= -p "$pid" | tr -d ' ')"
    home="$(tr '\0' ' ' < "/proc/$pid/cmdline" | sed -nE 's/.*\((.*)\).*/\1/p')"
    # O pm2 fica ao lado do node que roda o daemon (instalação global ou nvm)
    node_bin="$(sudo readlink -f "/proc/$pid/exe")"
    pm2_bin="$(dirname "$node_bin")/pm2"
    [ -x "$pm2_bin" ] || pm2_bin="$(command -v pm2 || true)"
    if [ -z "$pm2_bin" ]; then
      aviso "PM2 de $dono ($home) em execução, mas não achei o executável pm2: pare os processos dele à mão"
      continue
    fi
    ids="$(pm2_como "$dono" "$home" "$node_bin" "$pm2_bin" jlist 2>/dev/null | sudo -u "$dono" "$node_bin" -e '
      let d = "";
      process.stdin.on("data", c => (d += c)).on("end", () => {
        const i = d.indexOf("[");
        if (i < 0) return;
        const ids = JSON.parse(d.slice(i)).filter(p => p.pm2_env.status === "online").map(p => p.pm_id);
        console.log(ids.join(" "));
      });' 2>/dev/null || true)"
    if [ -n "$ids" ]; then
      ATUAL_PM2+=("$dono|$home|$node_bin|$pm2_bin|$ids")
      printf '    PM2 de %s (%s) com %d processo(s) rodando:\n' "$dono" "$home" "$(wc -w <<<"$ids")"
      pm2_como "$dono" "$home" "$node_bin" "$pm2_bin" ls --no-color 2>/dev/null | sed 's/^/      /'
    fi
  done

  if systemctl cat nginx.service >/dev/null 2>&1; then
    if systemctl is-active --quiet nginx; then
      ATUAL_NGINX_HOST=1
      echo "    O Nginx instalado na máquina está ativo e ocupa a porta 80."
    elif systemctl is-enabled --quiet nginx 2>/dev/null; then
      # Parado, mas voltaria no próximo boot e tomaria a porta 80 antes do Docker
      sudo systemctl disable nginx >/dev/null 2>&1
      ok "Nginx da máquina já estava parado; desabilitado para não voltar no boot"
    fi
  fi
  if [ "$ATUAL_NGINX_HOST" = 0 ] && portas_ocupadas | grep -q '"nginx"'; then
    ATUAL_NGINX_SOLTO=1
    echo "    Há um processo nginx fora do systemd na(s) porta(s) $PORTAS_TXT."
  fi

  for c in $("${DOCKER[@]}" ps --format '{{.Names}}'); do
    portas="$("${DOCKER[@]}" port "$c" 2>/dev/null | grep -E "$PORTAS_RE" || true)"
    [ -n "$portas" ] || continue
    d="$("${DOCKER[@]}" inspect "$c" -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')"
    if [[ -n "$d" && "$d" == "$BASE"* ]]; then ok "Contêiner $c já é deste sistema"; continue; fi
    ATUAL_CONTEINERES+=("$c")
    echo "    O contêiner $c ($("${DOCKER[@]}" inspect "$c" -f '{{.Config.Image}}'), de ${d:-origem desconhecida}) ocupa a(s) porta(s) $PORTAS_TXT."
  done

  # Um contêiner parado chamado nginx impediria o deploy de criar o deste sistema com o mesmo nome
  if "${DOCKER[@]}" inspect nginx >/dev/null 2>&1; then
    d="$("${DOCKER[@]}" inspect nginx -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')"
    if [[ "$d" != "$BASE"* ]] && [ "$("${DOCKER[@]}" inspect -f '{{.State.Running}}' nginx)" != true ]; then
      "${DOCKER[@]}" rename nginx "nginx-parado-$(date +%Y%m%d)"
      ok "Contêiner nginx parado de ${d:-outro sistema} renomeado para nginx-parado-$(date +%Y%m%d) (não foi apagado)"
    fi
  fi
}

tem_sistema_atual() {
  [ "${#ATUAL_PM2[@]}" -gt 0 ] || [ "$ATUAL_NGINX_HOST" = 1 ] || [ "$ATUAL_NGINX_SOLTO" = 1 ] \
    || [ "${#ATUAL_CONTEINERES[@]}" -gt 0 ]
}

# Para o que detectar_sistema_atual achou, perguntando antes de cada coisa. Cada parada entra em
# REVERTER. Falha se as portas 80/3001 continuarem ocupadas.
parar_sistema_atual() {
  local e dono home node_bin pm2_bin ids unidade c pm2_dir
  for e in "${ATUAL_PM2[@]}"; do
    IFS='|' read -r dono home node_bin pm2_bin ids <<<"$e"
    if confirmar "Parar os processos do PM2 de $dono (ids $ids)? Nada é apagado"; then
      # shellcheck disable=SC2086
      pm2_como "$dono" "$home" "$node_bin" "$pm2_bin" stop $ids >/dev/null
      pm2_dir="$(dirname "$node_bin")"
      REVERTER+=("sudo -u $dono env PATH=$pm2_dir:/usr/local/bin:/usr/bin:/bin PM2_HOME=$home $pm2_bin start $ids")
      ok "PM2 de $dono parado (ids $ids)"
      # Sem desativar o boot, o pm2 resurrect religaria os processos no próximo boot
      unidade="pm2-$dono.service"
      if systemctl is-enabled --quiet "$unidade" 2>/dev/null; then
        sudo systemctl disable "$unidade" >/dev/null 2>&1 || true
        REVERTER+=("sudo systemctl enable $unidade")
        ok "$unidade desabilitada: o PM2 de $dono não religa os processos no boot"
      fi
    else
      nota "PM2 de $dono continua rodando os processos $ids"
    fi
  done
  if [ "$ATUAL_NGINX_HOST" = 1 ]; then
    if confirmar "Parar e desabilitar o Nginx da máquina? (/etc/nginx é mantido)"; then
      sudo systemctl disable --now nginx >/dev/null 2>&1
      REVERTER+=("sudo systemctl enable --now nginx")
      ok "Nginx da máquina parado e desabilitado"
    fi
  fi
  if [ "$ATUAL_NGINX_SOLTO" = 1 ]; then
    if confirmar "Parar o nginx fora do systemd (sem apagar a configuração)?"; then
      # Só pelo nginx da máquina: um pkill acertaria também o nginx dos contêineres
      if command -v nginx >/dev/null && sudo nginx -s quit 2>/dev/null; then
        sleep 2
        REVERTER+=("sudo nginx")
        ok "Processo nginx parado"
      fi
    fi
  fi
  for c in "${ATUAL_CONTEINERES[@]}"; do
    if confirmar "Parar o contêiner $c? (ele e a configuração são mantidos)"; then
      # Sem isto, a política de restart o religaria com o Docker ou no boot
      "${DOCKER[@]}" update --restart=no "$c" >/dev/null
      "${DOCKER[@]}" stop "$c" >/dev/null
      REVERTER+=("${DOCKER[*]} update --restart=unless-stopped $c && ${DOCKER[*]} start $c")
      ok "Contêiner $c parado"
    fi
  done
  [ -z "$(portas_ocupadas)" ] || return 1
  for c in "${ATUAL_CONTEINERES[@]}"; do
    [ "$("${DOCKER[@]}" inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" != true ] || return 1
  done
}

# Religa o sistema anterior: tira o Nginx deste sistema das portas e desfaz as paradas, de trás
# para a frente
religar_sistema_atual() {
  local i d
  [ "${#REVERTER[@]}" -gt 0 ] || return 0
  d="$("${DOCKER[@]}" inspect nginx -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || true)"
  if [[ -n "$d" && "$d" == "$BASE"* ]]; then "${DOCKER[@]}" rm -f nginx >/dev/null; fi
  for ((i = ${#REVERTER[@]} - 1; i >= 0; i--)); do
    if eval "${REVERTER[$i]}" >/dev/null 2>&1; then
      ok "Religado: ${REVERTER[$i]}"
    else
      aviso "Não consegui religar, rode à mão: ${REVERTER[$i]}"
    fi
  done
  REVERTER=()
}

# Compila as imagens que o deploy.sh vai usar (a próxima cor e a migração) com o sistema atual no
# ar. O deploy.sh compila de novo, mas tudo vem do cache: a troca em si leva segundos.
compilar_imagens() {
  local dir="$1" amb="$2" sis prefixo projeto cor log
  sis="$(grep -m1 -oE '^SISTEMA=[^[:space:]]+' "$dir/deploy.sh" 2>/dev/null | cut -d= -f2 | tr -d "\"'" || true)"
  sis="${sis:-$SISTEMA}"
  if [ "$amb" = "$PROD_NOME" ]; then prefixo="${sis}_" projeto="$sis"; else prefixo="${sis}_hml_" projeto="$sis-hml"; fi
  case "$(grep -oE '(blue|green)_app:' "/opt/$sis/nginx/$amb.inc" 2>/dev/null | head -1 || true)" in
    blue_app:) cor=green ;;
    *) cor=blue ;;
  esac
  log="$BASE/build-$amb.log"
  # sg aplica o grupo docker sem precisar sair da sessão
  if sg docker -c "cd '$dir' && APP_PREFIX='$prefixo' docker compose -p '$projeto-$cor' -f 'compose.$cor.yml' build" </dev/null >"$log" 2>&1 \
    && { [ ! -f "$dir/compose.migrate.yml" ] \
      || sg docker -c "cd '$dir' && docker compose -p '$projeto-migrate' -f compose.migrate.yml build" </dev/null >>"$log" 2>&1; }; then
    rm -f "$log"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Instalação atual (deploy antigo) de um repositório na VM

# Pastas com .git cujo remoto é DONO/REPO, em /home, /root, /var/www, /srv e /opt (fora de
# /opt/<sistema>). Lê o .git/config com sudo: serve para pastas de outros usuários.
achar_instalacoes() {
  local slug g url
  slug="$(tr '[:upper:]' '[:lower:]' <<<"$1")"
  sudo find /home /root /var/www /srv /opt -maxdepth 4 -name .git -type d \
      -not -path "/opt/$SISTEMA/*" -not -path '*/node_modules/*' 2>/dev/null \
    | while IFS= read -r g; do
        url="$(sudo git config -f "$g/config" --get remote.origin.url 2>/dev/null || true)"
        url="$(tr '[:upper:]' '[:lower:]' <<<"${url%.git}")"
        if [[ "$url" == *[:/]"$slug" ]]; then dirname "$g"; fi
      done || true
}

# Adoção da instalação atual: a pasta de produção nasce dela, em vez de um clone
# O que se regenera no build ou na execução fica para trás
EXCLUIR_ADOCAO=(node_modules .next .nuxt .svelte-kit dist build out .turbo .cache .parcel-cache coverage logs tmp
  .venv venv __pycache__ .pytest_cache target .gradle)
RE_EXCLUIR_ADOCAO="(^|/)($(IFS='|'; echo "${EXCLUIR_ADOCAO[*]}" | sed 's/\./\\./g'))(/|$)"

git_em() { local d="$1"; shift; sudo git -c safe.directory='*' -C "$d" "$@"; }

# adotar_instalacao ORIGEM DESTINO BRANCH URL: copia a instalação (menos o que se regenera) e põe o
# código na versão da branch, como o CI faz a cada deploy (fetch e reset --hard). O reset não apaga
# o que está fora do git: .env, credenciais e uploads ficam, também nos próximos deploys.
adotar_instalacao() {
  local origem="$1" dest="$2" branch="$3" url="$4" mudados locais extras n e excl=() chave valor imagem
  [ -d "$origem/.git" ] || { nota "$origem não é um repositório git: produção clonada, sem adotar"; return 1; }
  mudados="$(git_em "$origem" status --porcelain --untracked-files=no 2>/dev/null || true)"
  locais="$(git_em "$origem" log --oneline "origin/$branch..HEAD" 2>/dev/null || true)"
  extras="$( { git_em "$origem" ls-files --others --exclude-standard
               git_em "$origem" ls-files --others --ignored --exclude-standard; } 2>/dev/null \
             | grep -vE "$RE_EXCLUIR_ADOCAO" | sort -u || true)"
  n="$(grep -c . <<<"$extras" || true)"
  printf '    Instalação atual %s (branch %s)\n' "$origem" "$(git_em "$origem" branch --show-current 2>/dev/null || echo '?')"
  if [ -n "$mudados" ]; then
    echo "    Arquivos versionados com mudança só na VM (o reset desfaz; guarde antes se precisar):"
    head -15 <<<"$mudados" | sed 's/^/      /'
  fi
  if [ -n "$locais" ]; then
    echo "    Commits só na VM, fora de origin/$branch (o código fica sem eles):"
    head -10 <<<"$locais" | sed 's/^/      /'
  fi
  if [ "$n" -gt 0 ]; then
    echo "    Fora do git, vão junto ($n):"
    head -20 <<<"$extras" | sed 's/^/      /'
    [ "$n" -le 20 ] || echo "      ... e mais $((n - 20))"
  fi
  if [ "$INTERATIVO" = 1 ] && ! confirmar "Adotar $origem como $dest? (código na branch $branch; o que está fora do git vai junto)"; then
    nota "Produção de $SLUG clonada, sem adotar $origem"
    return 1
  fi

  mkdir -p "$dest"
  for e in "${EXCLUIR_ADOCAO[@]}"; do excl+=(--exclude="$e"); done
  # sudo para ler: a instalação pode ser de outro usuário; a cópia fica com o usuário do deploy
  if ! sudo tar -C "$origem" "${excl[@]}" -cf - . | tar -C "$dest" -xf - 2>/dev/null; then
    rm -rf "$dest"
    aviso "Falha ao copiar $origem para $dest"
    return 1
  fi
  git -C "$dest" remote set-url origin "$url"
  if ! GIT_SSH_COMMAND="ssh -o BatchMode=yes" git -C "$dest" fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch" \
    || ! git -C "$dest" checkout -q -f -B "$branch" "origin/$branch" \
    || ! git -C "$dest" reset -q --hard "origin/$branch"; then
    rm -rf "$dest"
    aviso "Falha ao pôr $dest na branch $branch (acesso ao repositório?): nada foi adotado"
    return 1
  fi
  ok "$dest adotado de $origem: código da branch $branch, $n arquivo(s) fora do git junto"

  # No contêiner, localhost é o próprio contêiner: o banco da máquina é host.docker.internal
  if [ -f "$dest/.env" ]; then
    while IFS= read -r chave; do
      valor="$(get_env "$dest/.env" "$chave")"
      if [[ "$valor" =~ (@|//)(localhost|127\.0\.0\.1)([:/]|$) ]]; then
        set_env "$dest/.env" "$chave" "$(sed -E 's#(@|//)(localhost|127\.0\.0\.1)([:/]|$)#\1host.docker.internal\3#g' <<<"$valor")"
        ok "$dest/.env: $chave com localhost trocado por host.docker.internal"
      fi
    done < <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$dest/.env" | tr -d = | grep -E "$CHAVES_DE_BANCO" || true)
  fi

  # Fora do git e fora de .env e uploads: entram na imagem no build, a menos que o .dockerignore os tire
  imagem="$(grep -vE '(^|/)\.env|(^|/)(uploads|storage)/' <<<"$extras" | grep . | head -8 | tr '\n' ' ' || true)"
  if [ -n "$imagem" ]; then
    nota "$SLUG: arquivos fora do git que entram na imagem no build (se forem credenciais, monte-os como volume ou passe por variável): $imagem"
  fi
  return 0
}

# Pasta da instalação atual escolhida para DONO/REPO (vazio: nenhuma)
origem_de() {
  local o
  for o in "${ORIGENS[@]}"; do
    if [[ "$o" == "$1="* ]]; then echo "${o#*=}"; return 0; fi
    if [[ "$o" != *=* ]]; then echo "$o"; return 0; fi
  done
}

# Pastas montadas como volume nos composes de uma pasta (- ./pasta:/app/pasta), uma por linha
volumes_do_compose() {
  grep -hoE '^[[:space:]]*-[[:space:]]*"?\./[^:"]+:' "$1"/*compose*.y*ml 2>/dev/null \
    | sed -E 's/^[[:space:]]*-[[:space:]]*"?\.\///; s/:$//' | sort -u || true
}

# Chaves do .env antigo que não vão para a homologação: banco e endereço do próprio ambiente
CHAVES_SO_PRODUCAO='^(DATABASE_URL|DIRECT_URL|SHADOW_DATABASE_URL|POSTGRES_[A-Z_]*|DB_[A-Z_]*|PG[A-Z_]*|NEXTAUTH_URL|AUTH_URL|APP_URL|BASE_URL|SITE_URL|PUBLIC_URL|NEXT_PUBLIC_[A-Z_]*URL)$'
# Endereço do próprio ambiente: preenchidas sozinhas (https://domínio, ou http://IP:porta)
CHAVES_URL_PROPRIA='^(NEXTAUTH_URL|AUTH_URL|APP_URL|BASE_URL|SITE_URL|PUBLIC_URL|NEXT_PUBLIC_URL|NEXT_PUBLIC_(APP|SITE|BASE)_URL)$'
# Pedidas sem eco na tela: a URL do banco leva a senha
CHAVES_OCULTAS='SECRET|PASSWORD|SENHA|TOKEN|_KEY|^DATABASE_URL$|^DIRECT_URL$|^SHADOW_DATABASE_URL$|^REDIS_URL$|_DSN$|_URI$'

# Endereço público de um ambiente, lido do nginx/default.conf do repositório: o domínio com
# https (atrás do proxy da prefeitura), ou o IP da VM com a porta de homologação
url_do_ambiente() {
  local dest="$1" amb="$2" conf bloco nomes porta n
  conf="$dest/nginx/default.conf"
  [ -f "$conf" ] || conf="$RAIZ/$PROD_NOME/nginx/default.conf"
  [ -f "$conf" ] || return 0
  if [ "$amb" = "$PROD_NOME" ]; then bloco='^# Produção'; else bloco='^# Homologação'; fi
  nomes="$(awk -v b="$bloco" '$0 ~ b { f = 1 } f && /^[[:space:]]*server_name/ { $1 = ""; print; exit }' "$conf" | tr -d ';')"
  for n in $nomes; do
    [ "$n" != _ ] || continue
    if [[ "$n" =~ ^[0-9.]+$ ]]; then continue; fi
    echo "https://$n"
    return 0
  done
  if [ "$amb" = "$PROD_NOME" ]; then
    for n in $nomes; do [[ "$n" =~ ^[0-9.]+$ ]] && { echo "http://$n"; return 0; }; done
    return 0
  fi
  porta="$(awk '/^# Homologação/ { f = 1 } f && /listen[[:space:]]+[0-9]+[[:space:]]+default_server/ { print $2; exit }' "$conf")"
  echo "http://$(hostname -I | awk '{print $1}'):${porta:-3001}"
}

# Chaves de banco: localhost vira host.docker.internal (o banco fica fora do contêiner)
CHAVES_DE_BANCO='^(DATABASE_URL|DIRECT_URL|SHADOW_DATABASE_URL|REDIS_URL|POSTGRES_HOST|DB_HOST|PGHOST)$'

# ---------------------------------------------------------------------------
# Estado salvo: as respostas e onde a execução parou, para continuar sem responder tudo de novo.
# Um arquivo por sistema, só do usuário (chmod 600). O GH_TOKEN e os valores digitados para o
# .env nunca entram aqui (os do .env já ficam gravados no próprio .env).
ESTADO_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zero-downtime-deploy"

# salvar_estado andamento|interrompido|pendencias|concluido
salvar_estado() {
  local arq
  [ -n "$SISTEMA" ] || return 0
  mkdir -p "$ESTADO_DIR" && chmod 700 "$ESTADO_DIR"
  arq="$ESTADO_DIR/setup-host.$SISTEMA.estado"
  {
    echo "# setup-host.sh: respostas e situação da última execução de $SISTEMA. Pode apagar."
    declare -p FORGE GIT_HOST FORGE_DEFINIDO SISTEMA PROD_NOME PROD_BRANCH HML_NOME HML_BRANCH SEM_HML \
      SEGREDOS SEGREDOS_PERGUNTADO PG_HML CLONAR DEPLOY REPOS PG_ACESSOS ENV_TODOS ENV_PROD ENV_HML ORIGENS
    printf 'ESTADO_DATA=%q\nESTADO_ETAPA=%q\nESTADO_FIM=%q\n' "$(date '+%d/%m/%Y %H:%M')" "$ETAPA_ATUAL" "$1"
    declare -p PENDENCIAS | sed 's/ PENDENCIAS=/ ESTADO_PENDENCIAS=/'
  } >"$arq.tmp"
  chmod 600 "$arq.tmp"
  mv "$arq.tmp" "$arq"
}

# Ao sair, depois de confirmada a configuração: registra como terminou
ao_sair() {
  local codigo=$?
  [ "$ESTADO_ATIVO" = 1 ] || return 0
  if [ "$codigo" -ne 0 ]; then
    salvar_estado interrompido
  elif [ "${#PENDENCIAS[@]}" -gt 0 ]; then
    salvar_estado pendencias
  else
    salvar_estado concluido
  fi
}

# Uma linha de resumo de um arquivo de estado (lido num subshell: não mexe nas variáveis daqui)
resumo_estado() {
  (
    # shellcheck disable=SC1090
    source "$1"
    case "$ESTADO_FIM" in
      concluido) echo "$SISTEMA: concluído em $ESTADO_DATA" ;;
      pendencias) echo "$SISTEMA: terminou com ${#ESTADO_PENDENCIAS[@]} pendência(s) em $ESTADO_DATA" ;;
      *) echo "$SISTEMA: parou em \"$ESTADO_ETAPA\" em $ESTADO_DATA" ;;
    esac
  ) 2>/dev/null
}

# ---------------------------------------------------------------------------
# Modo interativo: pergunta só o que não veio na linha de comando
if [ "$INTERATIVO" = 1 ]; then
  { : </dev/tty; } 2>/dev/null || falha "o modo interativo precisa de um terminal"
  trap 'printf "\n\n  %s%s Cancelado: nada foi alterado.%s\n" "$AMARELO" "$I_AVISO" "$RESET" >/dev/tty; exit 130' INT
  banner "setup-host.sh $VERSAO" "prepara a VM para o deploy blue-green"

  # Execução anterior: continuar com as mesmas respostas ou começar do zero
  if [ -z "$SISTEMA" ] && [ "${#REPOS[@]}" -eq 0 ]; then
    mapfile -t salvos < <(ls -t "$ESTADO_DIR"/setup-host.*.estado 2>/dev/null || true)
    if [ "${#salvos[@]}" -gt 0 ]; then
      opcoes=()
      for f in "${salvos[@]}"; do
        rotulo="$(resumo_estado "$f")"
        [ -n "$rotulo" ] && opcoes+=("$f|continuar $rotulo")
      done
      if [ "${#opcoes[@]}" -gt 0 ]; then
        echo >/dev/tty
        opcoes+=("__novo|começar do zero (novas respostas)")
        escolher retomar "Execuções anteriores (continuar repete as respostas; o que já foi feito é pulado)" 1 "${opcoes[@]}"
        if [ "$retomar" != __novo ]; then
          # shellcheck disable=SC1090
          source "$retomar"
          RETOMADO=1
          # O deploy é decidido de novo: as pendências podem ter sido resolvidas
          DEPLOY=""
          if [ "${#ESTADO_PENDENCIAS[@]}" -gt 0 ]; then
            printf '    %s%s Pendências da última vez:%s\n' "$AMARELO" "$I_AVISO" "$RESET" >/dev/tty
            for p_ in "${ESTADO_PENDENCIAS[@]}"; do printf '      %s%s%s %s\n' "$AMARELO" "$I_ITEM" "$RESET" "$p_" >/dev/tty; done
          fi
        fi
      fi
    fi
  fi
  etapa "Configuração"

  if [ "$FORGE_DEFINIDO" = 0 ] && [ "${#REPOS[@]}" -eq 0 ]; then
    escolher FORGE "Onde estão os repositórios?" 1 \
      "github|GitHub (deploy key e runner cadastrados pelo script, com GH_TOKEN)" \
      "gitlab|GitLab (deploy key e runner manuais, com passo a passo)"
    if [ "$FORGE" = gitlab ]; then
      perguntar GIT_HOST "Endereço do GitLab" gitlab.com '^[A-Za-z0-9.:-]+$'
    fi
  fi

  if [ "${#REPOS[@]}" -eq 0 ]; then
    while true; do
      perguntar repo "Repositório (DONO/REPO, ex.: SEMIT-SUAS/siscon)" "" '^[^/[:space:]]+(/[^/[:space:]]+)+$'
      REPOS+=("$repo")
      sim_nao "Adicionar outro repositório do mesmo sistema (ex.: API e frontend separados)?" n || break
    done
    # Com vários, cada um ganha uma subpasta e, se quiser, labels extras do runner
    if [ "${#REPOS[@]}" -gt 1 ]; then
      for i in "${!REPOS[@]}"; do
        slug="${REPOS[$i]}"
        perguntar pasta "Subpasta de $slug em /opt/<sistema>" "${slug##*/}" '^[A-Za-z0-9._-]+$'
        REPOS[$i]="$slug:$pasta"
      done
    fi
  fi

  if [ -z "$SISTEMA" ]; then
    # Igual ao scaffold.sh (declaracao-isencao vira declaracao_isencao): o CI gerado por ele usa
    # /opt/<sistema>, e um nome diferente aqui deixaria o deploy sem pasta
    sugestao="$(sed -E 's#.*/##' <<<"${REPOS[0]%%:*}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_]+/_/g')"
    perguntar SISTEMA "Nome do sistema (pastas em /opt/NOME)" "$sugestao" '^[a-z0-9_-]+$'
  fi

  if [ "$FORGE" = github ] && [ -z "${GH_TOKEN:-}" ]; then
    echo "  GH_TOKEN: token com escopo repo e admin no repositório (na sua máquina: gh auth token)."
    perguntar_segredo GH_TOKEN "Cole o GH_TOKEN (Enter para pular: deploy key e runner ficam manuais)"
    [ -n "$GH_TOKEN" ] && export GH_TOKEN
  fi

  # Branches: com GH_TOKEN, oferece as que existem no primeiro repositório
  branches=""
  if [ "$FORGE" = github ] && [ -n "${GH_TOKEN:-}" ]; then
    branches="$(gh_api GET "repos/${REPOS[0]%%:*}/branches?per_page=100" 2>/dev/null \
      | grep -oE '"name": *"[^"]+"' | cut -d'"' -f4 || true)"
  fi
  if [ "$SEM_HML_DEF" = 0 ] && [ "$RETOMADO" = 0 ] && [ -z "$HML_BRANCH" ] && [ -z "$PG_HML" ]; then
    escolher ambientes "Ambientes (o mesmo escolhido no scaffold.sh)" 1 \
      "ambos|produção e homologação (homologação na porta 3001, com banco próprio)" \
      "prod|só produção"
    if [ "$ambientes" = prod ]; then SEM_HML=1; fi
    SEM_HML_DEF=1
  fi

  if [ -z "$PROD_BRANCH" ]; then
    escolher_branch PROD_BRANCH "Branch de produção" "$branches" main main master production prod
  fi
  if [ -z "$HML_BRANCH" ] && [ "$SEM_HML" = 0 ]; then
    escolher_branch HML_BRANCH "Branch de homologação" "$branches" dev \
      dev develop developer homolog homologacao staging hml
    if [ -n "$branches" ] && ! grep -qx "$HML_BRANCH" <<<"$branches"; then
      echo "    A branch $HML_BRANCH ainda não existe: crie-a (a partir de $PROD_BRANCH) antes do clone."
    fi
  fi

  # Instalação atual (ex.: deploy antigo pelo PM2): aproveitar o .env e os arquivos enviados
  if [ "${#ORIGENS[@]}" -eq 0 ] && [ "$RETOMADO" = 0 ]; then
    for spec in "${REPOS[@]}"; do
      slug="${spec%%:*}"
      mapfile -t achadas < <(achar_instalacoes "$slug")
      [ "${#achadas[@]}" -gt 0 ] || continue
      opcoes=()
      for d in "${achadas[@]}"; do
        ramo="$(sudo sed -n 's#^ref: refs/heads/##p' "$d/.git/HEAD" 2>/dev/null || true)"
        info="branch ${ramo:-?}"
        if sudo test -f "$d/.env"; then info+=", com .env"; fi
        opcoes+=("$d|$d ($info)")
      done
      opcoes+=("|não aproveitar")
      escolher origem "Instalação atual de $slug encontrada. A produção nasce dela? (código na versão da branch; .env, credenciais e arquivos fora do git vão junto)" 1 "${opcoes[@]}"
      if [ -n "$origem" ]; then ORIGENS+=("$slug=$origem"); fi
    done
  fi

  # PostgreSQL da máquina: banco de homologação e acesso da rede Docker aos bancos de produção
  if [ -d /etc/postgresql ] && [ -z "$PG_HML" ] && [ "$RETOMADO" = 0 ] && [ "$SEM_HML" = 0 ]; then
    hml_sugerido="$(tr '-' '_' <<<"$SISTEMA")_hml"
    escolher PG_HML "Banco de homologação no PostgreSQL da máquina" 1 \
      "$hml_sugerido|criar $hml_sugerido (banco e usuário novos, vazios)" \
      "|não criar (já existe ou fica em outro servidor)"
  fi

  if [ -z "$DEPLOY" ]; then
    escolher DEPLOY "Ao final" 1 \
      "0|só preparar a VM (o sistema atual, se houver, continua no ar)" \
      "1|preparar e fazer o primeiro deploy: compila as imagens, só então para o sistema atual e publica"
  fi

  # Comando equivalente, para repetir sem perguntas (o GH_TOKEN nunca entra aqui)
  cmd="$CHAMADA --system $SISTEMA"
  [ "$FORGE" = gitlab ] && cmd+=" --gitlab $GIT_HOST"
  for r in "${REPOS[@]}"; do cmd+=" --repo $r"; done
  if [ "$SEM_HML" = 1 ]; then
    cmd+=" --no-staging --prod-branch $PROD_BRANCH"
  else
    cmd+=" --prod-branch $PROD_BRANCH --staging-branch $HML_BRANCH"
  fi
  [ -n "$PG_HML" ] && cmd+=" --pg-staging $PG_HML"
  for a in "${PG_ACESSOS[@]}"; do cmd+=" --pg-access $a"; done
  for a in "${ORIGENS[@]}"; do cmd+=" --source $a"; done
  [ "$DEPLOY" = 1 ] && cmd+=" --deploy"
  printf '\n  %s%s Para repetir sem perguntas:%s\n    %s%s%s\n\n' "$FRACO" "$I_INFO" "$RESET" "$CIANO" "$cmd" "$RESET"
  sim_nao "Continuar?" s || { printf '  %s%s Nada foi alterado.%s\n' "$AMARELO" "$I_AVISO" "$RESET"; exit 0; }
fi
# Interrompido no meio: cada etapa confere o que já está feito, então basta rodar de novo
trap 'printf "\n\n  %s%s Interrompido em \"%s\". Rode o mesmo comando de novo para continuar.%s\n" "$AMARELO" "$I_AVISO" "$ETAPA_ATUAL" "$RESET" >&2; exit 130' INT

PROD_BRANCH="${PROD_BRANCH:-main}" HML_BRANCH="${HML_BRANCH:-dev}" DEPLOY="${DEPLOY:-0}"
# Ambientes em uso: AMBIENTES na ordem de preparar, ORDEM_DEPLOY com homologação primeiro
if [ "$SEM_HML" = 1 ]; then
  [ -z "$PG_HML" ] || falha "--pg-staging não combina com --no-staging"
  AMBIENTES=("$PROD_NOME") ORDEM_DEPLOY=("$PROD_NOME") CLONES=("$PROD_NOME:$PROD_BRANCH")
else
  AMBIENTES=("$PROD_NOME" "$HML_NOME") ORDEM_DEPLOY=("$HML_NOME" "$PROD_NOME")
  CLONES=("$PROD_NOME:$PROD_BRANCH" "$HML_NOME:$HML_BRANCH")
fi
definir_portas
[[ "$SISTEMA" =~ ^[a-z0-9_-]+$ ]] || falha "--system aceita só minúsculas, números, _ e -"
BASE="/opt/$SISTEMA"
for a in "${ORIGENS[@]}"; do
  sudo test -d "${a#*=}" || falha "--source: pasta não encontrada: ${a#*=}"
done
ESTADO_ATIVO=1
trap ao_sair EXIT
salvar_estado andamento
if [ "$FORGE" = gitlab ]; then
  echo "GitLab ($GIT_HOST): deploy keys e runner ficam manuais; o script mostra o passo a passo."
elif [ -z "${GH_TOKEN:-}" ]; then
  echo "Sem GH_TOKEN: deploy keys e runners ficam como pendência."
fi

# ---------------------------------------------------------------------------
etapa "Docker"
if ! command -v docker >/dev/null; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq ca-certificates curl git openssl
  curl -fsSL https://get.docker.com | sudo sh
  ok "Docker instalado"
else
  ok "Docker já instalado ($(docker --version | cut -d, -f1))"
fi
docker compose version >/dev/null 2>&1 || falha "falta o plugin docker compose"

if ! id -nG "$USUARIO" | tr ' ' '\n' | grep -qx docker; then
  sudo usermod -aG docker "$USUARIO"
  ok "$USUARIO adicionado ao grupo docker"
fi
# A sessão atual só enxerga o grupo novo depois de entrar de novo; até lá, usa sudo
if docker info >/dev/null 2>&1; then DOCKER=(docker); else DOCKER=(sudo docker); fi

"${DOCKER[@]}" network inspect web >/dev/null 2>&1 || "${DOCKER[@]}" network create web >/dev/null
ok "Rede docker web (compartilhada pelos sistemas da VM)"

# ---------------------------------------------------------------------------
etapa "Sistema atual"
detectar_sistema_atual
if ! tem_sistema_atual; then
  ok "Porta(s) $PORTAS_TXT livre(s) e nenhum processo no PM2"
elif [ "$DEPLOY" = 1 ]; then
  ok "Fica no ar até o primeiro deploy, no fim desta execução: as imagens novas são compiladas antes"
else
  nota "O sistema atual continua no ar. O primeiro deploy precisa ser por aqui (rode de novo e escolha fazer o deploy): pelo push, o Nginx novo não subiria com a porta 80 ocupada"
fi

# ---------------------------------------------------------------------------
etapa "Pastas em $BASE"
sudo mkdir -p "$BASE/nginx"
sudo chown "$USUARIO:$GRUPO" "$BASE" "$BASE/nginx"
ok "$BASE pertence a $USUARIO"

# ---------------------------------------------------------------------------
if [ "$CLONAR" = 1 ]; then
  etapa "Acesso aos repositórios e clones"
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  touch "$HOME/.ssh/config" && chmod 600 "$HOME/.ssh/config"
  # A porta de um endereço como servidor:8443 é a da web, não a do SSH
  SSH_HOST="${GIT_HOST%%:*}" SSH_PORTA=22
  # Rede que bloqueia a porta 22: o GitHub também aceita SSH em ssh.github.com:443
  if ! timeout 5 bash -c "</dev/tcp/$SSH_HOST/22" 2>/dev/null; then
    if [ "$FORGE" = github ]; then
      SSH_HOST=ssh.github.com SSH_PORTA=443
      ok "Porta 22 bloqueada: SSH do GitHub por $SSH_HOST:$SSH_PORTA"
    else
      aviso "Porta 22 de $SSH_HOST inacessível: o clone por SSH vai falhar"
    fi
  fi
  known="$SSH_HOST"; [ "$SSH_PORTA" = 22 ] || known="[$SSH_HOST]:$SSH_PORTA"
  ssh-keygen -F "$known" >/dev/null 2>&1 \
    || ssh-keyscan -p "$SSH_PORTA" -t ed25519 "$SSH_HOST" 2>/dev/null >> "$HOME/.ssh/known_hosts" \
    || aviso "ssh-keyscan $SSH_HOST:$SSH_PORTA falhou: confira o acesso da VM ao $GIT_HOST"

  for spec in "${REPOS[@]}"; do
    ler_repo "$spec"
    url="git@$HOST_SSH:$SLUG.git"

    [ -f "$CHAVE_SSH" ] || ssh-keygen -t ed25519 -N "" -C "$USUARIO@$(hostname) $SLUG" -f "$CHAVE_SSH" -q
    if ! grep -qx "Host $HOST_SSH" "$HOME/.ssh/config"; then
      printf '\nHost %s\n  HostName %s\n  Port %s\n  User git\n  IdentityFile %s\n  IdentitiesOnly yes\n' \
        "$HOST_SSH" "$SSH_HOST" "$SSH_PORTA" "$CHAVE_SSH" >> "$HOME/.ssh/config"
    fi

    # A deploy key gerada ainda não tem acesso: uma chave que já existe na VM pode ter
    # (ex.: ~/.ssh/id_ed25519 de uma conta do GitLab). Ela serve, mas dá o acesso da conta inteira.
    if ! GIT_SSH_COMMAND="ssh -o BatchMode=yes" git ls-remote "$url" >/dev/null 2>&1; then
      for chave in "$HOME"/.ssh/id_ed25519 "$HOME"/.ssh/id_ecdsa "$HOME"/.ssh/id_rsa; do
        [ -f "$chave" ] || continue
        GIT_SSH_COMMAND="ssh -o BatchMode=yes -o IdentitiesOnly=yes -i $chave -p $SSH_PORTA" \
          git ls-remote "git@$SSH_HOST:$SLUG.git" >/dev/null 2>&1 || continue
        usar=existente
        if [ "$SIM" = 0 ] && { : </dev/tty; } 2>/dev/null; then
          escolher usar "$SLUG: a chave $chave já tem acesso ao repositório. Qual usar?" 1 \
            "existente|$(basename "$chave") (já funciona; é chave de usuário: a VM fica com o acesso da conta)" \
            "deploy|a deploy key gerada (só leitura deste repositório; cadastre-a no $GIT_HOST)"
        fi
        if [ "$usar" = existente ]; then
          tmp="$(mktemp)"
          H="$HOST_SSH" K="$chave" awk '
            /^Host / { dentro = ($2 == ENVIRON["H"]) }
            dentro && /^[[:space:]]*IdentityFile / { print "  IdentityFile " ENVIRON["K"]; next }
            { print }' "$HOME/.ssh/config" >"$tmp" && cat "$tmp" >"$HOME/.ssh/config"
          rm -f "$tmp"
          ok "$SLUG: acesso pela chave existente $chave (para só leitura, troque por uma deploy key)"
        fi
        break
      done
    fi
    if ! GIT_SSH_COMMAND="ssh -o BatchMode=yes" git ls-remote "$url" >/dev/null 2>&1; then
      if [ "$FORGE" = gitlab ]; then
        echo "    $SLUG: cadastre a chave abaixo em https://$GIT_HOST/$SLUG/-/settings/repository"
        echo "    (Deploy keys > Add new key, sem marcar \"Grant write permissions\") e rode o script de novo:"
        sed 's/^/      /' "$CHAVE_SSH.pub"
        aviso "$SLUG: cadastrar a deploy key no GitLab (chave em $CHAVE_SSH.pub)"
        continue
      elif [ -n "${GH_TOKEN:-}" ]; then
        corpo="{\"title\":\"$(hostname) ($SISTEMA)\",\"key\":\"$(cat "$CHAVE_SSH.pub")\",\"read_only\":true}"
        gh_api POST "repos/$SLUG/keys" "$corpo" >/dev/null || falha "não consegui cadastrar a deploy key em $SLUG (o token é admin do repositório?)"
        ok "$SLUG: deploy key somente leitura cadastrada"
      else
        aviso "$SLUG: cadastre esta deploy key (somente leitura) em https://github.com/$SLUG/settings/keys e rode de novo: $(cat "$CHAVE_SSH.pub")"
        continue
      fi
    fi

    for par in "${CLONES[@]}"; do
      amb="${par%%:*}" branch="${par#*:}"
      dest="$RAIZ/$amb"
      mkdir -p "$RAIZ"
      if [ -d "$dest/.git" ]; then
        ok "$dest já clonado ($(git -C "$dest" branch --show-current))"
      elif ! git ls-remote --exit-code --heads "$url" "$branch" >/dev/null 2>&1; then
        aviso "$SLUG não tem a branch $branch: crie-a ou ajuste --prod-branch/--staging-branch ($amb não clonado)"
      elif [ "$amb" = "$PROD_NOME" ] && [ -n "$(origem_de "$SLUG")" ] \
        && adotar_instalacao "$(origem_de "$SLUG")" "$dest" "$branch" "$url"; then
        :
      elif git clone -q -b "$branch" "$url" "$dest"; then
        ok "$dest clonado da branch $branch"
      else
        aviso "Falha ao clonar $SLUG ($branch) em $dest"
      fi
    done
  done
fi

# ---------------------------------------------------------------------------
etapa "Arquivos de deploy nos repositórios"
# O script prepara a VM; o deploy em si depende destes arquivos, que ficam no repositório
for spec in "${REPOS[@]}"; do
  ler_repo "$spec"
  for amb in "${AMBIENTES[@]}"; do
    dest="$RAIZ/$amb"
    [ -d "$dest/.git" ] || continue
    faltam=()
    [ -f "$dest/deploy.sh" ] || faltam+=("deploy.sh")
    # Monorepo (APPS no deploy.conf): um Dockerfile em cada pasta de aplicação
    apps_conf="$(sed -n 's/^APPS=//p' "$dest/deploy.conf" 2>/dev/null | tr -d "\"'\r" || true)"
    if [ -n "$apps_conf" ]; then
      for a in $apps_conf; do
        pasta_app="$(cut -d: -f2 <<<"$a")"
        [ -f "$dest/$pasta_app/Dockerfile" ] || faltam+=("$pasta_app/Dockerfile")
      done
    else
      [ -f "$dest/Dockerfile" ] || faltam+=("Dockerfile")
    fi
    compgen -G "$dest/*blue*.y*ml" >/dev/null || faltam+=("compose da cor blue")
    compgen -G "$dest/*green*.y*ml" >/dev/null || faltam+=("compose da cor green")
    if [ "$FORGE" = gitlab ]; then
      [ -f "$dest/.gitlab-ci.yml" ] || faltam+=(".gitlab-ci.yml")
    else
      grep -qslE 'self-hosted' "$dest"/.github/workflows/*.y*ml || faltam+=("workflow com runs-on: self-hosted")
      # Dois workflows de deploy ativos: cada push faria dois deploys (ex.: o antigo, com PM2)
      for wf in "$dest"/.github/workflows/*.y*ml; do
        [ -f "$wf" ] || continue
        grep -q zero-downtime-deploy "$wf" && continue
        if grep -qiE 'self-hosted|\bpm2\b|appleboy/ssh|git pull' "$wf"; then
          aviso "$SLUG ($amb): ${wf#"$dest"/} faz deploy além do workflow novo: cada push faria dois deploys. Desative-o no repositório (scaffold.sh --replace-ci)"
        fi
      done
    fi
    if [ "$SEM_HML" = 0 ] && [ -f "$dest/nginx/default.conf" ] && ! grep -q '_hml_blue_app' "$dest/nginx/default.conf"; then
      aviso "$SLUG ($amb): o repositório foi gerado sem homologação (scaffold.sh --no-staging): rode este script com --no-staging"
    fi
    if [ "${#faltam[@]}" -eq 0 ]; then
      ok "$SLUG ($amb): arquivos de deploy presentes"
    else
      aviso "$SLUG ($amb) sem: ${faltam[*]}. Veja a pasta modelos/ e o README do zero-downtime-deploy"
    fi
  done
done

# ---------------------------------------------------------------------------
# Banco de homologação antes do .env, para o endereço dele já entrar no .env de homologação
psql_pg() { sudo -u postgres psql -v ON_ERROR_STOP=1 -tAc "$1"; }
if [ -n "$PG_HML" ]; then
  etapa "Banco de homologação"
  [ -d /etc/postgresql ] || falha "--pg-staging: PostgreSQL não encontrado em /etc/postgresql"
  [[ "$PG_HML" =~ ^[a-z0-9_]+$ ]] || falha "--pg-staging aceita só minúsculas, números e _"
  if [ "$(psql_pg "SELECT 1 FROM pg_roles WHERE rolname = '$PG_HML'")" != 1 ]; then
    # Hexadecimal: sem @ : / $, que quebrariam a URL ou o Compose
    senha="$(openssl rand -hex 24)"
    psql_pg "CREATE ROLE $PG_HML LOGIN PASSWORD '$senha'"
    psql_pg "CREATE DATABASE $PG_HML OWNER $PG_HML"
    PG_URL="postgresql://$PG_HML:$senha@host.docker.internal:5432/$PG_HML"
    ok "Banco e usuário $PG_HML criados, vazios (a migração do deploy cria as tabelas)"
  else
    ok "Usuário $PG_HML já existe"
  fi
fi

# ---------------------------------------------------------------------------
etapa "Arquivos .env"
# Banco de homologação criado numa execução anterior, quando o .env ainda não existia
if [ -z "$PG_URL" ] && [ -n "$PG_HML" ] && [ -f "$BASE/$PG_HML.url" ]; then
  PG_URL="$(head -1 "$BASE/$PG_HML.url")"
fi
for spec in "${REPOS[@]}"; do
  ler_repo "$spec"
  for amb in "${AMBIENTES[@]}"; do
    dest="$RAIZ/$amb"
    [ -d "$dest" ] || continue

    origem="$(origem_de "$SLUG")"

    # Pastas montadas como volume (- ./pasta:/app/pasta nos composes): sem isto, o Docker as cria como root
    while IFS= read -r vol; do
      [ -n "$vol" ] && [[ "$vol" != *..* ]] || continue
      mkdir -p "$dest/$vol"
      # Produção: arquivos enviados na instalação atual. cp -u só traz o que é novo ou mudou,
      # então rodar de novo logo antes da troca completa a cópia; nada é apagado no destino.
      if [ -n "$origem" ] && [ "$amb" = "$PROD_NOME" ] && sudo test -d "$origem/$vol"; then
        n="$(sudo find "$origem/$vol" -type f | wc -l)"
        if [ "$n" -gt 0 ]; then
          sudo cp -a -u "$origem/$vol/." "$dest/$vol/"
          sudo chown -R "$USUARIO:$GRUPO" "$dest/$vol"
          ok "$amb: $vol sincronizada com $origem/$vol ($n arquivos; rode de novo logo antes da troca)"
        fi
      fi
    done < <(volumes_do_compose "$dest")

    exemplo="$(ls "$dest"/.env.example "$dest"/.env.exemple "$dest"/example.env "$dest"/env.example 2>/dev/null | head -1 || true)"
    env="$dest/.env"
    if [ ! -f "$env" ]; then
      [ -n "$exemplo" ] || { aviso "$dest sem .env nem arquivo de exemplo (.env.example): crie o .env à mão"; continue; }
      cp "$exemplo" "$env"
      ok "$dest/.env criado a partir de $(basename "$exemplo")"
    fi
    chmod 600 "$env"

    # Valores do .env da instalação atual, só onde o novo ainda está como no exemplo (ou sem a
    # chave): o que já foi preenchido não é trocado. Na homologação, sem banco nem URLs.
    # DA_ORIGEM: chaves com o valor da instalação atual. Contam como preenchidas mesmo se o
    # .env.example tiver o mesmo valor (exemplo com valores reais): não são perguntadas de novo
    # nem trocadas por um segredo gerado.
    DA_ORIGEM=" "
    if [ -n "$origem" ] && sudo test -f "$origem/.env"; then
      trazidas=0
      while IFS= read -r linha; do
        chave="${linha%%=*}" valor="${linha#*=}"
        if [ "$amb" = "$HML_NOME" ] && [[ "$chave" =~ $CHAVES_SO_PRODUCAO ]]; then continue; fi
        # Homologação com segredos próprios: com os de produção, um token dela valeria em produção
        if [ "$amb" = "$HML_NOME" ] && [[ " $SEGREDOS " == *" $chave "* ]]; then continue; fi
        if [[ "$chave" =~ $CHAVES_DE_BANCO ]]; then
          valor="$(sed -E 's#(@|//)(localhost|127\.0\.0\.1)([:/]|$)#\1host.docker.internal\3#g' <<<"$valor")"
        fi
        if grep -qE "^$chave=" "$env"; then
          atual="$(get_env "$env" "$chave")"
          if [ "$atual" = "$valor" ]; then DA_ORIGEM+="$chave "; continue; fi
          modelo=""
          if [ -n "$exemplo" ]; then modelo="$(get_env "$exemplo" "$chave")"; fi
          [ "$atual" = "$modelo" ] || continue
        fi
        set_env "$env" "$chave" "$valor"
        DA_ORIGEM+="$chave "
        trazidas=$((trazidas + 1))
      done < <(sudo cat "$origem/.env" | tr -d '\r' | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' || true)
      if [ "$trazidas" -gt 0 ]; then ok "$amb: $trazidas valor(es) trazido(s) de $origem/.env"; fi
    fi

    # Dono dos volumes, quando os composes usam APP_UID
    if grep -qsE 'APP_UID' "$dest"/*compose*.y*ml; then
      set_env "$env" APP_UID "$(id -u)"
      set_env "$env" APP_GID "$(id -g)"
    fi

    # Valores passados no comando: sempre aplicados, inclusive ao rodar de novo
    if [ "$amb" = "$PROD_NOME" ]; then extras=("${ENV_TODOS[@]}" "${ENV_PROD[@]}"); else extras=("${ENV_TODOS[@]}" "${ENV_HML[@]}"); fi
    for kv in "${extras[@]}"; do
      [ -n "$kv" ] || continue
      set_env "$env" "${kv%%=*}" "${kv#*=}"
    done

    # Interativo e sem --secrets: escolhe no .env.example, já marcando os que parecem segredos
    if [ "$INTERATIVO" = 1 ] && [ -z "$SEGREDOS" ] && [ "$SEGREDOS_PERGUNTADO" = 0 ] && [ -n "$exemplo" ]; then
      SEGREDOS_PERGUNTADO=1
      opcoes=() marcados="" i=1 escolhidos=()
      while IFS= read -r chave; do
        opcoes+=("$chave|$chave")
        [[ "$chave" =~ SECRET|ENCRYPTION|JWT|SALT|SESSION ]] && marcados+="$i "
        i=$((i + 1))
      done < <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$exemplo" | tr -d = | grep -vE '^(APP_UID|APP_GID|NODE_ENV)$')
      if [ "${#opcoes[@]}" -gt 0 ]; then
        escolher_varios escolhidos "Chaves que recebem um segredo aleatório, diferente em cada ambiente" \
          "${marcados% }" "${opcoes[@]}"
        SEGREDOS="${escolhidos[*]}"
      fi
    fi

    # Segredos próprios de cada ambiente; os já definidos não mudam (mudar derruba sessões)
    for chave in $SEGREDOS; do
      # O da instalação atual fica: trocar derrubaria as sessões abertas
      [[ "$DA_ORIGEM" == *" $chave "* ]] && continue
      atual="$(get_env "$env" "$chave")"
      if [ -z "$atual" ] || { [ -n "$exemplo" ] && [ "$atual" = "$(get_env "$exemplo" "$chave")" ]; }; then
        set_env "$env" "$chave" "$(openssl rand -hex 32)"
        ok "$amb: $chave gerado"
      fi
    done

    # Banco de homologação recém-criado: preenche onde o .env ainda tem o valor de exemplo
    if [ -n "$PG_URL" ] && [ "$amb" = "$HML_NOME" ] && [ -n "$exemplo" ]; then
      for chave in DATABASE_URL DIRECT_URL; do
        atual="$(get_env "$env" "$chave")"
        if [ -n "$atual" ] && [ "$atual" = "$(get_env "$exemplo" "$chave")" ]; then
          set_env "$env" "$chave" "\"$PG_URL\""
          ok "$amb: $chave aponta para o banco $PG_HML"
          PG_URL_USADA=1
        fi
      done
    fi

    # Endereço do próprio ambiente (NEXTAUTH_URL e afins), onde ainda está como no exemplo
    url_amb="$(url_do_ambiente "$dest" "$amb")"
    if [ -n "$url_amb" ] && [ -n "$exemplo" ]; then
      while IFS= read -r chave; do
        atual="$(get_env "$env" "$chave")"
        if [ -z "$atual" ] || [ "$atual" = "$(get_env "$exemplo" "$chave")" ]; then
          set_env "$env" "$chave" "$url_amb"
          ok "$amb: $chave = $url_amb"
        fi
      done < <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$exemplo" | tr -d = | grep -E "$CHAVES_URL_PROPRIA" || true)
    fi

    # O que ainda está igual ao exemplo precisa ser revisto à mão
    if [ -n "$exemplo" ]; then
      iguais=()
      while IFS= read -r linha; do
        chave="${linha%%=*}" valor="${linha#*=}"
        [[ "$DA_ORIGEM" == *" $chave "* ]] && continue
        [ -n "$valor" ] && [ "$(get_env "$env" "$chave")" = "$valor" ] && iguais+=("$chave")
      done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$exemplo")

      # Interativo: pede cada valor; Enter mantém o do exemplo e deixa como pendência
      if [ "$INTERATIVO" = 1 ] && [ "${#iguais[@]}" -gt 0 ]; then
        echo "    $amb: valores ainda iguais ao exemplo (Enter mantém)"
        restantes=()
        for chave in "${iguais[@]}"; do
          if [[ "$chave" =~ $CHAVES_OCULTAS ]]; then
            perguntar_segredo valor "$amb: $chave (exemplo: $(get_env "$exemplo" "$chave"))"
          else
            perguntar valor "$amb: $chave (exemplo: $(get_env "$exemplo" "$chave"))" "" '^.*$'
          fi
          if [ -z "$valor" ]; then
            restantes+=("$chave")
            continue
          fi
          # No contêiner, localhost é o próprio contêiner: o banco da máquina é host.docker.internal
          if [[ "$valor" =~ @(localhost|127\.0\.0\.1)[:/] ]]; then
            valor="${valor/@localhost/@host.docker.internal}"
            valor="${valor/@127.0.0.1/@host.docker.internal}"
            ok "$amb: $chave com localhost trocado por host.docker.internal"
          fi
          # URL sem esquema (ex.: isencao.saoluis.ma.gov.br): https para domínio, http para IP
          if [[ "$chave" == *_URL && "$valor" != *://* && "$valor" =~ ^[A-Za-z0-9.-]+\.[A-Za-z0-9-]+(:[0-9]+)?(/.*)?$ ]]; then
            if [[ "$valor" =~ ^[0-9.]+(:|/|$) ]]; then valor="http://$valor"; else valor="https://$valor"; fi
            ok "$amb: $chave sem http(s)://, gravado como $valor"
          fi
          # Aspas simples: o Compose não interpreta espaço, # nem $ dentro delas
          if [[ "$valor" =~ [[:space:]#\$] ]] && [[ ! "$valor" =~ ^[\"\'] ]] && [[ "$valor" != *"'"* ]]; then
            valor="'$valor'"
          fi
          set_env "$env" "$chave" "$valor"
        done
        iguais=("${restantes[@]}")
      fi
      [ "${#iguais[@]}" -eq 0 ] || aviso "Revise em $env (iguais ao exemplo): ${iguais[*]}"
    fi
  done
done

if [ -n "$PG_URL" ] && [ "$PG_URL_USADA" = 0 ]; then
  printf '%s\n' "$PG_URL" > "$BASE/$PG_HML.url" && chmod 600 "$BASE/$PG_HML.url"
  aviso "Endereço do banco $PG_HML salvo em $BASE/$PG_HML.url: rode de novo depois do clone (ou copie para o .env de homologação)"
elif [ "$PG_URL_USADA" = 1 ] && [ -f "$BASE/$PG_HML.url" ]; then
  # Tem a senha do banco: não fica para trás depois de usado
  rm -f "$BASE/$PG_HML.url"
fi

# ---------------------------------------------------------------------------
# Acesso dos contêineres ao PostgreSQL da máquina: os bancos saem do DATABASE_URL/DIRECT_URL de
# cada .env (os que apontam para host.docker.internal), mais os de --pg-access
RE_URL_PG='^postgres(ql)?://([^:@/]+)(:[^@]*)?@(host\.docker\.internal|172\.17\.0\.1)(:[0-9]+)?/([^?]+)'
if [ -d /etc/postgresql ]; then
  etapa "Acesso ao PostgreSQL da máquina"
  PG_DIR="$(ls -d /etc/postgresql/*/main 2>/dev/null | sort -V | tail -1 || true)"
  [ -n "$PG_DIR" ] || falha "PostgreSQL não encontrado em /etc/postgresql"
  WEB_SUBNET="$("${DOCKER[@]}" network inspect web -f '{{(index .IPAM.Config 0).Subnet}}')"
  DOCKER0_IP="$(ip -4 -o addr show docker0 | awk '{print $4}' | cut -d/ -f1)"

  acessos=("${PG_ACESSOS[@]}")
  for spec in "${REPOS[@]}"; do
    ler_repo "$spec"
    for amb in "${AMBIENTES[@]}"; do
      env="$RAIZ/$amb/.env"
      [ -f "$env" ] || continue
      for chave in DATABASE_URL DIRECT_URL; do
        valor="$(get_env "$env" "$chave" | tr -d "\"'")"
        if [[ "$valor" =~ $RE_URL_PG ]] && [[ "${BASH_REMATCH[2]}" != USUARIO ]]; then
          acessos+=("${BASH_REMATCH[6]}:${BASH_REMATCH[2]}")
        fi
      done
    done
  done
  mapfile -t acessos < <(printf '%s\n' "${acessos[@]}" | grep -v '^$' | sort -u)

  if [ "${#acessos[@]}" -eq 0 ]; then
    ok "Nenhum .env aponta para o PostgreSQL da máquina (host.docker.internal)"
  else
    # Escuta também no docker0, para onde aponta o host.docker.internal
    listen="$(psql_pg "SHOW listen_addresses")"
    reiniciar=0
    if [ "$listen" != "*" ] && [[ ",$listen," != *",$DOCKER0_IP,"* ]]; then
      sudo grep -qE "^\s*include_dir\s*=\s*'conf.d'" "$PG_DIR/postgresql.conf" \
        || falha "$PG_DIR/postgresql.conf sem include_dir 'conf.d': inclua $DOCKER0_IP em listen_addresses à mão"
      sudo mkdir -p "$PG_DIR/conf.d"
      echo "listen_addresses = '$listen,$DOCKER0_IP'" | sudo tee "$PG_DIR/conf.d/docker.conf" >/dev/null
      reiniciar=1
      ok "listen_addresses: $listen,$DOCKER0_IP"
    else
      ok "listen_addresses já aceita o docker0 ($listen)"
    fi

    for acesso in "${acessos[@]}"; do
      db="${acesso%%:*}" user="${acesso#*:}"
      if sudo grep -qE "^host\s+$db\s+$user\s+$WEB_SUBNET\s" "$PG_DIR/pg_hba.conf"; then
        ok "pg_hba.conf já libera $db/$user para $WEB_SUBNET"
      else
        echo "host  $db  $user  $WEB_SUBNET  scram-sha-256" | sudo tee -a "$PG_DIR/pg_hba.conf" >/dev/null
        ok "pg_hba.conf: $db/$user liberado para $WEB_SUBNET"
      fi
    done

    if [ "$reiniciar" = 1 ]; then sudo systemctl restart postgresql; else sudo systemctl reload postgresql; fi
    ok "PostgreSQL recarregado"
  fi

  # Segurança: não impede o deploy, mas aparece no resumo
  while IFS= read -r linha; do
    nota "pg_hba.conf aceita conexão sem senha (trust) de fora da máquina: \"$linha\". Troque por scram-sha-256 ou restrinja o endereço"
  done < <(sudo grep -hE '^\s*host' "$PG_DIR/pg_hba.conf" | awk '$NF == "trust" && $4 != "127.0.0.1/32" && $4 != "::1/128" && $4 != "localhost" && $4 != "samehost"' | tr -s ' \t' ' ')
  listen="$(psql_pg "SHOW listen_addresses")"
  if [[ "$listen" == "*" || ",$listen," == *",0.0.0.0,"* ]] && ! sudo ufw status 2>/dev/null | grep -q 'Status: active'; then
    nota "PostgreSQL ouve em todas as interfaces (listen_addresses = '$listen') e o firewall está desligado: a porta 5432 fica aberta para a rede"
  fi
fi

# ---------------------------------------------------------------------------
if [ "$FORGE" = gitlab ]; then
  etapa "Runner do GitLab (manual)"
  # Um gitlab-runner atende vários projetos. Ele precisa rodar como o usuário do deploy,
  # para usar o grupo docker e gravar em /opt sem sudo
  projetos="$(for spec in "${REPOS[@]}"; do printf '%s ' "${spec%%:*}"; done)"
  projetos="${projetos% }"
  # Tag pedida pelos jobs de deploy no .gitlab-ci.yml já clonado (o scaffold.sh --runner-tag a define)
  tag_ci="$(grep -hoE '^[[:space:]]*tags:[[:space:]]*\[[^]]+\]' "$BASE"/*/*/.gitlab-ci.yml "$BASE"/*/.gitlab-ci.yml 2>/dev/null \
    | head -1 | sed -E 's/.*\[[[:space:]]*//; s/[][[:space:]]//g' || true)"
  tag_ci="${tag_ci:-$SISTEMA}"
  if command -v gitlab-runner >/dev/null && systemctl cat gitlab-runner >/dev/null 2>&1; then
    if systemctl show -p ExecStart --value gitlab-runner | grep -qE -- "--user[= ]$USUARIO( |;|$)"; then
      ok "gitlab-runner instalado como serviço do usuário $USUARIO"
    else
      aviso "gitlab-runner não roda como $USUARIO: refaça o install do passo a passo abaixo"
    fi
    # No config.toml, e não no gitlab-runner list: a saída dele tem códigos de cor no meio
    # (URL, código de cor, =https://...), e a busca não achava o runner registrado
    # O do serviço (/etc); o da home só vale quando o serviço não tem um
    registrados="$( { sudo cat /etc/gitlab-runner/config.toml 2>/dev/null || cat "$HOME/.gitlab-runner/config.toml" 2>/dev/null; } \
      | grep -cE "^[[:space:]]*url[[:space:]]*=[[:space:]]*\"https?://$GIT_HOST/?\"" || true)"
    if [ "$registrados" -gt 0 ]; then
      ok "$registrados runner(s) registrado(s) em $GIT_HOST: confira se atendem $projetos"
    else
      aviso "gitlab-runner sem registro em $GIT_HOST: siga o passo a passo abaixo"
    fi
  else
    aviso "gitlab-runner não instalado: siga o passo a passo abaixo"
  fi
  cat <<EOF

    Passo a passo, uma vez por VM:
      curl -fsSL https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh | sudo bash
      sudo apt-get install -y gitlab-runner
      sudo gitlab-runner uninstall
      sudo gitlab-runner install --user $USUARIO --working-directory $HOME
      sudo gitlab-runner start

    Em cada projeto ($projetos):
      No GitLab: Settings > CI/CD > Runners > New project runner, com a tag $tag_ci.
      Na versão 15 ou anterior, use o registration token mostrado na mesma tela.
      Depois, na VM:
        sudo gitlab-runner register --non-interactive --url https://$GIT_HOST \\
          --token <glrt-...> --executor shell --name $(hostname)-$SISTEMA

    No Ubuntu, o ~/.bash_logout limpa o terminal e faz o job falhar em "prepare environment":
      sed -i '/clear_console/s/^/#/' ~/.bash_logout

    No .gitlab-ci.yml: tags: [$tag_ci], GIT_STRATEGY: none e resource_group por ambiente.
EOF
else
etapa "Runners do GitHub Actions"
for spec in "${REPOS[@]}"; do
  ler_repo "$spec"
  # Runners deste repositório já instalados na VM (em qualquer pasta e de qualquer usuário; o
  # endereço não diferencia maiúsculas: SEMIT-SUAS/EGGEM e semit-suas/eggem são o mesmo)
  slug_min="$(tr '[:upper:]' '[:lower:]' <<<"$SLUG")"
  mapfile -t deste < <(listar_runners_vm | awk -F'|' -v s="$slug_min" 'tolower($2) ~ ("github.com/" s "/?$")')
  if [ "${#deste[@]}" -gt 0 ]; then
    # Fica o primeiro ativo (ou o primeiro); os outros são duplicados
    manter="$(printf '%s\n' "${deste[@]}" | awk -F'|' '$5 == 1' | head -1)"
    [ -n "$manter" ] || manter="${deste[0]}"
    IFS='|' read -r rdir _ rnome rdono rativo <<<"$manter"
    ok "$SLUG: runner já instalado, reaproveitado: $rnome em $rdir$([ "$rativo" = 1 ] || echo " (serviço parado)")"
    # A label do sistema, que o workflow pede (runs-on: [self-hosted, <sistema>])
    if [ -n "${GH_TOKEN:-}" ]; then
      rjson="$(gh_api GET "repos/$SLUG/actions/runners?per_page=100" 2>/dev/null || true)"
      rid="$(tr -d '\n' <<<"$rjson" | grep -oE "\\{\"id\": *[0-9]+, *\"name\": *\"$rnome\"" | grep -oE '[0-9]+' | head -1 || true)"
      if [ -n "$rid" ]; then
        if gh_api GET "repos/$SLUG/actions/runners/$rid/labels" 2>/dev/null | grep -qE "\"name\": *\"$SISTEMA\""; then
          ok "$SLUG: o runner $rnome já tem a label $SISTEMA"
        elif gh_api POST "repos/$SLUG/actions/runners/$rid/labels" "{\"labels\":[\"$SISTEMA\"]}" >/dev/null 2>&1; then
          ok "$SLUG: label $SISTEMA acrescentada ao runner $rnome"
        else
          aviso "$SLUG: não consegui acrescentar a label $SISTEMA ao runner $rnome: faça em Settings > Actions > Runners"
        fi
      fi
    else
      nota "$SLUG: confira se o runner $rnome tem a label $SISTEMA (Settings > Actions > Runners); sem ela, o deploy fica na fila"
    fi
    # Duplicados: cada job roda num runner só, mas dois deixam deploys de produção e homologação
    # compilarem ao mesmo tempo, e um deles pode ser o do deploy antigo
    for e in "${deste[@]}"; do
      [ "$e" != "$manter" ] || continue
      IFS='|' read -r ddir _ dnome ddono _ <<<"$e"
      echo "    Outro runner do mesmo repositório: $dnome em $ddir (de $ddono)."
      # Só com terminal e perguntando (o --yes não remove runner)
      if [ -n "${GH_TOKEN:-}" ] && [ "$SIM" = 0 ] && confirmar "Remover o runner duplicado $dnome? (a pasta $ddir fica)"; then
        if remover_runner "$ddir" "$ddono"; then
          ok "$SLUG: runner duplicado $dnome removido (serviço e registro no GitHub)"
        else
          aviso "$SLUG: não consegui remover o runner $dnome: em $ddir, rode sudo ./svc.sh uninstall e ./config.sh remove"
        fi
      else
        nota "$SLUG: runner duplicado $dnome em $ddir. Para remover: cd $ddir && sudo ./svc.sh stop && sudo ./svc.sh uninstall && ./config.sh remove --token <token de remoção>"
      fi
    done
    continue
  fi
  if [ -z "${GH_TOKEN:-}" ]; then
    aviso "$SLUG: runner não instalado (falta GH_TOKEN)"
    continue
  fi

  if [ -z "${RUNNER_TGZ:-}" ]; then
    case "$(uname -m)" in x86_64) arq=x64 ;; aarch64) arq=arm64 ;; *) falha "arquitetura $(uname -m) sem runner" ;; esac
    versao="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | grep -oE '"tag_name": *"v[^"]+"' | grep -oE '[0-9][^"]*')"
    RUNNER_TGZ="$(mktemp --suffix .tar.gz)"
    curl -fsSLo "$RUNNER_TGZ" "https://github.com/actions/runner/releases/download/v$versao/actions-runner-linux-$arq-$versao.tar.gz"
  fi

  token="$(gh_api POST "repos/$SLUG/actions/runners/registration-token" | grep -oE '"token": *"[^"]+"' | cut -d'"' -f4)"
  [ -n "$token" ] || falha "não consegui gerar o token do runner de $SLUG"

  dir="$HOME/actions-runner-$SISTEMA${PASTA:+-$PASTA}"
  mkdir -p "$dir" && tar xzf "$RUNNER_TGZ" -C "$dir"
  (
    cd "$dir"
    ./config.sh --unattended --replace --url "https://github.com/$SLUG" --token "$token" \
      --name "$(hostname)-$SISTEMA${PASTA:+-$PASTA}" --labels "$SISTEMA${LABELS:+,$LABELS}" --work _work
    sudo ./svc.sh install "$USUARIO" >/dev/null
    sudo ./svc.sh start >/dev/null
  )
  ok "$SLUG: runner $versao instalado como serviço em $dir"
done
[ -z "${RUNNER_TGZ:-}" ] || rm -f "$RUNNER_TGZ"
fi

# ---------------------------------------------------------------------------
if [ "$DEPLOY" = 1 ]; then
  etapa "Primeiro deploy"
  if [ "${#PENDENCIAS[@]}" -gt 0 ]; then
    aviso "Deploy não executado: resolva as pendências antes"
  else
    # 1. Imagens compiladas com o sistema atual ainda no ar
    seguir=1
    for amb in "${ORDEM_DEPLOY[@]}"; do
      for spec in "${REPOS[@]}"; do
        ler_repo "$spec"
        printf '    %s%s%s Compilando %s (%s); pode levar alguns minutos...\n' "$CIANO" "$I_INFO" "$RESET" "$SLUG" "$amb"
        if compilar_imagens "$RAIZ/$amb" "$amb"; then
          ok "$SLUG ($amb): imagens compiladas"
        else
          aviso "$SLUG ($amb): a compilação falhou, nada foi parado. Últimas linhas de $BASE/build-$amb.log:"
          tail -15 "$BASE/build-$amb.log" | sed 's/^/        /'
          seguir=0
          break 2
        fi
      done
    done

    # 2. O sistema atual sai do ar só agora, com tudo pronto
    if [ "$seguir" = 1 ] && tem_sistema_atual; then
      printf '    %s%s%s Imagens prontas. O sistema atual sai do ar até o deploy terminar (cerca de 1 minuto):\n' "$CIANO" "$I_INFO" "$RESET"
      if ! parar_sistema_atual; then
        aviso "Porta(s) $PORTAS_TXT ainda ocupada(s): deploy não executado"
        religar_sistema_atual
        seguir=0
      fi
    fi

    # 3. Deploy, homologação primeiro; se falhar, o sistema anterior é religado
    if [ "$seguir" = 1 ]; then
      for amb in "${ORDEM_DEPLOY[@]}"; do
        for spec in "${REPOS[@]}"; do
          ler_repo "$spec"
          if sg docker -c "cd '$RAIZ/$amb' && bash deploy.sh '$amb'" </dev/null; then
            ok "$SLUG: deploy de $amb concluído"
          else
            aviso "$SLUG: deploy de $amb falhou (veja a saída acima); os seguintes não foram executados"
            if [ "${#REVERTER[@]}" -gt 0 ]; then
              printf '    %s%s%s Religando o sistema anterior:\n' "$CIANO" "$I_INFO" "$RESET"
              religar_sistema_atual
            fi
            seguir=0
            break 2
          fi
        done
      done
      if [ "$seguir" = 1 ] && [ "${#REVERTER[@]}" -gt 0 ]; then
        printf '    %s%s%s Para voltar ao sistema anterior, na ordem:\n' "$CIANO" "$I_INFO" "$RESET"
        printf '        %s rm -f nginx\n' "${DOCKER[*]}"
        for ((i = ${#REVERTER[@]} - 1; i >= 0; i--)); do printf '        %s\n' "${REVERTER[$i]}"; done
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
etapa "Conferência"
# O Docker passa por cima do UFW: qualquer porta publicada fica aberta para a rede
expostos="$("${DOCKER[@]}" ps --format '{{.Names}} {{.Ports}}' | grep -E '0\.0\.0\.0:|\[::\]:' | grep -vE '^nginx ' || true)"
if [ -n "$expostos" ]; then
  while IFS= read -r l; do aviso "Contêiner com porta aberta para a rede (o UFW não bloqueia): $l"; done <<<"$expostos"
else
  ok "Só o Nginx publica portas"
fi

etapa "Resumo"
for spec in "${REPOS[@]}"; do
  ler_repo "$spec"
  printf '    %s%s%s %s %s%s %s%s\n' "$AZUL" "$I_LOGO" "$RESET" "$SLUG" "$FRACO" "$I_SETA" "$(if [ "$SEM_HML" = 1 ]; then echo "$RAIZ/$PROD_NOME (só produção)"; else echo "$RAIZ/{$PROD_NOME,$HML_NOME}"; fi)" "$RESET"
done
if [ "${#PENDENCIAS[@]}" -eq 0 ]; then
  ok "Nenhuma pendência"
  [ "$DEPLOY" = 1 ] || printf '    %s%s%s Próximo passo: rode de novo e escolha fazer o deploy (com sistema atual no ar, o push não basta)\n' "$CIANO" "$I_INFO" "$RESET"
else
  printf '    %s%s %d pendência(s):%s\n' "$AMARELO$NEGRITO" "$I_AVISO" "${#PENDENCIAS[@]}" "$RESET"
  for p in "${PENDENCIAS[@]}"; do printf '      %s%s%s %s\n' "$AMARELO" "$I_ITEM" "$RESET" "$p"; done
fi
if [ "${#NOTAS[@]}" -gt 0 ]; then
  printf '    %s%s Atenção (não impede o deploy):%s\n' "$AMARELO$NEGRITO" "$I_AVISO" "$RESET"
  for p in "${NOTAS[@]}"; do printf '      %s%s%s %s\n' "$AMARELO" "$I_ITEM" "$RESET" "$p"; done
fi
[ "${DOCKER[0]}" = sudo ] && printf '    %s%s%s Saia e entre de novo na sessão para usar docker sem sudo.\n' "$CIANO" "$I_INFO" "$RESET"
if [ "${#PENDENCIAS[@]}" -gt 0 ]; then
  printf '    %s%s%s Resolvidas as pendências, rode %s e escolha continuar: as respostas são reaproveitadas\n' "$CIANO" "$I_INFO" "$RESET" "$CHAMADA"
fi
printf '\n%s%s Concluído em %dmin%02ds%s\n' "$VERDE$NEGRITO" "$I_OK" $((SECONDS / 60)) $((SECONDS % 60)) "$RESET"
exit 0
}
