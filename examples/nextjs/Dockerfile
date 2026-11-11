# Imagem de produção (Next.js standalone, sem Prisma). Ajuste à vontade.
FROM node:20-bookworm-slim AS base
WORKDIR /app

FROM base AS deps
COPY package.json package-lock.json* yarn.lock* pnpm-lock.yaml* ./
# Instala pelo lock que o projeto tiver (npm, yarn ou pnpm); sem lock, npm install
RUN if [ -f package-lock.json ]; then npm ci; \
    elif [ -f yarn.lock ]; then corepack enable && yarn install --frozen-lockfile; \
    elif [ -f pnpm-lock.yaml ]; then corepack enable && pnpm install --frozen-lockfile; \
    else npm install; fi

FROM base AS builder
ENV NEXT_TELEMETRY_DISABLED=1 NODE_ENV=production
# {{BUILD_ARGS_DOCKERFILE}}
COPY --from=deps /app/node_modules ./node_modules
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
