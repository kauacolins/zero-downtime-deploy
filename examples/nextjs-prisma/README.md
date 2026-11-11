# Next.js com Prisma

Arquivos específicos da stack, para usar junto com os [`modelos/`](../../modelos). O `scaffold.sh --stack nextjs-prisma` copia todos para o repositório do sistema, sem sobrescrever o que já existe.

| Arquivo | Função |
| --- | --- |
| `Dockerfile` | Estágios `migrate` (migrações) e `runner` (imagem final, Next.js standalone) |
| `.dockerignore` | Tira da imagem segredos, dependências e arquivos de deploy |
| `compose.migrate.yml` | Serviço `migrate`, que o `deploy.sh` roda antes de subir a cor nova |
| `.env.example` | Variáveis mínimas, se o sistema ainda não tiver um; o `scaffold.sh` acrescenta as que o código usa e faltam nele. O `setup-host.sh` cria o `.env` a partir dele |
| `src/app/api/health/route.ts` | Rota de saúde: 200 só com o banco acessível |
| `src/lib/db/health.ts` | Consulta ao banco usada pela rota |
| `gitignore` | Linhas acrescentadas ao `.gitignore` do sistema (`.env`; as pastas montadas vêm de `--volume`) |

## Ajustes no projeto

1. Em `next.config.ts`, use `output: "standalone"`. O `scaffold.sh` acrescenta sozinho quando acha o objeto de configuração; senão, avisa.
2. Em `src/lib/db/health.ts`, ajuste o import do Prisma ao caminho do projeto.
3. Se o middleware exige login, deixe `/api/health` de fora do `matcher`. O health check segue redirecionamentos, então um redirecionamento para a tela de login faria uma versão com problema parecer saudável.
4. Se alguma página consulta o banco durante o build, use `export const dynamic = "force-dynamic"` nela ou no layout. O build não tem acesso ao banco nem ao `.env`.
5. Inclua os domínios e o `IP:porta-hml` em `experimental.serverActions.allowedOrigins`, no `next.config.ts`. Sem isso, as Server Actions recusam pedidos que chegam pelo Nginx. O `scaffold.sh` avisa quando o código usa Server Actions sem essa opção.
6. Variáveis `NEXT_PUBLIC_*` são gravadas no build, e o `.env` não entra na imagem. O `scaffold.sh` acha as usadas no código e as declara como `ARG` no `Dockerfile` e `args` nos composes, com o valor do `.env` de cada pasta.
7. Pastas lidas em tempo de execução (ex.: `data/` com arquivos JSON) não entram no build standalone. O `scaffold.sh` as acha no código e as copia no `Dockerfile` (`--copy`).

## Sem Prisma

Remova o estágio `migrate` e o `COPY prisma` do `Dockerfile`, e o `compose.migrate.yml`. Sem esse arquivo, o `deploy.sh` não roda migração.

## Outra stack

Crie uma pasta em `examples/` com os mesmos papéis: um `Dockerfile` cuja imagem tenha `wget`, `curl` ou `node` (usados pelo health check do compose), a rota de saúde e, se houver, o `compose.migrate.yml`.
