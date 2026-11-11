# Dockerfile próprio

Para qualquer tecnologia (PHP, Python, Java, Go...) cujo repositório já tem um `Dockerfile`. Nada é copiado: o `scaffold.sh` só gera os arquivos de deploy e pergunta o que depende do sistema.

| O que o deploy precisa | Opção |
| --- | --- |
| Porta em que a aplicação ouve dentro do contêiner | `--app-port` |
| Rota que responde `200` só com a aplicação pronta, sem login | `--health` |
| Comando de migração do banco, rodado na imagem nova antes da troca | `--migrate-cmd` (ex.: `php artisan migrate --force`, `alembic upgrade head`, `python manage.py migrate`) |
| Pastas onde a aplicação grava arquivos | `--volume` |

A imagem precisa de `wget`, `curl` ou `node`, usados pelo health check do compose. O `WORKDIR` precisa ser `/app`, porque as pastas montadas ficam em `/app/<pasta>`.
