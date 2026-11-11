# Front-end com build estático

Para front-ends que geram arquivos estáticos e conversam com uma API: Vite (React, Vue, Svelte), Create React App, Vue CLI e Angular. O `scaffold.sh` sugere esta stack pelo `package.json` e lê a pasta de saída do build (`dist`, `build` ou a do `angular.json`).

| Arquivo | Função |
| --- | --- |
| `Dockerfile` | `npm run build` e Nginx sem root servindo a pasta `dist` |
| `nginx-spa.conf` | Rotas do navegador caem no `index.html`; `assets/` com cache longo |
| `.dockerignore` | Tira da imagem segredos, dependências e arquivos de deploy |

- A rota de saúde é a própria página inicial (`/`).
- Variáveis `VITE_*`, `REACT_APP_*` e `VUE_APP_*` são gravadas no build. O `scaffold.sh` as acha no código e as passa como argumento de build, com o valor do `.env` de cada pasta. No Angular, os valores ficam nos `environment*.ts`.
- Sem banco, sem migração e sem pastas montadas.
