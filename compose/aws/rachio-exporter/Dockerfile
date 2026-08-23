FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY rachio_exporter.py .

EXPOSE 9200
CMD ["python", "rachio_exporter.py"]
