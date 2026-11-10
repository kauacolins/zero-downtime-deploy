# Deploy zero downtime com Docker e Nginx

Deploy **blue-green** com **homologação e produção na mesma VM**, para qualquer sistema em contêiner. Cada push publica sozinho, sem tirar o sistema do ar.

| Arquivo | Onde roda | Para quê |
| --- | --- | --- |
| [`setup-host.sh`](setup-host.sh) | Na VM | Prepara a VM para um sistema: Docker, pastas, `.env`, banco de homologação, runner |
| [`scaffold.sh`](scaffold.sh) | Na sua máquina | Gera no repositório do sistema os arquivos de deploy, a partir dos [`modelos/`](modelos) |
| [`examples/`](examples) | | Arquivos específicos de cada stack, como o [`Dockerfile` de Next.js com Prisma](examples/nextjs-prisma) |

A versão 1, com um ambiente só em `/var/www/app`, continua na tag `v1.0.0`. Veja o [CHANGELOG](CHANGELOG.md).

## Como funciona

Cada ambiente tem duas "cores", blue e green. O deploy sobe a versão nova na cor livre, espera ela responder na rota de saúde e só então troca o destino do Nginx. Se a versão nova não ficar saudável, nada muda para o usuário.

```text
                     ┌──────────────────────────── VM ────────────────────────────┐
dominio-prod :80 ──► │ nginx ─► production.inc ─► sistema_blue_app | sistema_green_app │
dominio-hml  :80 ──► │   │                                                         │
IP da VM   :3001 ──► │   └────► developer.inc ─► sistema_hml_blue_app | ..._green_app  │
                     └─────────────────────────────────────────────────────────────┘
push na main ─► runner na VM ─► /opt/<sistema>/production ─► bash deploy.sh production
push na dev  ─► runner na VM ─► /opt/<sistema>/developer  ─► bash deploy.sh developer
```

O `deploy.sh` de cada sistema faz, nesta ordem:

1. Confere se a pasta e o banco do `.env` são do ambiente certo (o de homologação termina em `_hml`).
2. Escolhe a cor livre. No primeiro deploy, usa `blue`.
3. Compila a imagem. Um erro de build não deixa o banco à frente da versão no ar.
4. Roda as migrações, se houver um `compose.migrate.yml`.
5. Sobe a cor livre e espera o health check, por até 2 minutos. Se falhar, derruba a versão nova e encerra com erro.
6. Grava a cor ativa em `/opt/<sistema>/nginx/<ambiente>.inc` e faz `nginx -s reload`, que não derruba conexões.
7. Espera 10 segundos e derruba a cor antiga.

## Uso rápido

### 1. Gere os arquivos de deploy no repositório do sistema

Na sua máquina:

```bash
git clone https://github.com/kauacolins/zero-downtime-deploy.git
bash zero-downtime-deploy/scaffold.sh --sistema meusistema \
  --dominio-prod meusistema.saoluis.ma.gov.br --dominio-hml hml-meusistema.saoluis.ma.gov.br \
  --stack nextjs-prisma  ../meusistema
```

Sem as opções, num terminal, ele pergunta o que faltar (`bash zero-downtime-deploy/scaffold.sh`): lista as pastas com `.git` perto de você (pasta atual, a de cima, a vizinha a este projeto e a home) para escolher pelo número, lê o repositório para sugerir nome, branches, stack e CI, oferece listas de escolha e, se já houver um CI antigo, pergunta se deve mantê-lo ou substituí-lo (o antigo fica em `.bak`). No fim mostra o comando equivalente, para repetir sem perguntas.

Ele também lê o código do sistema e adapta o que gera:

| O que ele procura | O que faz |
| --- | --- |
| Pastas onde a aplicação grava (`public/uploads`, `storage`, `uploads`...) | Monta todas fora do contêiner, cria-as antes de subir e as tira do git e da imagem (documentos de usuários não podem ir para a imagem). `--volume` escolhe à mão; `--sem-volume`, nenhuma |
| Pastas lidas em tempo de execução, como `data/` (stack Next.js) | Copia para a imagem, porque o build standalone não as inclui (`--copiar`) |
| `NEXT_PUBLIC_*` no código | Passa como argumento de build, com o valor do `.env` de cada pasta: o Next grava essas variáveis no build |
| `process.env.X` ausentes do `.env.example` | Acrescenta ao `.env.example`, de onde o `setup-host.sh` cria o `.env` |
| `package.json` | Monta o job de teste: versão do Node, `npm ci`, `prisma generate`, `tsc` ou `typecheck` e `test` |
| `next.config` sem `output: "standalone"` (stack Next.js) | Acrescenta; avisa se o código usa Server Actions sem `allowedOrigins` |

