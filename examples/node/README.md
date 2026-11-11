# Node.js

Para servidores Node.js (Express, NestJS, Fastify...). O `scaffold.sh` sugere esta stack quando o repositório tem `package.json` e nenhuma stack mais específica (como a de Next.js) bate.

| Arquivo | Função |
| --- | --- |
| `Dockerfile` | `npm ci`, `npm run build` (se houver) e `npm start` |
| `.dockerignore` | Tira da imagem segredos, dependências e arquivos de deploy |
| `gitignore` | Linhas acrescentadas ao `.gitignore` do sistema |

## Ajustes no projeto

1. O `npm start` precisa ouvir na porta da variável `PORT` (padrão `3000`, ou `--app-port`) e em `0.0.0.0`.
2. Crie a rota de saúde (padrão `/health`, ou `--health`): `200` só com a aplicação pronta, sem exigir login. Se ela depende de um banco, confira-o ali também.
3. Migração de banco: `--migrate-cmd "npm run migrate"` (ou o comando do seu ORM). Ele roda na imagem nova antes da troca, com o `.env` do ambiente.
4. Usa `npm` e `package-lock.json`. Com `yarn` ou `pnpm`, troque as linhas de instalação do `Dockerfile`.
