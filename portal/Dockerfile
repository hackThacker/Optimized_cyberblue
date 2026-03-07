FROM python:3.9-slim

# ── Working directory ─────────────────────────────────────────────
WORKDIR /app

# ── System dependencies + Docker CLI ─────────────────────────────
# FIX 1: hardcoded "bullseye" — lsb_release inside container is unreliable
# FIX 2: --no-install-recommends — smaller image, no junk packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    yara \
    git \
 && curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
    https://download.docker.com/linux/debian bullseye stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli \
 && rm -rf /var/lib/apt/lists/*

# ── Git safe directories ──────────────────────────────────────────
# FIX 3: --system instead of --global
#         --global only works for root, lost after USER switch
#         --system persists for ALL users including cyberblue
RUN git config --system --add safe.directory /opt/yara-rules \
 && git config --system --add safe.directory /opt/sigma-rules \
 && git config --system --add safe.directory /app

# ── Copy requirements first — better layer caching ────────────────
COPY requirements.txt .

# ── Python dependencies ───────────────────────────────────────────
# FIX 4: combined into one RUN layer — faster build, smaller image
RUN pip install --no-cache-dir -r requirements.txt \
 && pip install --no-cache-dir \
    sigma-cli \
    pysigma-backend-elasticsearch \
    pysigma-backend-opensearch

# ── Non-root user ─────────────────────────────────────────────────
# FIX 5: run as cyberblue not root — security best practice
RUN groupadd --gid 1000 cyberblue \
 && useradd --uid 1000 --gid 1000 --no-create-home \
    --shell /bin/bash cyberblue

# ── Copy application code ─────────────────────────────────────────
# FIX 6: --chown so cyberblue owns all app files from the start
COPY --chown=cyberblue:cyberblue . .

# ── FIX 7: Create portal.log + set ALL /app permissions BEFORE USER switch ──
# ROOT CAUSE OF CRASH:
#   app.py line 26: logging.FileHandler('portal.log')
#   Flask opens /app/portal.log for writing on every startup
#   If portal.log owned by root → PermissionError → crash loop → unhealthy
#
# WHY IT WAS BROKEN:
#   Old Dockerfile only did: chown /app/logs
#   portal.log lives in /app directly — NOT in /app/logs
#   File was created by root during COPY → owned by root
#   After USER cyberblue → Flask cannot write → crash on line 26 every time
#
# THE FIX:
#   1. touch portal.log explicitly while still running as root
#   2. chown ALL of /app recursively → cyberblue owns everything
#   3. chmod 775 → cyberblue can read+write all files
#   MUST happen BEFORE USER switch — after that we have no root access
RUN mkdir -p /app/logs \
 && touch /app/portal.log \
 && chown -R cyberblue:cyberblue /app \
 && chmod -R 775 /app

# ── Switch to non-root user ───────────────────────────────────────
USER cyberblue

# ── Port ──────────────────────────────────────────────────────────
EXPOSE 5500

# ── Environment variables ─────────────────────────────────────────
# PYTHONUNBUFFERED=1        → logs appear immediately in docker logs
# PYTHONDONTWRITEBYTECODE=1 → no .pyc files cluttering the image
ENV PORT=5500
ENV FLASK_ENV=production
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# ── Health check ──────────────────────────────────────────────────
# FIX 8: start-period 5s → 15s
#         Flask needs time to fully start before first health check
#         5s caused immediate "unhealthy" even when app was fine
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:5500/health || exit 1

# ── Start application ─────────────────────────────────────────────
CMD ["python3", "app.py"]