Homologação só com IP atende apenas na porta de homologação; o IP na porta 80 é recusado, a menos que `--ip-prod` o mande para a produção. `--limite-upload` ajusta o maior envio aceito pelo Nginx (padrão `25m`) e, no GitLab, `--tag-runner` define a tag do runner da VM (padrão: o nome do sistema).

O `scaffold.sh` nunca sobrescreve um arquivo que já existe. Revise o que foi gerado, faça os ajustes da stack (veja [Next.js com Prisma](examples/nextjs-prisma)) e faça o commit nas branches de produção e de homologação.

### 2. Prepare a VM

Entre na VM com o **usuário do deploy** (não root, com sudo):

```bash
curl -fsSLO https://raw.githubusercontent.com/kauacolins/zero-downtime-deploy/master/setup-host.sh

# GitHub: o token permite cadastrar a deploy key e o runner sozinho.
# Pegue com "gh auth token" na sua máquina e cole aqui (não fica no histórico):
read -rs GH_TOKEN && export GH_TOKEN

bash setup-host.sh --sistema meusistema --repo SEMIT-SUAS/meusistema \
  --pg-hml meusistema_hml --pg-acesso meusistema:meusistema \
  --segredos "AUTH_SECRET" --env NODE_ENV=production \
  --env-prod NEXTAUTH_URL=https://meusistema.saoluis.ma.gov.br \
  --env-hml NEXTAUTH_URL=http://<IP da VM>:3001
```

Também dá para rodar só `bash setup-host.sh`, sem opções: ele pergunta o repositório, o nome, o `GH_TOKEN` (sem mostrar), as branches (lidas do GitHub), o banco de homologação e os bancos de produção a liberar (em lista de escolha), os segredos e os valores do `.env` que ainda estão iguais ao exemplo. `-i` força as perguntas mesmo com opções; `--nao-interativo` as desliga.

O script guarda as respostas e onde parou em `~/.local/state/zero-downtime-deploy/`, sem o `GH_TOKEN` e sem os valores do `.env`. Ao rodar `bash setup-host.sh` de novo, por exemplo depois de cadastrar a deploy key ou preencher o `.env`, ele oferece **continuar**: mostra as pendências da última vez, reaproveita as respostas (só pergunta de novo o `GH_TOKEN` e se faz o deploy) e pula o que já foi feito. Também dá para **começar do zero**. As cores só aparecem num terminal, e `NO_COLOR=1` as desliga; sem locale UTF-8, os ícones viram caracteres simples.

No fim, o script lista as **pendências**: o que precisa ser feito à mão, como valores do `.env` que continuam iguais ao exemplo. Resolva-as e rode o mesmo comando com `--deploy` para o primeiro deploy, homologação primeiro. Depois disso, cada push publica sozinho.

Para fixar uma versão, troque `master` na URL por uma tag, por exemplo `v2.0.0`. Se este repositório ficar privado, o `curl` precisa de `-H "Authorization: token $GH_TOKEN"`. Ele não guarda segredos, então pode ser público.

## O que o `setup-host.sh` faz

Cada etapa confere se já está feita antes de agir, então o script pode ser rodado de novo quantas vezes for preciso.

| Etapa | O que faz |
| --- | --- |
| Docker | Instala o Docker e o Compose, se faltarem; põe o usuário no grupo `docker`; cria a rede `web` |
| PM2 | Se a VM roda sistemas pelo PM2 (de qualquer usuário), **pergunta** e roda `pm2 stop all` e `pm2 unstartup` |
| Portas 80 e 3001 | Se um Nginx as ocupa (da máquina, iniciado à mão ou em contêiner de outro sistema), **pergunta** e o para |
| Pastas | Cria `/opt/<sistema>` com o usuário do deploy como dono |
| Repositórios | Gera uma deploy key por repositório, cadastra (GitHub, com token) e clona as branches de produção e de homologação |
| Arquivos de deploy | Confere se cada repositório tem `deploy.sh`, `Dockerfile`, os composes das cores e o CI |
| PostgreSQL | Opcional: cria o banco de homologação e libera o acesso da rede Docker |
| `.env` | Cria a partir do exemplo, gera segredos próprios de cada ambiente e grava os valores passados |
| Runner | GitHub: instala um runner por repositório, como serviço. GitLab: mostra o passo a passo |
| Deploy | Opcional (`--deploy`): roda o `deploy.sh` de cada pasta; se homologação falhar, produção não é publicada |
| Conferência | Avisa sobre contêineres com porta aberta para a rede |

