# Front-end estático (Vite)

Para front-ends com Vite (React, Vue, Svelte) que geram arquivos estáticos e conversam com uma API. O `scaffold.sh` sugere esta stack quando o `package.json` tem `vite`.

| Arquivo | Função |
| --- | --- |
| `Dockerfile` | `npm run build` e Nginx sem root servindo a pasta `dist` |
| `nginx-spa.conf` | Rotas do navegador caem no `index.html`; `assets/` com cache longo |
| `.dockerignore` | Tira da imagem segredos, dependências e arquivos de deploy |

- A rota de saúde é a própria página inicial (`/`).
- Variáveis `VITE_*` são gravadas no build. O `scaffold.sh` as acha no código e as passa como argumento de build, com o valor do `.env` de cada pasta.
- Sem banco, sem migração e sem pastas montadas.
- Com outra pasta de saída (ex.: `build` no Create React App), ajuste o `COPY --from=builder` do `Dockerfile`.
