FROM public.ecr.aws/docker/library/python:3.12-slim

WORKDIR /app

# Apply latest Debian security patches before installing packages.
# This addresses base-image CVEs that ship with python:3.12-slim
# (e.g. CVE-2026-33845 in gnutls28). The slim image is rebuilt on a
# delay, so apt-get upgrade closes the gap at build time.
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    curl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/

RUN useradd --create-home --shell /bin/bash appuser && \
    chown -R appuser:appuser /app
USER appuser

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl --fail http://localhost:8000/health || exit 1

CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2"]