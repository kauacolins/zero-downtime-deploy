# Imagem de produção de um servidor Node.js (Express, NestJS, Fastify...). Ajuste à vontade.
FROM node:20-bookworm-slim AS deps
WORKDIR /app
COPY package.json package-lock.json* yarn.lock* pnpm-lock.yaml* ./
# Instala pelo lock que o projeto tiver (npm, yarn ou pnpm); sem lock, npm install
RUN if [ -f package-lock.json ]; then npm ci; \
    elif [ -f yarn.lock ]; then corepack enable && yarn install --frozen-lockfile; \
    elif [ -f pnpm-lock.yaml ]; then corepack enable && pnpm install --frozen-lockfile; \
    else npm install; fi

FROM deps AS builder
# {{BUILD_ARGS_DOCKERFILE}}
COPY . .
# Compila se o package.json tiver o script "build" (TypeScript, NestJS); depois tira as devDependencies
RUN npm run build --if-present && npm prune --omit=dev

FROM node:20-bookworm-slim AS runner
ENV NODE_ENV=production PORT={{PORTA_APP}}
WORKDIR /app
COPY --from=builder /app ./
# {{CRIAR_PASTAS_DOCKERFILE}}
USER node
EXPOSE {{PORTA_APP}}
# O script "start" do package.json precisa ouvir na porta da variável PORT
CMD ["npm", "start"]
