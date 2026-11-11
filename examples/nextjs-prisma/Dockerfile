# Imagem de produção (Next.js standalone com Prisma).
FROM node:20-bookworm-slim AS base
RUN apt-get update -y && apt-get install -y --no-install-recommends openssl ca-certificates \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /app

# Todas as dependências: usadas no build e nas migrações (o Prisma CLI é dev dependency)
FROM base AS deps
COPY package.json package-lock.json* yarn.lock* pnpm-lock.yaml* ./
COPY prisma ./prisma
# Instala pelo lock que o projeto tiver (npm, yarn ou pnpm); sem lock, npm install
RUN if [ -f package-lock.json ]; then npm ci --ignore-scripts; \
    elif [ -f yarn.lock ]; then corepack enable && yarn install --frozen-lockfile --ignore-scripts; \
    elif [ -f pnpm-lock.yaml ]; then corepack enable && pnpm install --frozen-lockfile --ignore-scripts; \
    else npm install --ignore-scripts; fi \
  && npx prisma generate

# Migrações: docker compose run --rm migrate
FROM deps AS migrate
ENV NODE_ENV=production
CMD ["npx", "prisma", "migrate", "deploy"]

FROM deps AS builder
ENV NEXT_TELEMETRY_DISABLED=1 NODE_ENV=production
# {{BUILD_ARGS_DOCKERFILE}}
COPY . .
# A pasta public é opcional no Next, mas o estágio final a copia
RUN mkdir -p public && npm run build

FROM base AS runner
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 PORT={{PORTA_APP}} HOSTNAME=0.0.0.0
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public
# {{COPIAR_PASTAS}}
# O compose escolhe o UID (dono das pastas montadas no host); o cache do Next precisa aceitar qualquer um
RUN mkdir -p {{PASTAS_VOLUME}} .next/cache && chmod -R a+rwX .next {{PASTAS_VOLUME}}
USER node
EXPOSE {{PORTA_APP}}
CMD ["node", "server.js"]
