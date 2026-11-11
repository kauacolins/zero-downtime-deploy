# PHP

Para aplicações PHP, Laravel ou PHP puro, com Apache. O `scaffold.sh` sugere esta stack com `composer.json` ou `index.php` (na raiz ou em `public/`).

- Com `public/index.php` (Laravel), a raiz do site é `public/`; senão, a própria pasta.
- O Apache ouve na porta 8080 e roda sem root, com o UID escolhido pelo compose. `storage/` e `bootstrap/cache` ficam graváveis.
- Laravel: migração com `--migrate-cmd "php artisan migrate --force"`. Monte `storage/app` com `--volume` se o sistema guardar arquivos enviados.
- A rota de saúde padrão é `/`. No Laravel 11, use `--health /up`. O health check usa `php`, que a imagem já tem.
