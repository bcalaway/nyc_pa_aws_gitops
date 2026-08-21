FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY weather_exporter.py .

EXPOSE 9101
CMD ["python", "weather_exporter.py"]
