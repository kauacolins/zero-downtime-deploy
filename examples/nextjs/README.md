# Next.js sem Prisma

Para sistemas Next.js que não usam Prisma (sem banco, ou com banco por uma API). O `scaffold.sh` sugere esta stack quando o `package.json` tem `next` e não tem `prisma`.

| Arquivo | Função |
| --- | --- |
| `Dockerfile` | Imagem final com o Next.js standalone |
| `.dockerignore` | Tira da imagem segredos, dependências e arquivos de deploy |
| `.env.example` | Variáveis mínimas, se o sistema ainda não tiver um |
| `src/app/api/health/route.ts` | Rota de saúde: 200 com o servidor de pé |
| `gitignore` | Linhas acrescentadas ao `.gitignore` do sistema |

Os ajustes de Next.js valem igual aos da [stack com Prisma](../nextjs-prisma): `output: "standalone"`, `force-dynamic` em páginas que consultam dados no build, `allowedOrigins` para Server Actions e variáveis `NEXT_PUBLIC_*` como argumento de build. O `scaffold.sh` faz ou avisa de cada um.

Para migração de banco sem Prisma, use `--migrate-cmd` (ex.: `npm run migrate`): o comando roda na imagem nova antes da troca.
