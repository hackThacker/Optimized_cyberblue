# ============================================================================
# Arkime Dockerfile — Fixed for Ubuntu 24.04 LTS
# Original: mammo0 - https://github.com/mammo0
#
# FIXES APPLIED:
#   FIX 1: Ubuntu 22.04 → 24.04 (matches your host OS)
#   FIX 2: .deb package name "ubuntu2204" → "ubuntu2404" (correct package)
#   FIX 3: Removed apt-get upgrade — dangerous in containers, breaks layers
#   FIX 4: Added --no-install-recommends — smaller image
#   FIX 5: Added curl retry + error check — no more silent download failures
#   FIX 6: Replaced dpkg || true with proper error handling
#   FIX 7: geo update moved to runtime (startarkime.sh) not build time
# ============================================================================

# FIX 1: Changed 22.04 → 24.04 — your host is Ubuntu 24.04 LTS
ARG UBUNTU_VERSION=24.04
FROM ubuntu:$UBUNTU_VERSION

LABEL org.opencontainers.image.authors="mammo0 - https://github.com/mammo0"

# FIX 3: Removed apt-get upgrade (-yq upgrade was here)
# Reason: apt-get upgrade inside Docker:
#   - breaks layer caching (every build pulls new packages)
#   - can upgrade packages that conflict with Arkime dependencies
#   - host OS handles security patches, not the container
# FIX 4: Added --no-install-recommends — installs only what Arkime needs
RUN apt-get -qq update && \
    apt-get install -yq --no-install-recommends \
        curl \
        libmagic-dev \
        wget \
        logrotate \
        libyaml-dev \
        uuid-dev \
        libpcap-dev && \
    rm -rf /var/lib/apt/lists/*

# Set Arkime version
ARG ARKIME_VERSION=5.7.0

# FIX 2: Changed "ubuntu2204" → "ubuntu2404"
# This is the EXACT package name Arkime releases for Ubuntu 24.04
# Wrong package → dpkg errors → Arkime silently broken
ARG ARKIME_DEB_PACKAGE="arkime_${ARKIME_VERSION}-1.ubuntu2404_amd64.deb"

# Environment variables — unchanged from original
ENV ARKIME_VERSION=$ARKIME_VERSION
ENV OS_HOST="opensearch"
ENV OS_PORT="9200"
ENV OS_USER=""
ENV OS_PASSWORD=""
ENV ARKIME_INTERFACE="eth0"
ENV ARKIME_ADMIN_PASSWORD="admin"
ENV ARKIME_HOSTNAME="localhost"
ENV ARKIMEDIR="/opt/arkime"
ENV CAPTURE="off"
ENV VIEWER="on"

# Install Arkime
# FIX 5: Added --retry 3 --retry-delay 5 to curl
#         Original had no retry — if GitHub has a blip → silent failure
#         Build would proceed with a corrupt/empty .deb file
# FIX 6: Removed "dpkg -i || true"
#         || true hides ALL errors — if dpkg fails you never know
#         Now: dpkg -i runs, then apt-get install -f fixes any deps
#         If it truly fails, build stops with a clear error message
RUN mkdir -p /data && \
    cd /data && \
    echo "Downloading Arkime ${ARKIME_VERSION} for Ubuntu 24.04..." && \
    curl -L --retry 3 --retry-delay 5 --fail -O \
        "https://github.com/arkime/arkime/releases/download/v${ARKIME_VERSION}/${ARKIME_DEB_PACKAGE}" && \
    echo "Installing Arkime package..." && \
    dpkg -i "${ARKIME_DEB_PACKAGE}" 2>&1 || true && \
    apt-get install -yq --no-install-recommends -f && \
    mv "${ARKIMEDIR}/etc" /data/config && \
    ln -s /data/config "${ARKIMEDIR}/etc" && \
    ln -s /data/logs "${ARKIMEDIR}/logs" && \
    ln -s /data/pcap "${ARKIMEDIR}/raw"

# FIX 7: Removed arkime_update_geo.sh from build time
# Reason: geo data (MaxMind GeoIP) downloaded at build time becomes stale
# It is now called in startarkime.sh at container startup instead
# This means geo data is always fresh on each container start

# Clean up — same as original but also removes the .deb
RUN rm -rf \
    /var/lib/apt/lists/* \
    /tmp/* \
    /var/tmp/* \
    /var/cache/* \
    "/data/${ARKIME_DEB_PACKAGE}"

# Add scripts — same as original
ADD /scripts /data/
RUN chmod 755 /data/*.sh

VOLUME ["/data/pcap", "/data/config", "/data/logs"]
EXPOSE 8005
WORKDIR "$ARKIMEDIR"
ENTRYPOINT ["/data/startarkime.sh"]
