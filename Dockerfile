FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN pip install --no-cache-dir \
    "mcp[cli]>=1.2.0" \
    httpx \
    yt-dlp \
    feedparser

COPY server.py /app/server.py

# Non-root user (UID 1000 matches host 'marcus' for bind-mount ownership).
RUN useradd --create-home --uid 1000 --shell /usr/sbin/nologin appuser \
    && chown -R appuser:appuser /app

ENV WHISPER_URL=http://host.docker.internal:8082/v1/audio/transcriptions
ENV INPUT_DIR=/data
ENV OUTPUT_DIR=/output
ENV PYTHONUNBUFFERED=1

USER appuser

ENTRYPOINT ["python", "/app/server.py"]
