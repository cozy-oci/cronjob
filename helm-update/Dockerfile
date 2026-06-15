FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        openssh-client \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir requests pyyaml

WORKDIR /app
COPY helm_update.py /app/helm_update.py
RUN chmod 755 /app/helm_update.py

ENTRYPOINT ["python", "/app/helm_update.py"]
