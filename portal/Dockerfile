FROM python:3.9-slim

# ── Working directory ─────────────────────────────────────────────
# ORIGINAL: same — kept exactly
WORKDIR /app

# ── System dependencies + Docker CLI ─────────────────────────────
# ORIGINAL GOAL: install curl, yara, git, docker-ce-cli — kept exactly
#
# FIX 1: $(lsb_release -cs) inside container returns wrong/unreliable value
#         python:3.9-slim is Debian Bullseye — hardcode "bullseye"
#         Original would break if base image ever changes minor versions
#
# FIX 2: added --no-install-recommends
#         installs only required packages, not suggested extras
#         makes image smaller without removing any needed functionality
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
# ORIGINAL GOAL: trust /opt/yara-rules and /opt/sigma-rules — kept
#
# FIX 3: --global → --system
#         --global writes to ~/.gitconfig (only works for root user)
#         --system writes to /etc/gitconfig (works for ALL users)
#         When we switch to non-root user later, --global config is lost
#         --system config stays active for every user including cyberblue
RUN git config --system --add safe.directory /opt/yara-rules \
 && git config --system --add safe.directory /opt/sigma-rules \
 && git config --system --add safe.directory /app

# ── Copy requirements first — layer caching ───────────────────────
# ORIGINAL GOAL: copy requirements.txt first — kept exactly
# This layer only rebuilds when requirements.txt actually changes
COPY requirements.txt .

# ── Python dependencies ───────────────────────────────────────────
# ORIGINAL GOAL: install requirements + sigma-cli + backends — kept
#
# FIX 4: two separate RUN pip commands → one combined RUN
#         original had:
#           RUN pip install -r requirements.txt
#           RUN pip install sigma-cli pysigma-backend-...
#         two layers = Docker has to cache/rebuild both separately
#         one layer = faster rebuild, smaller image, single cache entry
RUN pip install --no-cache-dir -r requirements.txt \
 && pip install --no-cache-dir \
    sigma-cli \
    pysigma-backend-elasticsearch \
    pysigma-backend-opensearch

# ── Non-root user ─────────────────────────────────────────────────
# ORIGINAL HAD: nothing — ran as root
#
# FIX 5: create dedicated user cyberblue (uid 1000)
#         running containers as root is a security risk
#         if the container is compromised, attacker gets root on host
#         non-root user limits the blast radius
RUN groupadd --gid 1000 cyberblue \
 && useradd --uid 1000 --gid 1000 --no-create-home \
    --shell /bin/bash cyberblue

# ── Copy application code ─────────────────────────────────────────
# ORIGINAL GOAL: copy app code — kept
#
# FIX 6: added --chown=cyberblue:cyberblue
#         without this, all copied files are owned by root
#         when we switch to USER cyberblue, app cannot read its own files
#         use .dockerignore to exclude caldera/, wazuh/, rules/ etc
#         (see .dockerignore — prevents 10GB+ image)
COPY --chown=cyberblue:cyberblue . .

# ── Create logs directory ─────────────────────────────────────────
# ORIGINAL GOAL: mkdir /app/logs — kept
# FIX: set ownership so cyberblue user can write logs
RUN mkdir -p /app/logs \
 && chown -R cyberblue:cyberblue /app/logs

# ── Switch to non-root user ───────────────────────────────────────
USER cyberblue

# ── Port ──────────────────────────────────────────────────────────
# ORIGINAL: same — kept exactly
EXPOSE 5500

# ── Environment variables ─────────────────────────────────────────
# ORIGINAL GOAL: PORT + FLASK_ENV — kept
# ADDED: PYTHONUNBUFFERED=1 so print() and log lines show immediately
#         in docker logs without buffering delay
#        PYTHONDONTWRITEBYTECODE=1 stops .pyc files cluttering the image
ENV PORT=5500
ENV FLASK_ENV=production
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# ── Health check ──────────────────────────────────────────────────
# ORIGINAL GOAL: health check on /health every 30s — kept
# FIX: start-period 5s → 15s
#      Flask needs time to start up before Docker checks health
#      5s was too short — Docker marked container unhealthy immediately
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:5500/health || exit 1

# ── Start application ─────────────────────────────────────────────
# ORIGINAL GOAL: run python3 app.py — kept exactly
CMD ["python3", "app.py"]
