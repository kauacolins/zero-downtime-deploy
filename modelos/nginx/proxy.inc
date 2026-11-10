# Comum aos dois ambientes. Gerado pelo zero-downtime-deploy (modelos/nginx/proxy.inc).

# Maior envio aceito (uploads). Ajuste ao limite da aplicação.
client_max_body_size 25m;

location / {
    proxy_pass http://$app_upstream;

    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection 'upgrade';

    # Com a porta: logins e formulários que comparam o Host com a origem do navegador
    # quebrariam na porta de homologação com $host
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $forwarded_proto;

    proxy_cache_bypass $http_upgrade;
}
