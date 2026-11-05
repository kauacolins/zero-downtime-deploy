# Imagem de produção (Next.js standalone com Prisma).
FROM node:20-bookworm-slim AS base
RUN apt-get update -y && apt-get install -y --no-install-recommends openssl ca-certificates \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /app

# Todas as dependências: usadas no build e nas migrações (o Prisma CLI é dev dependency)
FROM base AS deps
COPY package.json package-lock.json ./
COPY prisma ./prisma
RUN npm ci --ignore-scripts && npx prisma generate

# Migrações: docker compose run --rm migrate
FROM deps AS migrate
ENV NODE_ENV=production
CMD ["npx", "prisma", "migrate", "deploy"]

FROM deps AS builder
ENV NEXT_TELEMETRY_DISABLED=1 NODE_ENV=production
COPY . .
# A pasta public é opcional no Next, mas o estágio final a copia
RUN mkdir -p public && npm run build

FROM base AS runner
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 PORT=3000 HOSTNAME=0.0.0.0
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public
# O compose escolhe o UID (dono de ./uploads no host); o cache do Next precisa aceitar qualquer um
RUN mkdir -p uploads .next/cache && chmod -R a+rwX .next uploads
USER node
EXPOSE 3000
CMD ["node", "server.js"]
