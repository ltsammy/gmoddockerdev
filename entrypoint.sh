# entrypoint.sh
#!/usr/bin/env bash
set -euo pipefail

# Colors
info(){ echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
err (){ echo -e "\033[1;31m[ERR ]\033[0m $*"; }

# Ensure sshd runtime dir exists
mkdir -p /var/run/sshd

# ----- Setup SSH user/key -----
SSH_USER="${SSH_USERNAME:-dev}"
if ! id "$SSH_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$SSH_USER"
fi

# Optional password (for emergencies; default disabled)
if [[ "${SSH_ENABLE_PASSWORD,,}" == "true" ]]; then
  if [[ -n "${SSH_PASSWORD:-}" ]]; then
    echo "${SSH_USER}:${SSH_PASSWORD}" | chpasswd
    info "SSH password login ENABLED for ${SSH_USER}"
    sed -ri 's/^#?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true
  else
    warn "SSH_ENABLE_PASSWORD=true but SSH_PASSWORD is empty"
  fi
else
  sed -ri 's/^#?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config || true
fi

# Public key auth
if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
  su - "$SSH_USER" -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'
  su - "$SSH_USER" -c "echo '${SSH_PUBLIC_KEY}' >> ~/.ssh/authorized_keys"
  su - "$SSH_USER" -c 'chmod 600 ~/.ssh/authorized_keys'
  info "Installed SSH public key for ${SSH_USER}"
else
  warn "No SSH_PUBLIC_KEY provided; SSH will still run but key auth is missing."
fi

# Harden SSH a bit, keep it friendly for VS Code Remote-SSH
sed -ri 's/^#?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config || true
sed -ri 's/^#?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config || true
sed -ri 's/^#?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config || true
sed -ri 's/^#?UsePAM .*/UsePAM yes/' /etc/ssh/sshd_config || true
# Ensure sftp works
grep -q "^Subsystem sftp" /etc/ssh/sshd_config || echo "Subsystem sftp /usr/lib/openssh/sftp-server" >> /etc/ssh/sshd_config

# Start SSH in background
/usr/sbin/sshd
info "SSHD started on port 22"

# ----- Prepare SRCDS -----
GMOD_DIR="${GMOD_DIR:-/gmod}"
STEAM_HOME="${STEAM_HOME:-/steam}"
STEAMCMD_DIR="${STEAMCMD_DIR:-/opt/steamcmd}"
APP_ID="${APP_ID:-4020}"

# Ownership for steam user
chown -R steam:steam "$GMOD_DIR" "$STEAM_HOME"

# Install/Update server
if [[ ! -f "$GMOD_DIR/srcds_run" ]] || [[ "${STEAM_AUTO_UPDATE:-1}" == "1" ]]; then
  info "Running SteamCMD to install/update app ${APP_ID} into ${GMOD_DIR}"
  su - steam -c "\"$STEAMCMD_DIR/steamcmd.sh\" +force_install_dir \"$GMOD_DIR\" +login anonymous +app_update ${APP_ID} validate +quit"
else
  info "Skipping auto-update (STEAM_AUTO_UPDATE=${STEAM_AUTO_UPDATE})"
fi

# ----- Server CFG from env (only bootstrap if missing) -----
CFG_DIR="${GMOD_DIR}/garrysmod/cfg"
mkdir -p "$CFG_DIR"
SERVER_CFG="${CFG_DIR}/server.cfg"
if [[ ! -s "$SERVER_CFG" ]]; then
  info "Generating initial server.cfg"
  cat > "$SERVER_CFG" <<EOF
hostname "${SRCDS_HOSTNAME:-GMod Dev Server (Docker)}"
rcon_password "${SRCDS_RCON_PASSWORD:-changeme}"
sv_password ""
sv_lan 0
sv_setsteamaccount "${GSLT:-}"
sv_loadingurl ""
sv_region 3
sv_allowcslua 1
sv_downloadurl ""
sv_minrate 75000
sv_maxrate 0
sv_maxupdaterate ${SRCDS_TICKRATE:-66}
sv_minupdaterate 20
sv_parallel_sendsnapshot 1
sv_parallel_packentities 1
EOF
fi

# Workshop (command-line flags still preferred)
if [[ -n "${SRCDS_AUTHKEY:-}" ]]; then
  echo "host_workshop_collection ${SRCDS_WORKSHOP_COLLECTION:-}" > "${CFG_DIR}/autoexec.cfg"
  echo "sv_setsteamaccount ${GSLT:-}" >> "${CFG_DIR}/autoexec.cfg"
fi

# ----- Build command line -----
PORT="${SRCDS_PORT:-27015}"
TV_PORT="${SRCDS_TV_PORT:-27020}"
CLIENT_PORT="${SRCDS_CLIENT_PORT:-27005}"
MAXPLAYERS="${SRCDS_MAXPLAYERS:-16}"
TICKRATE="${SRCDS_TICKRATE:-66}"
MAP="${SRCDS_MAP:-gm_construct}"
GAME="${SRCDS_GAME:-garrysmod}"
FPSMAX="${SRCDS_FPSMAX:-300}"
ADDL="${SRCDS_ADDITIONAL_ARGS:-}"

# Workshop flags
WS_FLAGS=()
if [[ -n "${SRCDS_AUTHKEY:-}" ]]; then
  WS_FLAGS+=(+sv_setsteamaccount "${GSLT:-}")
  WS_FLAGS+=(-authkey "${SRCDS_AUTHKEY}")
fi
if [[ -n "${SRCDS_WORKSHOP_COLLECTION:-}" ]]; then
  WS_FLAGS+=(-collection "${SRCDS_WORKSHOP_COLLECTION}")
fi

CMD_LINE=( \
  "${GMOD_DIR}/srcds_run" \
  -game "${GAME}" \
  -console \
  -port "${PORT}" \
  +clientport "${CLIENT_PORT}" \
  +tv_port "${TV_PORT}" \
  -tickrate "${TICKRATE}" \
  +map "${MAP}" \
  +maxplayers "${MAXPLAYERS}" \
  -fps_max "${FPSMAX}" \
  ${ADDL} \
  "${WS_FLAGS[@]}" \
)

info "Launching SRCDS: ${CMD_LINE[*]}"
# Drop to steam user for the game server
exec gosu steam:steam "${CMD_LINE[@]}"
