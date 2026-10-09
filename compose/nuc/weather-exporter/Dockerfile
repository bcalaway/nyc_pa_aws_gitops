# Base images from public.ecr.aws/docker/library, AWS's mirror of Docker's official images: no Docker Hub
# rate limits or outages (Bill, 2026-10-09; nyc_pa_aws_gitops docs/gotchas.md).
FROM public.ecr.aws/docker/library/python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY weather_exporter.py .

EXPOSE 9101
CMD ["python", "weather_exporter.py"]
