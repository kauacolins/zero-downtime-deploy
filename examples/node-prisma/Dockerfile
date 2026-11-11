# Imagem de produção de uma API Node.js com Prisma. Ajuste à vontade.
FROM node:20-bookworm-slim AS base
RUN apt-get update -y && apt-get install -y --no-install-recommends openssl ca-certificates \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /app

FROM base AS builder
COPY package.json package-lock.json* yarn.lock* pnpm-lock.yaml* ./
COPY prisma ./prisma
# Instala pelo lock que o projeto tiver (npm, yarn ou pnpm); sem lock, npm install
RUN if [ -f package-lock.json ]; then npm ci; \
    elif [ -f yarn.lock ]; then corepack enable && yarn install --frozen-lockfile; \
    elif [ -f pnpm-lock.yaml ]; then corepack enable && pnpm install --frozen-lockfile; \
    else npm install; fi \
  && npx prisma generate
# {{BUILD_ARGS_DOCKERFILE}}
COPY . .
# Compila se o package.json tiver o script "build" (TypeScript)
RUN npm run build --if-present

FROM base AS runner
ENV NODE_ENV=production PORT={{PORTA_APP}}
# Com as devDependencies: o Prisma CLI roda a migração (MIGRATE_CMD) nesta mesma imagem
COPY --from=builder /app ./
# {{CRIAR_PASTAS_DOCKERFILE}}
USER node
EXPOSE {{PORTA_APP}}
# O script "start" do package.json precisa ouvir na porta da variável PORT
CMD ["npm", "start"]
