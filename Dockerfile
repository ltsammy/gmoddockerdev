# Dockerfile
FROM debian:stable-slim

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Europe/Berlin

# --- System deps (32-bit libs for srcds), tools, tini, SSH, gosu ---
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates curl tar xz-utils \
      lib32gcc-s1 lib32stdc++6 libtinfo5:i386 libncurses5:i386 \
      tini openssh-server gosu tzdata jq \
    && rm -rf /var/lib/apt/lists/*

# --- SteamCMD install ---
ENV STEAMCMD_DIR=/opt/steamcmd
RUN mkdir -p "$STEAMCMD_DIR" && \
    curl -fsSL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
      | tar -C "$STEAMCMD_DIR" -xz && \
    ln -s "$STEAMCMD_DIR/steamcmd.sh" /usr/local/bin/steamcmd

# --- Create users and dirs ---
# - 'steam' runs the gameserver (non-root)
# - 'dev' is for SSH (VS Code Remote-SSH)
ENV GMOD_DIR=/gmod \
    STEAM_HOME=/steam
RUN useradd -m -d /home/steam -s /bin/bash steam && \
    useradd -m -d /home/dev   -s /bin/bash dev && \
    mkdir -p "$GMOD_DIR" "$STEAM_HOME" /var/run/sshd && \
    chown -R steam:steam "$GMOD_DIR" "$STEAM_HOME"

# --- Defaults for server configuration (override in Coolify/compose) ---
ENV APP_ID=4020 \
    SRCDS_GAME="garrysmod" \
    SRCDS_MAP="gm_construct" \
    SRCDS_MAXPLAYERS=16 \
    SRCDS_TICKRATE=66 \
    SRCDS_PORT=27015 \
    SRCDS_TV_PORT=27020 \
    SRCDS_CLIENT_PORT=27005 \
    SRCDS_FPSMAX=300 \
    SRCDS_WORKSHOP_COLLECTION="" \
    SRCDS_AUTHKEY="" \
    SRCDS_HOSTNAME="GMod Dev Server (Docker)" \
    SRCDS_RCON_PASSWORD="changeme" \
    SRCDS_ADDITIONAL_ARGS="" \
    GSLT="" \
    STEAM_AUTO_UPDATE=1

# --- SSH configuration via env (provide your public key in Coolify) ---
ENV SSH_USERNAME="dev" \
    SSH_PUBLIC_KEY="" \
    SSH_ENABLE_PASSWORD="false" \
    SSH_PASSWORD=""

# --- Copy entrypoint ---
COPY entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint

# --- Expose ports ---
# Game/Query: 27015 UDP (game) + 27015 TCP (RCON/query), Client: 27005 UDP, TV: 27020 UDP
# SSH: 22 TCP
EXPOSE 27015/udp 27015/tcp 27005/udp 27020/udp 22/tcp

# --- Volumes for persistence ---
VOLUME ["/gmod", "/steam"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
  CMD pgrep -f "/gmod/srcds_linux" >/dev/null || exit 1

# Use tini as PID1; keep SSH and SRCDS under one entrypoint
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/entrypoint"]
