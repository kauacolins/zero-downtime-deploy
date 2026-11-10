#!/usr/bin/env bash
# setup-host.sh: prepara uma VM Ubuntu para deploy blue-green de qualquer sistema,
# com homologação e produção na mesma máquina. Ajuda: bash setup-host.sh --help
# Documentação: README.md do repositório.
set -euo pipefail

# ---------------------------------------------------------------------------
# Parâmetros
FORGE=github GIT_HOST=github.com
SISTEMA="" PROD_NOME=production PROD_BRANCH=main HML_NOME=developer HML_BRANCH=dev
SEGREDOS="" PG_HML="" PG_URL="" PG_URL_USADA=0 CLONAR=1 DEPLOY=0 SIM=0
REPOS=() PG_ACESSOS=() ENV_TODOS=() ENV_PROD=() ENV_HML=()

VERSAO=2.0.0

# Texto embutido: funciona também quando o script vem direto do curl, sem arquivo
uso() {
  echo "setup-host.sh $VERSAO"
  echo
  cat <<'AJUDA'
Prepara uma VM Ubuntu para deploy blue-green de qualquer sistema, com homologação e
produção na mesma máquina. Pode ser rodado de novo: cada etapa pula o que já está feito.

Rode com o usuário do deploy (não como root), que precisa de sudo. Exemplos:

  # Um repositório (Siscon): /opt/siscon/{production,developer}
  bash setup-host.sh --sistema siscon --repo SEMIT-SUAS/siscon \
    --pg-hml siscon_hml --segredos "AUTH_SECRET NEXTAUTH_SECRET JWT_SECRET APP_ENCRYPTION_KEY" \
    --env NODE_ENV=production --env-prod NEXTAUTH_URL=https://siscon.saoluis.ma.gov.br \
    --env-hml NEXTAUTH_URL=http://10.0.0.160:3001

  # Vários repositórios (CIS): /opt/cis/{api,frontend}/{production,homolog}
  bash setup-host.sh --sistema cis --hml-nome homolog --hml-branch homolog \
    --repo SEMIT-SUAS/cis-api:api --repo SEMIT-SUAS/cis-frontend:frontend:front

  # GitLab (subgrupos valem): deploy key e runner ficam manuais, com passo a passo
  bash setup-host.sh --sistema sisx --gitlab gitlab.saoluis.ma.gov.br --repo semit/sisx

Opções:
  --sistema NOME          obrigatório; as pastas ficam em /opt/NOME
  --repo DONO/REPO[:PASTA[:LABELS]]
                          repetível. PASTA é a subpasta em /opt/NOME (padrão: nenhuma com
                          um repositório, o nome do repositório com vários). LABELS são as
                          labels extras do runner, separadas por vírgula (ex.: front)
  --prod-nome / --prod-branch   padrão: production / main
  --hml-nome  / --hml-branch    padrão: developer / dev
  --segredos "CHAVE ..."  chaves do .env que recebem segredo aleatório, se ainda
                          estiverem com o valor do arquivo de exemplo
  --env CHAVE=VALOR       repetível; grava no .env dos dois ambientes (ex.: NODE_ENV=production)
  --env-prod / --env-hml CHAVE=VALOR
                          repetíveis; gravam só no .env daquele ambiente (ex.: NEXTAUTH_URL)
  --pg-hml NOME           cria banco e usuário NOME no PostgreSQL da máquina
  --pg-acesso BANCO:USUARIO
                          repetível; libera o banco para a rede Docker no pg_hba.conf
  --gitlab HOST           repositórios no GitLab (gitlab.com ou um servidor próprio). A deploy
                          key e o runner ficam manuais: o script mostra o passo a passo
  --sem-clone             não clona (o workflow do sistema cria as pastas sozinho)
  --deploy                roda deploy.sh de cada pasta no final, homologação primeiro
  --sim                   não pergunta antes de parar o PM2 ou o Nginx que ocupa as portas 80/3001

Acesso ao GitHub (cadastrar deploy keys e registrar runners; não vale para o GitLab):
  GH_TOKEN   token com escopo repo e admin nos repositórios. Na sua máquina: gh auth token.
             Na VM, cole sem deixar no histórico: read -rs GH_TOKEN && export GH_TOKEN
             Sem ele, o script mostra o que cadastrar à mão e lista como pendência.
AJUDA
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --sistema) SISTEMA="$2"; shift 2 ;;
    --repo) REPOS+=("$2"); shift 2 ;;
    --prod-nome) PROD_NOME="$2"; shift 2 ;;
    --prod-branch) PROD_BRANCH="$2"; shift 2 ;;
    --hml-nome) HML_NOME="$2"; shift 2 ;;
    --hml-branch) HML_BRANCH="$2"; shift 2 ;;
    --segredos) SEGREDOS="$2"; shift 2 ;;
    --env) ENV_TODOS+=("$2"); shift 2 ;;
    --env-prod) ENV_PROD+=("$2"); shift 2 ;;
    --env-hml) ENV_HML+=("$2"); shift 2 ;;
    --pg-hml) PG_HML="$2"; shift 2 ;;
    --pg-acesso) PG_ACESSOS+=("$2"); shift 2 ;;
    --gitlab)
      FORGE=gitlab
      GIT_HOST="${2#*://}"
      GIT_HOST="${GIT_HOST%%/*}"
      shift 2
      ;;
    --sem-clone) CLONAR=0; shift ;;
    --deploy) DEPLOY=1; shift ;;
    --sim) SIM=1; shift ;;
    -h|--help) uso ;;
    --versao|--version) echo "setup-host.sh $VERSAO"; exit 0 ;;
    *) echo "Opção desconhecida: $1" >&2; uso 1 ;;
  esac