### Nada é apagado

Tudo o que o script desliga continua na VM e pode ser religado:

| O que foi parado | Como religar |
| --- | --- |
| Nginx da máquina | `sudo systemctl enable --now nginx` |
| Contêiner de outro sistema | `docker update --restart=unless-stopped <nome> && docker start <nome>` |
| Contêiner `nginx` renomeado | `docker rename nginx-parado-AAAAMMDD nginx` e o comando acima |
| PM2 | `pm2 resurrect` e `pm2 startup` |

Segredos que já existem no `.env` nunca são trocados, porque isso derrubaria as sessões abertas.

### Opções

Lista completa em `bash setup-host.sh --help`.

| Opção | Para quê |
| --- | --- |
| `--sistema NOME` | Obrigatório. As pastas ficam em `/opt/NOME` |
| `--repo DONO/REPO[:PASTA[:LABELS]]` | Repetível. Com vários repositórios, cada um fica em `/opt/NOME/PASTA` |
| `--prod-nome`, `--prod-branch` | Padrão: `production`, `main` |
| `--hml-nome`, `--hml-branch` | Padrão: `developer`, `dev` |
| `--segredos "CHAVE ..."` | Chaves do `.env` que recebem um segredo aleatório |
| `--env`, `--env-prod`, `--env-hml CHAVE=VALOR` | Valores gravados no `.env` dos dois ambientes ou de um só |
| `--pg-hml NOME` | Cria banco e usuário de homologação no PostgreSQL da máquina |
| `--pg-acesso BANCO:USUARIO` | Libera um banco para a rede Docker no `pg_hba.conf` |
| `--gitlab HOST` | Repositórios no GitLab; deploy key e runner ficam manuais |
| `--sem-clone` | Não clona: para sistemas cujo CI cria as pastas sozinho |
| `--deploy` | Faz o primeiro deploy no final |
| `--sim` | Não pergunta antes de parar PM2 e Nginx. **Evite em VM que já atende algum sistema** |

```bash
# Dois repositórios (API e frontend), branch de homologação "homolog"
bash setup-host.sh --sistema cis --hml-nome homolog --hml-branch homolog \
  --repo SEMIT-SUAS/cis-api:api --repo SEMIT-SUAS/cis-frontend:frontend:front

# GitLab próprio, com subgrupo
bash setup-host.sh --sistema sisx --gitlab gitlab.saoluis.ma.gov.br --repo semit/sistemas/sisx
```

### GitHub ou GitLab

A preparação da VM é a mesma. Mudam o acesso ao código e o runner:

| | GitHub | GitLab (`--gitlab HOST`) |
| --- | --- | --- |
| Deploy key | Cadastrada pelo script, com `GH_TOKEN` | Manual: o script mostra a chave e o link |
| Runner | Instalado pelo script, um por repositório, com a label do sistema | Manual: o script mostra os comandos e confere na execução seguinte |
| CI | `.github/workflows/deploy.yml` (`scaffold.sh --ci github`) | `.gitlab-ci.yml` (`scaffold.sh --ci gitlab`) |

O `GH_TOKEN` precisa de escopo `repo` e de admin nos repositórios. Ele só é usado durante a execução e não fica gravado na VM.

## Rollback

A versão anterior continua como imagem na VM, então o rollback leva segundos e não precisa de build. Exemplo em produção, voltando de `green` para `blue`:

```bash
cd /opt/<sistema>/production
export APP_PREFIX=<sistema>_
docker compose -p <sistema>-blue -f compose.blue.yml up -d --wait
echo 'set $app_upstream <sistema>_blue_app:3000;' > /opt/<sistema>/nginx/production.inc
docker exec nginx nginx -t && docker exec nginx nginx -s reload
docker compose -p <sistema>-green -f compose.green.yml down
```

Em homologação, use a pasta `developer`, `APP_PREFIX=<sistema>_hml_`, os projetos `<sistema>-hml-blue` e `<sistema>-hml-green`, o contêiner `<sistema>_hml_blue_app` e o arquivo `developer.inc`.

Depois do rollback:

1. **Reverta o commit na branch.** Ela ainda aponta para a versão com defeito, e o próximo push a publicaria de novo.
2. **Não desfaça a migração às pressas.** O rollback não altera o banco. Se a migração foi compatível, a versão antiga funciona com ela.

Só existe uma versão anterior disponível: o deploy seguinte compila na cor livre e substitui essa imagem.

