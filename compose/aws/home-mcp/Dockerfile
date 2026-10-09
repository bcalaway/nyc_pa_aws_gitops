# Base images from public.ecr.aws/docker/library, AWS's mirror of Docker's official images: no Docker Hub
# rate limits or outages (Bill, 2026-10-09; nyc_pa_aws_gitops docs/gotchas.md).
FROM public.ecr.aws/docker/library/python:3.12-slim

# ssh client: reaches the voice worker's forced command on nuc4 (tasks.py).
RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-client \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY *.py .

# Unprivileged. Secrets it holds: its OAuth client id, the voiceworker SSH
# key (usable only for nuc4's forced command, from this hub's IP), and the
# Gmail SMTP password for task-start emails.
USER nobody
EXPOSE 8000
CMD ["python", "server.py"]
