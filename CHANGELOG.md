# Changelog

## Não publicado

- **`deploy.conf`:** as respostas do `scaffold.sh` ficam no repositório; rodando de novo, o que está nele não é perguntado. `--upgrade` refaz os arquivos de deploy (os com a marca do projeto) a partir dele.
- **Stacks com detecção:** cada pasta de `examples/` tem um `stack.conf` com a regra de detecção e os padrões; o `scaffold.sh` sugere a mais específica. Novas: `nextjs` (sem Prisma), `node`, `spa` (Vite) e `dockerfile` (o do próprio sistema, para qualquer tecnologia).
- **`--migrate-cmd`:** migração de qualquer ORM, rodada pelo `deploy.sh` na imagem nova antes da troca.
- Arquivos de stack em `src/` vão para a raiz em projetos sem `src/`, e `.ts` vira `.js` em projetos sem TypeScript.
- **Opções em inglês** nos dois scripts; as perguntas e mensagens continuam em português. Os nomes antigos continuam aceitos:
  - `--sistema` → `--system`
  - `--dominio-prod` / `--dominio-hml` → `--prod-domain` / `--staging-domain`
  - `--porta-app` / `--porta-hml` → `--app-port` / `--staging-port`
  - `--prod-nome` / `--hml-nome` / `--hml-branch` → `--prod-name` / `--staging-name` / `--staging-branch`
  - `--sem-homologacao` → `--no-staging`
  - `--substituir-ci` / `--sem-volume` / `--copiar` → `--replace-ci` / `--no-volume` / `--copy`
  - `--limite-upload` / `--ip-prod` / `--tag-runner` → `--upload-limit` / `--prod-ip` / `--runner-tag`
  - `--segredos` / `--env-hml` → `--secrets` / `--env-staging`
  - `--pg-hml` / `--pg-acesso` → `--pg-staging` / `--pg-access`
  - `--origem` / `--sem-clone` / `--sim` → `--source` / `--no-clone` / `--yes`
  - `--interativo` / `--nao-interativo` → `--interactive` / `--non-interactive`

## 2.0.0 (2026-11-10)

Homologação e produção na mesma VM, e ferramentas para preparar a VM e o repositório.

- **`setup-host.sh`:** prepara a VM. Instala o Docker, para o PM2 e qualquer Nginx nas portas 80 e 3001 sem apagar nada, clona os repositórios com uma deploy key por repositório, monta os `.env`, cria o banco de homologação no PostgreSQL da máquina, instala os runners do GitHub e faz o primeiro deploy. Com GitLab, a deploy key e o runner ficam manuais, com passo a passo.
- **`scaffold.sh`:** gera no repositório do sistema os arquivos de deploy a partir de `modelos/`, com CI do GitHub ou do GitLab. Com `--stack`, copia também os arquivos de `examples/`.
- **Dois ambientes:** cada um com o próprio par de cores, branch, pasta (`/opt/<sistema>/<ambiente>`), `.env` e banco. A homologação também responde na porta 3001.
- **Nomes por sistema:** contêineres como `<sistema>_blue_app`, para não colidirem com outros sistemas na rede `web`.
- **Nginx:** a cor ativa fica em `/opt/<sistema>/nginx/<ambiente>.inc`, com o destino em variável e o `resolver` do Docker. Um ambiente parado responde 502 só no próprio domínio.
- **Deploy:** compila antes de migrar, confere se o banco do `.env` é do ambiente, e a migração passa a ser opcional (`compose.migrate.yml`).

### Mudanças incompatíveis com a 1.0.0

- Os arquivos de deploy saíram da raiz: agora são gerados pelo `scaffold.sh` a partir de `modelos/`.
- `docker-compose.{blue,green,nginx}.yml` viraram `compose.{blue,green,nginx}.yml`, e `docker-compose.yaml` virou `compose.migrate.yml`.
- `Dockerfile`, `.dockerignore` e `.env.example` foram para `examples/nextjs-prisma/`.
- O `nginx/upstream.conf` deu lugar aos arquivos `.inc` em `/opt/<sistema>/nginx`.
- A pasta no servidor passou de `/var/www/app` para `/opt/<sistema>/<ambiente>`.

## 1.0.0

Deploy blue-green com um ambiente só, em `/var/www/app`, para Next.js com Prisma.