## O que fica com cada sistema

- **`Dockerfile`:** depende da tecnologia. A imagem precisa ter `wget`, `curl` ou `node` para o health check do compose. Há um pronto para [Next.js com Prisma](examples/nextjs-prisma).
- **Rota de saúde:** responde 200 só quando a aplicação e o banco estão prontos, e sem exigir login.
- **Migrações compatíveis:** as duas versões usam o mesmo banco durante a troca. Para remover ou renomear uma coluna, primeiro faça a versão nova parar de usá-la e só remova no deploy seguinte.
- **`.env.example`:** com todas as variáveis. O `setup-host.sh` cria o `.env` a partir dele.
- **Origens permitidas:** frameworks que conferem a origem do pedido (Next.js Server Actions, Auth.js, CORS) precisam aceitar os domínios e o `IP:3001`.
- **Estado fora do contêiner:** arquivos nas pastas montadas (`--volume`, as mesmas nas duas cores) e sessões em JWT ou armazenamento externo. Sessões em memória se perdem a cada deploy.
- **Dados de homologação:** o banco nasce vazio. Uma cópia de produção precisa ter os dados pessoais anonimizados (LGPD).

## Limites e cuidados

**O que ainda pode causar erro ou queda:**

- **Migração incompatível:** o script não detecta. Veja a regra acima.
- **Pedidos longos:** um pedido que dure mais de 10 segundos na versão antiga pode ser cortado. Aumente o `sleep` no `deploy.sh`, se necessário.
- **Páginas abertas:** quem estiver com uma página da versão antiga pode ver um erro na próxima ação, até recarregar.
- **Memória:** o build roda na VM, ao lado dos sistemas no ar. Um build de homologação pode deixar produção lenta.
- **VM única:** se ela parar, os dois ambientes param. Mantenha backup dos bancos e das pastas montadas; o script não configura backup.

**Configuração e segurança:**

- **Um sistema por VM, por enquanto.** Cada sistema traz o próprio contêiner `nginx` nas portas 80 e 3001. Ao preparar um segundo sistema na mesma VM, o `setup-host.sh` para o Nginx do primeiro (depois de perguntar).
- **Grupo `docker`:** quem está nele pode virar root na prática. O mesmo vale para o runner e para quem altera um workflow que roda nele. Proteja as branches de produção e de homologação e limite o acesso de escrita.
- **Firewall:** o Docker passa por cima do UFW, então uma porta publicada por um contêiner fica aberta para a rede. Só o Nginx deve publicar portas; o script avisa quando outro contêiner publica.
- **HTTPS:** o Nginx escuta só nas portas 80 e 3001 e espera um proxy na frente, como o Cloudflare. Sem isso, configure os certificados nele.
- **Só Ubuntu e Debian**, porque o `setup-host.sh` usa `apt`.

## Problemas comuns

| Sintoma | O que fazer |
| --- | --- |
| "Sem acesso de leitura" ao repositório | Cadastre a deploy key mostrada e rode de novo |
| "não tem a branch" | Crie a branch ou passe `--prod-branch`/`--hml-branch` |
| `docker: permission denied` depois do script | Saia e entre de novo na sessão (grupo `docker`) |
| "O Nginx não subiu" | `sudo ss -ltnp \| grep -E ':80 \|:3001 '` mostra quem ocupa a porta |
| "não ficou saudável" no deploy | O log da cor nova aparece logo acima. Confira o `.env`, o acesso ao banco e a rota de saúde |
| "aponta para um banco de homologação" | O `.env` foi trocado entre os ambientes. Corrija o endereço do banco |
| 502 em um só domínio | A cor ativa do ambiente está parada: `docker ps` e `cat /opt/<sistema>/nginx/<ambiente>.inc` |
| Job do GitLab falha em "prepare environment" | `sed -i '/clear_console/s/^/#/' ~/.bash_logout` no usuário do runner |
| Job do GitHub parado em "Waiting for a runner" | `sudo ./svc.sh status` na pasta `~/actions-runner-<sistema>` |

## Desenvolvimento

- Os scripts precisam terminar linhas com LF; o [`.gitattributes`](.gitattributes) garante isso no Windows.
- O CI roda o [ShellCheck](https://www.shellcheck.net/), gera os arquivos de um sistema de exemplo (GitHub e GitLab, com e sem stack), valida os composes e testa a configuração do Nginx.
- Ao mudar o comportamento, atualize `VERSAO` nos dois scripts, o [`CHANGELOG.md`](CHANGELOG.md) e crie uma tag `vX.Y.Z`.