done

[ -n "$SISTEMA" ] || { echo "Falta --sistema" >&2; uso 1; }
[ "${#REPOS[@]}" -gt 0 ] || { echo "Falta ao menos um --repo" >&2; uso 1; }
[[ "$SISTEMA" =~ ^[a-z0-9_-]+$ ]] || { echo "--sistema aceita só minúsculas, números, _ e -" >&2; exit 1; }

BASE="/opt/$SISTEMA"
USUARIO="$(id -un)"
GRUPO="$(id -gn)"
PENDENCIAS=()

etapa() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }
ok() { printf '    \033[32m✓\033[0m %s\n' "$1"; }
aviso() { printf '    \033[33m!\033[0m %s\n' "$1"; PENDENCIAS+=("$1"); }
falha() { printf '\n\033[31mErro: %s\033[0m\n' "$1" >&2; exit 1; }

confirmar() {
  [ "$SIM" = 1 ] && return 0
  local resp=""
  # 2> antes de </dev/tty: sem terminal (ssh sem -t, CI), a falha ao abrir não aparece
  read -r -p "    $1 [s/N] " resp 2>/dev/null </dev/tty || return 1
  [[ "$resp" =~ ^[sS]$ ]]
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
etapa "PM2"
# Sistemas que já rodam pelo PM2 são parados e deixam de subir no boot, mas a lista de
# processos (dump.pm2) e os arquivos de cada app ficam: dá para voltar com pm2 resurrect.
pm2_achou=0

# 1. Daemons do PM2 em execução, de qualquer usuário
for pid in $(pgrep -f 'PM2 v[0-9.]+: God Daemon' || true); do
  pm2_achou=1
  dono_pm2="$(ps -o user= -p "$pid" | tr -d ' ')"
  pm2_home="$(tr '\0' ' ' < "/proc/$pid/cmdline" | sed -nE 's/.*\((.*)\).*/\1/p')"
  # O pm2 fica ao lado do node que roda o daemon (instalação global ou nvm)
  node_bin="$(sudo readlink -f "/proc/$pid/exe")"
  pm2_bin="$(dirname "$node_bin")/pm2"
  [ -x "$pm2_bin" ] || pm2_bin="$(command -v pm2 || true)"
  if [ -z "$pm2_bin" ]; then
    aviso "PM2 de $dono_pm2 ($pm2_home) em execução, mas não achei o executável pm2: rode pm2 stop all e pm2 unstartup à mão"
    continue
  fi
  pm2_de() { sudo -u "$dono_pm2" env PATH="$(dirname "$node_bin"):/usr/local/bin:/usr/bin:/bin" PM2_HOME="$pm2_home" "$pm2_bin" "$@"; }

  online="$(pm2_de jlist 2>/dev/null | grep -o '"status":"online"' | wc -l)"
  if [ "$online" -eq 0 ]; then
    ok "PM2 de $dono_pm2: nenhum processo rodando"
    continue
  fi
  echo "    PM2 de $dono_pm2 ($pm2_home) com $online processo(s) rodando:"
  pm2_de ls --no-color 2>/dev/null | sed 's/^/      /'
  if confirmar "Parar todos os processos do PM2 de $dono_pm2? (nada é apagado)"; then
    # Sem pm2 save: o dump.pm2 continua com a lista anterior, para o pm2 resurrect
    pm2_de stop all >/dev/null
    ok "PM2 de $dono_pm2 parado; para voltar: pm2 resurrect"
  else
    aviso "PM2 de $dono_pm2 continua rodando $online processo(s)"
  fi
done

# 2. Inicialização automática do PM2 (unidades pm2-<usuário>.service)
for unidade in $(systemctl list-unit-files --type=service --no-legend 'pm2-*.service' 2>/dev/null | awk '{print $1}'); do
  pm2_achou=1
  dono_pm2="$(systemctl show -p User --value "$unidade")"
  dono_pm2="${dono_pm2:-root}"
  casa="$(getent passwd "$dono_pm2" | cut -d: -f6)"
  pm2_bin="$(systemctl show -p ExecStart --value "$unidade" | grep -oE 'path=[^ ;]+' | head -1 | cut -d= -f2)"
  pm2_path="$(systemctl show -p Environment --value "$unidade" | tr ' ' '\n' | sed -n 's/^PATH=//p')"
  if confirmar "Desativar a inicialização automática do PM2 de $dono_pm2 ($unidade)?"; then
    if [ -x "$pm2_bin" ] && sudo env PATH="${pm2_path:-/usr/local/bin:/usr/bin:/bin}" "$pm2_bin" unstartup systemd -u "$dono_pm2" --hp "$casa" >/dev/null 2>&1; then
      ok "pm2 unstartup feito para $dono_pm2; para voltar: pm2 startup"
    else
      # Mesmo efeito do unstartup, sem depender do executável
      sudo systemctl disable "$unidade" >/dev/null 2>&1 || true
      ok "$unidade desabilitada (sem o pm2 unstartup); para voltar: sudo systemctl enable $unidade"
    fi
  else
    aviso "PM2 de $dono_pm2 continua subindo no boot ($unidade)"
  fi
done

[ "$pm2_achou" = 1 ] || ok "PM2 não está em uso"

# ---------------------------------------------------------------------------
etapa "Portas 80 e 3001"
# Todo Nginx que ocupar as portas é desligado, nunca apagado: a configuração fica onde está
# e ele pode ser religado. Antes, pergunta, porque tira do ar o que ele atende.
portas_ocupadas() { sudo ss -ltnpH '( sport = :80 or sport = :3001 )' | grep -v docker-proxy || true; }

# 1. Nginx da máquina, gerenciado pelo systemd
if systemctl cat nginx.service >/dev/null 2>&1; then
  if systemctl is-active --quiet nginx; then
    echo "    O Nginx instalado na máquina está ativo e ocupa a porta 80."
    if confirmar "Parar e desabilitar o Nginx da máquina? (/etc/nginx é mantido)"; then
      sudo systemctl disable --now nginx
      ok "Nginx da máquina parado e desabilitado; para voltar: sudo systemctl enable --now nginx"
    else
      aviso "Nginx da máquina continua ligado: o Nginx em contêiner não vai subir"
    fi
  elif systemctl is-enabled --quiet nginx 2>/dev/null; then
    # Parado, mas voltaria no próximo boot e tomaria a porta 80 antes do Docker
    sudo systemctl disable nginx
    ok "Nginx da máquina já estava parado; desabilitado para não voltar no boot"
  fi
fi

# 2. Nginx da máquina iniciado fora do systemd (o do systemd mantido acima não conta)
if ! systemctl is-active --quiet nginx 2>/dev/null && portas_ocupadas | grep -q '"nginx"'; then
  if confirmar "Há um processo nginx fora do systemd nas portas 80/3001. Pará-lo (sem apagar a configuração)?"; then
    # Só pelo nginx da máquina: um pkill acertaria também o nginx dos contêineres
    if command -v nginx >/dev/null && sudo nginx -s quit 2>/dev/null; then
      sleep 2
      ok "Processo nginx parado"
    else
      aviso "Não consegui parar o nginx fora do systemd: pare-o à mão (sem apagar /etc/nginx)"
    fi
  fi
fi

# 3. Contêineres de outros sistemas publicando as portas
for c in $("${DOCKER[@]}" ps --format '{{.Names}}'); do
  portas="$("${DOCKER[@]}" port "$c" 2>/dev/null | grep -E ':(80|3001)$' || true)"
  [ -n "$portas" ] || continue
  dono="$("${DOCKER[@]}" inspect "$c" -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')"
  [[ -n "$dono" && "$dono" == "$BASE"* ]] && { ok "Contêiner $c já é deste sistema"; continue; }
  imagem="$("${DOCKER[@]}" inspect "$c" -f '{{.Config.Image}}')"
  echo "    O contêiner $c ($imagem, de ${dono:-origem desconhecida}) ocupa a porta 80 ou 3001."
  if confirmar "Parar o contêiner $c? (ele e a configuração são mantidos)"; then
    # Sem isto, a política de restart o religaria com o Docker ou no boot
    "${DOCKER[@]}" update --restart=no "$c" >/dev/null
    "${DOCKER[@]}" stop "$c" >/dev/null
    ok "Contêiner $c parado; para voltar: docker update --restart=unless-stopped $c && docker start $c"
  else
    aviso "Contêiner $c continua nas portas 80/3001: o Nginx deste sistema não vai subir"
  fi
done

# Um contêiner parado chamado nginx impediria o deploy de criar o deste sistema com o mesmo nome
if "${DOCKER[@]}" inspect nginx >/dev/null 2>&1; then
  dono="$("${DOCKER[@]}" inspect nginx -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')"
  if [[ "$dono" != "$BASE"* ]] && [ "$("${DOCKER[@]}" inspect -f '{{.State.Running}}' nginx)" != true ]; then
    "${DOCKER[@]}" rename nginx "nginx-parado-$(date +%Y%m%d)"
    ok "Contêiner nginx parado de ${dono:-outro sistema} renomeado para nginx-parado-$(date +%Y%m%d) (não foi apagado)"
  fi
fi

ocupadas="$(portas_ocupadas)"
if [ -n "$ocupadas" ]; then
  aviso "Porta 80 ou 3001 ainda ocupada: $(echo "$ocupadas" | awk '{print $4, $6}' | tr '\n' ' ')"
else
  ok "Portas 80 e 3001 livres para o Nginx deste sistema"
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

    for par in "$PROD_NOME:$PROD_BRANCH" "$HML_NOME:$HML_BRANCH"; do
      amb="${par%%:*}" branch="${par#*:}"
      dest="$RAIZ/$amb"
      mkdir -p "$RAIZ"
      if [ -d "$dest/.git" ]; then
        ok "$dest já clonado ($(git -C "$dest" branch --show-current))"
      elif ! git ls-remote --exit-code --heads "$url" "$branch" >/dev/null 2>&1; then
        aviso "$SLUG não tem a branch $branch: crie-a ou ajuste --prod-branch/--hml-branch ($amb não clonado)"
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
  for amb in "$PROD_NOME" "$HML_NOME"; do
    dest="$RAIZ/$amb"
    [ -d "$dest/.git" ] || continue
    faltam=()
    [ -f "$dest/deploy.sh" ] || faltam+=("deploy.sh")
    [ -f "$dest/Dockerfile" ] || faltam+=("Dockerfile")
    compgen -G "$dest/*blue*.y*ml" >/dev/null || faltam+=("compose da cor blue")
    compgen -G "$dest/*green*.y*ml" >/dev/null || faltam+=("compose da cor green")
    if [ "$FORGE" = gitlab ]; then
      [ -f "$dest/.gitlab-ci.yml" ] || faltam+=(".gitlab-ci.yml")
    else
      grep -qslE 'self-hosted' "$dest"/.github/workflows/*.y*ml || faltam+=("workflow com runs-on: self-hosted")
    fi
    if [ "${#faltam[@]}" -eq 0 ]; then
      ok "$SLUG ($amb): arquivos de deploy presentes"
    else
      aviso "$SLUG ($amb) sem: ${faltam[*]}. Veja a pasta modelos/ e o README do zero-downtime-deploy"
    fi
  done
done

# ---------------------------------------------------------------------------
if [ -n "$PG_HML" ] || [ "${#PG_ACESSOS[@]}" -gt 0 ]; then
  etapa "PostgreSQL da máquina"
  PG_DIR="$(ls -d /etc/postgresql/*/main 2>/dev/null | sort -V | tail -1 || true)"
  [ -n "$PG_DIR" ] || falha "PostgreSQL não encontrado em /etc/postgresql"
  psql_pg() { sudo -u postgres psql -v ON_ERROR_STOP=1 -tAc "$1"; }
  WEB_SUBNET="$("${DOCKER[@]}" network inspect web -f '{{(index .IPAM.Config 0).Subnet}}')"
  DOCKER0_IP="$(ip -4 -o addr show docker0 | awk '{print $4}' | cut -d/ -f1)"

  if [ -n "$PG_HML" ]; then
    [[ "$PG_HML" =~ ^[a-z0-9_]+$ ]] || falha "--pg-hml aceita só minúsculas, números e _"
    PG_ACESSOS+=("$PG_HML:$PG_HML")
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

  for acesso in "${PG_ACESSOS[@]}"; do
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

