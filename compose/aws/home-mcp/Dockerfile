FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY *.py .

# Unprivileged: this container holds no secrets beyond its OAuth client id
# and only makes outbound HTTP calls (Prometheus, Authentik JWKS, app health).
USER nobody
EXPOSE 8000
CMD ["python", "server.py"]
