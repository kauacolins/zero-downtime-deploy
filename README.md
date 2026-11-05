# Deploy zero downtime com Docker e Nginx

Modelo de deploy blue-green para um servidor único, com Docker Compose, Nginx em contêiner e GitHub Actions em runner self-hosted. Foi feito para Next.js com Prisma, mas a ideia serve para outras stacks.

## Como funciona

```
Usuário → Nginx (contêiner, porta 80) → upstream app → blue_app:3000 ou green_app:3000
                                                              ↓
                                               banco (no servidor) e ./uploads
```

Só o Nginx expõe porta. As duas cores usam a porta 3000 dentro da rede Docker `web`, e o arquivo `nginx/upstream.conf` indica qual está ativa.

O `deploy.sh` faz o seguinte:

1. Lê a cor ativa e escolhe a outra. No primeiro deploy, usa `blue`.
2. Roda as migrações, com a versão atual ainda no ar.
3. Constrói e sobe a cor ociosa.
4. Espera o health check. Se falhar, derruba a versão nova e encerra com erro, sem tocar no tráfego.
5. Regrava o `upstream` e faz `nginx -s reload`, que não derruba conexões. Se falhar, restaura o arquivo anterior.
6. Espera 10 segundos e derruba a cor antiga.

## Arquivos

| Arquivo | Função |
| --- | --- |
| `Dockerfile` | Imagem do app (`runner`) e das migrações (`migrate`) |
| `docker-compose.blue.yml`, `docker-compose.green.yml` | Uma cor do app em cada arquivo |
| `docker-compose.nginx.yml` | Nginx, que não é reimplantado |
| `docker-compose.yaml` | Serviço de migrações |
| `nginx/default.conf` | Rota padrão: encaminha tudo para o `upstream app` |
| `nginx/upstream.conf` | Cor ativa; gerado pelo `deploy.sh`, fora do Git |
| `deploy.sh` | Faz a troca de versão |
| `.github/workflows/deploy.yml` | Roda o deploy a cada push na `main` |
| `examples/nextjs-prisma/` | Rota `/api/health` e consulta ao banco |

## Como usar em um projeto

1. Copie para a raiz do projeto tudo o que está aqui, menos `README.md`, `examples/` e `.gitignore`. Junte as regras desse `.gitignore` às do projeto.
2. Copie o conteúdo de `examples/nextjs-prisma/src/` para o `src/` do projeto e ajuste o import do Prisma em `health.ts`.
3. Em `next.config.ts`, use `output: "standalone"`.
4. Se o middleware exige login, deixe `/api/health` de fora. O health check segue redirecionamentos, então um redirecionamento para a tela de login faria uma versão com problema parecer saudável.
5. Se alguma página consulta o banco durante o build, use `export const dynamic = "force-dynamic"` nela ou no layout. O build não tem acesso ao banco nem ao `.env`.
6. Sem Prisma, remova o estágio `migrate` e o `COPY prisma` do `Dockerfile`, o `docker-compose.yaml` e a linha `docker compose run` do `deploy.sh`. Adapte o health check se a stack não for Node.
7. Se quiser outro caminho no servidor, altere `/var/www/app` em `.github/workflows/deploy.yml`.
8. Ajuste `client_max_body_size` em `nginx/default.conf` ao maior upload aceito pelo app.

## Como preparar o servidor

1. Instale o Docker e coloque o usuário do deploy no grupo `docker`.
2. Clone o repositório do projeto em `/var/www/app`.
3. Crie o `.env` a partir do `.env.example`.
4. Crie a pasta `uploads/` com o usuário do deploy. Se o Docker a criar, ela fica como root e os envios falham.
5. Se o banco roda no servidor, libere a rede Docker no `pg_hba.conf` e no firewall. Confira a faixa com `docker network inspect web`.
6. Libere a porta 80. Se houver um Nginx na máquina, desabilite-o sem apagar a configuração:

   ```bash
   sudo systemctl disable --now nginx
   ```

## Deploy

```bash
bash deploy.sh
```

Se o servidor já tiver um app no ar, reduza a queda da virada construindo antes de liberar a porta:

```bash
docker network create web
docker compose -f docker-compose.blue.yml up -d --build --wait
sudo systemctl disable --now nginx
bash deploy.sh
```

## CI

O workflow usa `runs-on: self-hosted` e roda a cada push na `main`.

1. No GitHub, abra **Settings → Actions → Runners → New self-hosted runner** e siga os comandos, com o usuário do deploy.
2. Dê a esse usuário acesso de leitura ao repositório, por exemplo com uma deploy key, para o `git pull`.
3. Instale o runner como serviço, na pasta dele:

   ```bash
   sudo ./svc.sh install USUARIO
   sudo ./svc.sh start
   ```

Instale o runner só depois do primeiro deploy manual, para um merge não disparar um deploy antes de o servidor estar pronto.

## Rollback

De `green` para `blue` (inverta as cores no caso contrário). A imagem anterior continua no servidor até o próximo deploy daquela cor:

```bash
docker compose -f docker-compose.blue.yml up -d --wait
echo "upstream app { server blue_app:3000; }" > nginx/upstream.conf
docker exec nginx nginx -t && docker exec nginx nginx -s reload
docker compose -f docker-compose.green.yml down
```

Para voltar ao Nginx da máquina:

```bash
docker compose -f docker-compose.nginx.yml down
sudo systemctl enable --now nginx
```

## Limites e cuidados

**O que ainda pode causar erro ou queda:**

- **Migração incompatível:** as duas versões usam o mesmo banco durante a troca, e o script não detecta incompatibilidade. Para remover ou renomear uma coluna, primeiro faça a versão nova parar de usá-la e só remova no deploy seguinte.
- **Pedidos longos:** um pedido que dure mais de 10 segundos na versão antiga pode ser cortado. Aumente o `sleep` no `deploy.sh`, se necessário.
- **Páginas abertas:** quem estiver com uma página da versão antiga pode ver um erro na próxima ação, até recarregar.
- **Memória:** o build roda no servidor, ao lado do app no ar. Em máquinas pequenas, construa a imagem em outro lugar.
- **Servidor único:** reiniciar o servidor, ou perder o Docker ou o banco, tira o app do ar. Os contêineres voltam sozinhos, mas o Nginx pode reiniciar algumas vezes até o app subir.

**Configuração e segurança:**

- **Uploads:** `./uploads` é compartilhada entre as cores para os arquivos sobreviverem à troca. Sessões em memória se perderiam; use JWT ou um armazenamento externo.
- **Grupo `docker`:** quem está nele pode virar root na prática. O mesmo vale para o runner e para quem altera um workflow que roda nele. Use só em repositório privado, proteja a `main` e limite o acesso de escrita.
- **Firewall:** portas publicadas pelo Docker podem passar por fora das regras do `ufw`.
- **HTTPS:** o Nginx escuta só na porta 80 e espera um proxy na frente, como o Cloudflare. Sem isso, configure os certificados nele.
