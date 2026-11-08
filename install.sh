#!/usr/bin/env bash
# Instala o media server neste Mac (OrbStack + launchd). Rode dentro do diretório do repo.
set -euo pipefail
cd "$(dirname "$0")"
command -v orbctl >/dev/null || brew install --cask orbstack
brew install jq tailscale 2>/dev/null || true
[ -f .env ] || { cp .env.example .env; sed -i '' "s/^PUID=.*/PUID=$(id -u)/;s/^PGID=.*/PGID=$(id -g)/" .env; }
TS=$(tailscale ip -4 2>/dev/null || true); [ -n "$TS" ] && sed -i '' "s/^TS_IP=.*/TS_IP=$TS/" .env
set -a; . ./.env; set +a
mkdir -p "$CONFIG_DIR" "$DATA_DIR"/{torrents,media}/{movies,tv,music} logs
docker compose up -d
./configure.sh
for n in mdns doctor; do
  P=$HOME/Library/LaunchAgents/local.mediaserver.$n.plist
  sed "s#__HOME__#$HOME#g;s#$HOME/mediaserver#$PWD#g" launchd/local.mediaserver.$n.plist > "$P"
  launchctl bootout "gui/$(id -u)/local.mediaserver.$n" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$P"
done
echo "Pronto. Cadastre o Split DNS 'lan' no Tailscale (ver README). Teste: ./doctor.sh"
