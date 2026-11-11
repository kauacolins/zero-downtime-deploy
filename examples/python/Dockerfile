# Imagem de produção de uma aplicação Python. Ajuste à vontade.
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PORT={{PORTA_APP}}
WORKDIR /app
COPY . .
# requirements.txt, ou o pyproject.toml; gunicorn serve Flask e Django em produção
RUN if [ -f requirements.txt ]; then pip install --no-cache-dir -r requirements.txt; else pip install --no-cache-dir .; fi \
  && pip install --no-cache-dir gunicorn
# {{CRIAR_PASTAS_DOCKERFILE}}
EXPOSE {{PORTA_APP}}
# Comando que sobe a aplicação (--start-cmd), ouvindo na porta da variável PORT
CMD ["sh", "-c", "{{START_CMD}}"]
