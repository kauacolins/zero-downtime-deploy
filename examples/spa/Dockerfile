# Front-end estático (Vite): compila e serve os arquivos com Nginx. Ajuste à vontade.
FROM node:20-bookworm-slim AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
# VITE_* são gravadas no build: o compose as passa a partir do .env de cada pasta
# {{BUILD_ARGS_DOCKERFILE}}
COPY . .
RUN npm run build

# Nginx sem root: roda com qualquer UID (o compose escolhe) e ouve na 8080
FROM nginxinc/nginx-unprivileged:1.27-alpine AS runner
COPY nginx-spa.conf /etc/nginx/conf.d/default.conf
# Saída do vite build; com outra pasta (ex.: build), ajuste aqui
COPY --from=builder /app/dist /usr/share/nginx/html
EXPOSE {{PORTA_APP}}
