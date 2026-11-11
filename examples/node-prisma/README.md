# API Node.js com Prisma

Para APIs Node.js (Express, Fastify, NestJS) com Prisma, sem Next.js. O `scaffold.sh` sugere esta stack quando o `package.json` tem `prisma` e não tem `next`.

- A imagem mantém as devDependencies, para o Prisma CLI rodar a migração (`MIGRATE_CMD`, padrão `npx prisma migrate deploy`) na imagem nova, antes da troca.
- O `npm start` precisa ouvir na porta da variável `PORT` e em `0.0.0.0`.
- Crie a rota de saúde (padrão `/health`): `200` só com a API pronta, sem exigir login.
- O banco vem do `DATABASE_URL` do `.env`. Com o PostgreSQL na própria VM, use `host.docker.internal`.
