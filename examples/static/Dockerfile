# Site estático, sem build: Nginx sem root servindo os arquivos da pasta. Ajuste à vontade.
FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY nginx-static.conf /etc/nginx/conf.d/default.conf
COPY . /usr/share/nginx/html
EXPOSE {{PORTA_APP}}
