# Front-end com build estático (Vite, Create React App, Vue CLI, Angular): compila e serve com Nginx.
FROM node:20-bookworm-slim AS builder
WORKDIR /app
COPY package.json package-lock.json* yarn.lock* pnpm-lock.yaml* ./
# Instala pelo lock que o projeto tiver (npm, yarn ou pnpm); sem lock, npm install
RUN if [ -f package-lock.json ]; then npm ci; \
    elif [ -f yarn.lock ]; then corepack enable && yarn install --frozen-lockfile; \
    elif [ -f pnpm-lock.yaml ]; then corepack enable && pnpm install --frozen-lockfile; \
    else npm install; fi
# VITE_*, REACT_APP_*, VUE_APP_* são gravadas no build: o compose as passa a partir do .env
# {{BUILD_ARGS_DOCKERFILE}}
COPY . .
# Lint é papel do CI: no Create React App, o ESLint embutido derruba o build por configuração
ENV DISABLE_ESLINT_PLUGIN=true
RUN npm run build

# Nginx sem root: roda com qualquer UID (o compose escolhe) e ouve na 8080
FROM nginxinc/nginx-unprivileged:1.27-alpine AS runner
COPY nginx-spa.conf /etc/nginx/conf.d/default.conf
# Saída do build (o scaffold.sh lê: dist no Vite e no Vue CLI, build no CRA, a do angular.json)
COPY --from=builder /app/{{SAIDA_BUILD}} /usr/share/nginx/html
EXPOSE {{PORTA_APP}}
