# Cabeçalhos de cada destino (monorepo: um location por aplicação).
# Gerado pelo zero-downtime-deploy (modelos/nginx/proxy-headers.inc).

# Maior envio aceito (uploads): um pouco acima do limite da aplicação
client_max_body_size {{LIMITE_UPLOAD}};

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
