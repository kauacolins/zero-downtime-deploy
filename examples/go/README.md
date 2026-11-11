# Go

Para aplicações Go. O `scaffold.sh` sugere esta stack quando o repositório tem `go.mod`, lê a versão do Go dele e acha o pacote `main` (na raiz ou em `cmd/<nome>/`).

- A aplicação precisa ouvir na porta da variável `PORT` (padrão 8080) e em `0.0.0.0`.
- Crie a rota de saúde (padrão `/health`): `200` só com a aplicação pronta. A imagem final é Alpine, com `wget` para o health check.
- Migração: `--migrate-cmd` (ex.: um subcomando do próprio binário, `/app/app migrate`).
