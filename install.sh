#!/usr/bin/env bash
# Instala o media server. macOS (OrbStack + launchd) ou Windows/Linux (Docker; no Windows, rode dentro do WSL2 — use install.ps1).
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh
if [ $IS_MAC = 1 ]; then
  command -v orbctl >/dev/null || brew install --cask orbstack
  brew install jq tailscale 2>/dev/null || true
else
  for c in docker jq curl; do command -v $c >/dev/null || { echo "Faltando '$c'. Instale (Windows: Docker Desktop com integração WSL; WSL: sudo apt install jq curl)."; exit 1; }; done
  docker info >/dev/null 2>&1 || { echo "Docker não responde. Abra o Docker Desktop e habilite a integração com a distro WSL."; exit 1; }
fi
[ -f .env ] || { cp .env.example .env; sedi "s/^PUID=.*/PUID=$(id -u)/;s/^PGID=.*/PGID=$(id -g)/" .env; }
if [ $IS_MAC = 1 ]; then
  grep -q '^COMPOSE_PROFILES=' .env || echo 'COMPOSE_PROFILES=tailscale' >> .env
  TS=$(tailscale ip -4 2>/dev/null || true); [ -n "$TS" ] && sedi "s/^TS_IP=.*/TS_IP=$TS/" .env
fi
set -a; . ./.env; set +a
mkdir -p "$CONFIG_DIR" "$DATA_DIR"/{torrents,media}/{movies,tv,music} logs
docker compose up -d
./configure.sh
if [ $IS_MAC = 1 ]; then
  for n in mdns doctor; do
    P=$HOME/Library/LaunchAgents/local.mediaserver.$n.plist
    sed "s#__HOME__/mediaserver#$PWD#g" launchd/local.mediaserver.$n.plist > "$P"
    launchctl bootout "gui/$(id -u)/local.mediaserver.$n" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$P"
  done
  echo "Pronto. Cadastre o Split DNS 'lan' no Tailscale (ver README). Teste: ./doctor.sh"
else
  echo "Pronto. Abra http://localhost (página inicial) ou http://localhost:8096 (Jellyfin). Teste: ./doctor.sh"
fi
