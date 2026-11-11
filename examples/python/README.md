# Python

Para aplicações Python (Flask, Django, FastAPI). O `scaffold.sh` sugere esta stack quando o repositório tem `requirements.txt` ou `pyproject.toml`.

- **Comando de início** (`--start-cmd`): o script sugere pelo `requirements.txt` (Flask: `gunicorn -b 0.0.0.0:$PORT app:app`; FastAPI: `uvicorn main:app --host 0.0.0.0 --port $PORT`; Django: `gunicorn -b 0.0.0.0:$PORT <projeto>.wsgi`). Confira o módulo e o objeto da aplicação.
- **Migração** (`--migrate-cmd`): ex.: `python manage.py migrate --noinput`, `alembic upgrade head`, `flask db upgrade`.
- Crie a rota de saúde (padrão `/health`): `200` só com a aplicação pronta. O health check usa `python3`, que a imagem já tem.
