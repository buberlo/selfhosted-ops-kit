# syntax=docker/dockerfile:1
FROM python:3.13-slim AS base

ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

# Numeric UID so Kubernetes can verify runAsNonRoot without an /etc/passwd lookup.
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["python", "/app/app.py"]
CMD ["serve"]
