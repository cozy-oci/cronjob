FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/usr/local/bin:/usr/bin:/bin"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        openssh-client \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /home/appuser/.ssh \
    && printf 'appuser:x:10001:10001::/home/appuser:/usr/sbin/nologin\n' >> /etc/passwd \
    && printf 'appuser:x:10001:\n' >> /etc/group \
    && mkdir -p /home/appuser/.ssh \
    && chown -R appuser:appuser /home/appuser/.ssh \
    && chmod 700 /home/appuser/.ssh

WORKDIR /app
COPY --chown=appuser:appuser park_reserve.py /app/park_reserve.py
RUN chmod 755 /app/park_reserve.py

USER appuser

ENTRYPOINT ["/app/park_reserve.py"]
