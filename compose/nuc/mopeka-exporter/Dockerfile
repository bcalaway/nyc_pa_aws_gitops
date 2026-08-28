FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY mopeka_exporter.py .

EXPOSE 9102
CMD ["python", "mopeka_exporter.py"]
