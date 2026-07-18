FROM postgres:16

RUN apt-get update \
    && apt-get install -y --no-install-recommends awscli cron \
    && rm -rf /var/lib/apt/lists/* \
    && touch /var/log/cron.log

COPY backup.sh /usr/local/bin/backup.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY crontab /etc/cron.d/postgres-backup

RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/entrypoint.sh \
    && chmod 0644 /etc/cron.d/postgres-backup \
    && crontab /etc/cron.d/postgres-backup

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
