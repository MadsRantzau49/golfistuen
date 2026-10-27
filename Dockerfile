FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.txt ./
RUN python -m pip install -r requirements.txt

COPY radar_app_python/ ./radar_app_python/
COPY configs/ ./configs/
RUN mkdir -p logs && chown -R 1000:1000 /app

USER 1000:1000
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/status', timeout=3).read()"]

CMD ["python", "-m", "uvicorn", "radar_app_python.api:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