# ---------------------------------------------------------------------------
etapa "Arquivos .env"
for spec in "${REPOS[@]}"; do
  ler_repo "$spec"
  for amb in "$PROD_NOME" "$HML_NOME"; do
    dest="$RAIZ/$amb"
    [ -d "$dest" ] || continue

    # Pastas montadas como volume: sem isto, o Docker as cria como root
    for vol in uploads arquivos; do
      grep -qsE "\./$vol:" "$dest"/*compose*.y*ml && mkdir -p "$dest/$vol"
    done

    exemplo="$(ls "$dest"/.env.example "$dest"/.env.exemple "$dest"/example.env "$dest"/env.example 2>/dev/null | head -1 || true)"
    env="$dest/.env"
    if [ ! -f "$env" ]; then
      [ -n "$exemplo" ] || { aviso "$dest sem .env nem arquivo de exemplo (.env.example): crie o .env à mão"; continue; }
      cp "$exemplo" "$env"
      ok "$dest/.env criado a partir de $(basename "$exemplo")"
    fi
    chmod 600 "$env"

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

    # Segredos próprios de cada ambiente; os já definidos não mudam (mudar derruba sessões)
    for chave in $SEGREDOS; do
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

    # O que ainda está igual ao exemplo precisa ser revisto à mão
    if [ -n "$exemplo" ]; then
      iguais=()
      while IFS= read -r linha; do
        chave="${linha%%=*}" valor="${linha#*=}"
        [ -n "$valor" ] && [ "$(get_env "$env" "$chave")" = "$valor" ] && iguais+=("$chave")
      done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$exemplo")
      [ "${#iguais[@]}" -eq 0 ] || aviso "Revise em $env (iguais ao exemplo): ${iguais[*]}"
    fi
  done
done

if [ -n "$PG_URL" ] && [ "$PG_URL_USADA" = 0 ]; then
  printf '%s\n' "$PG_URL" > "$BASE/$PG_HML.url" && chmod 600 "$BASE/$PG_HML.url"
  aviso "Endereço do banco $PG_HML salvo em $BASE/$PG_HML.url: copie para o .env de homologação"
fi

# ---------------------------------------------------------------------------
if [ "$FORGE" = gitlab ]; then
  etapa "Runner do GitLab (manual)"
  # Um gitlab-runner atende vários projetos. Ele precisa rodar como o usuário do deploy,
  # para usar o grupo docker e gravar em /opt sem sudo
  projetos="$(for spec in "${REPOS[@]}"; do printf '%s ' "${spec%%:*}"; done)"
  projetos="${projetos% }"
  if command -v gitlab-runner >/dev/null && systemctl cat gitlab-runner >/dev/null 2>&1; then
    if systemctl show -p ExecStart --value gitlab-runner | grep -qE -- "--user[= ]$USUARIO( |;|$)"; then
      ok "gitlab-runner instalado como serviço do usuário $USUARIO"
    else
      aviso "gitlab-runner não roda como $USUARIO: refaça o install do passo a passo abaixo"
    fi
    registrados="$(sudo gitlab-runner list 2>&1 | grep -cE "URL=https?://$GIT_HOST" || true)"
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
      No GitLab: Settings > CI/CD > Runners > New project runner, com a tag $SISTEMA.
      Na versão 15 ou anterior, use o registration token mostrado na mesma tela.
      Depois, na VM:
        sudo gitlab-runner register --non-interactive --url https://$GIT_HOST \\
          --token <glrt-...> --executor shell --name $(hostname)-$SISTEMA

    No Ubuntu, o ~/.bash_logout limpa o terminal e faz o job falhar em "prepare environment":
      sed -i '/clear_console/s/^/#/' ~/.bash_logout

    No .gitlab-ci.yml: tags: [$SISTEMA], GIT_STRATEGY: none e resource_group por ambiente.
EOF
else
etapa "Runners do GitHub Actions"
for spec in "${REPOS[@]}"; do
  ler_repo "$spec"
  # Um runner atende um repositório; reaproveita o que já existir para ele
  existente="$(grep -lsE "\"gitHubUrl\": *\"https://github.com/$SLUG\"" "$HOME"/actions-runner*/.runner | head -1 || true)"
  if [ -n "$existente" ]; then
    ok "$SLUG: runner já instalado em $(dirname "$existente")"
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
    # Homologação primeiro: se ela falhar, produção não é publicada
    for amb in "$HML_NOME" "$PROD_NOME"; do
      for spec in "${REPOS[@]}"; do
        ler_repo "$spec"
        # sg aplica o grupo docker sem precisar sair da sessão
        if sg docker -c "cd '$RAIZ/$amb' && bash deploy.sh '$amb'"; then
          ok "$SLUG: deploy de $amb concluído"
        else
          aviso "$SLUG: deploy de $amb falhou (veja a saída acima); os seguintes não foram executados"
          break 2
        fi
      done
    done
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
  echo "    $SLUG -> $RAIZ/{$PROD_NOME,$HML_NOME}"
done
if [ "${#PENDENCIAS[@]}" -eq 0 ]; then
  ok "Nenhuma pendência"
  [ "$DEPLOY" = 1 ] || echo "    Próximo passo: rode de novo com --deploy, ou faça push nas branches"
else
  echo "    Pendências:"
  for p in "${PENDENCIAS[@]}"; do echo "      - $p"; done
fi
[ "${DOCKER[0]}" = sudo ] && echo "    Saia e entre de novo na sessão para usar docker sem sudo."
exit 0
