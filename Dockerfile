# syntax=docker/dockerfile:1.7
# =============================================================================
# devops-cicd-app - production multi-stage image
# =============================================================================
# Stage 1 (builder) : compiles/installs Python dependencies into a virtualenv
# Stage 2 (runtime) : copies ONLY the virtualenv + source -> no compilers,
#                      no pip, no build caches, runs as a non-root user.
# =============================================================================

ARG PYTHON_VERSION=3.12
ARG BASE_IMAGE=python:${PYTHON_VERSION}-slim

# -----------------------------------------------------------------------------
# STAGE 1 - BUILDER
# -----------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    VIRTUAL_ENV=/opt/venv

WORKDIR /build

# Isolated virtualenv so the runtime image can copy a self-contained /opt/venv
RUN python -m venv ${VIRTUAL_ENV}
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

# Dependencies are copied and installed BEFORE the source code so that the
# Docker layer cache is only invalidated when requirements.txt changes.
COPY requirements.txt ./
RUN pip install --no-cache-dir --upgrade pip setuptools wheel \
    && pip install --no-cache-dir -r requirements.txt \
    && python -m compileall -q ${VIRTUAL_ENV}/lib/python*/site-packages

# -----------------------------------------------------------------------------
# STAGE 2 - RUNTIME
# -----------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS runtime

ARG APP_VERSION=1.0.0
ARG BUILD_DATE=unknown
ARG VCS_REF=unknown

LABEL org.opencontainers.image.title="devops-cicd-app" \
      org.opencontainers.image.description="Containerised Flask app with a full CI/CD pipeline" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="https://github.com/<your-username>/devops-cicd-project" \
      org.opencontainers.image.licenses="MIT"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PATH="/opt/venv/bin:${PATH}" \
    APP_NAME=devops-cicd-app \
    APP_VERSION=${APP_VERSION} \
    APP_ENV=production \
    APP_PORT=8000 \
    GUNICORN_WORKERS=3 \
    GUNICORN_THREADS=2 \
    GUNICORN_TIMEOUT=30 \
    LOG_LEVEL=INFO \
    LOG_FORMAT=json

# curl is NOT installed: the healthcheck uses the Python standard library,
# which keeps the image smaller and removes one more package to patch.
RUN set -eux; \
    groupadd --gid 10001 appgroup; \
    useradd --uid 10001 --gid 10001 --create-home --shell /usr/sbin/nologin appuser; \
    mkdir -p /app /tmp; \
    chown -R appuser:appgroup /app /tmp

WORKDIR /app

# Copy the virtualenv built in stage 1 (no pip, no build-essential here).
COPY --from=builder /opt/venv /opt/venv

# Application source (owned by root, read-only for the runtime user).
COPY --chown=root:root app/ ./app/
COPY --chown=root:root wsgi.py ./wsgi.py

USER appuser

EXPOSE 8000

# Container-level health check -> used by `docker compose ps` and by any
# orchestrator. It hits the SAME /health endpoint the CI pipeline validates.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["python", "-c", "import sys,urllib.request;\
r=urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=4);\
sys.exit(0 if r.status==200 else 1)"]

CMD ["gunicorn", \
     "--bind", "0.0.0.0:8000", \
     "--workers", "3", \
     "--threads", "2", \
     "--timeout", "30", \
     "--graceful-timeout", "20", \
     "--keep-alive", "5", \
     "--max-requests", "1000", \
     "--max-requests-jitter", "50", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "--capture-output", \
     "--preload", \
     "wsgi:app"]
