#!/usr/bin/env bash
# Diagnóstico (e autocorreção) da stack.
#   ./doctor.sh           mostra o diagnóstico
#   ./doctor.sh --fix     também corrige: liga o OrbStack, sobe containers, reinicia quem travou
#   --quiet               só grava em logs/doctor.log e avisa no macOS quando algo muda (usado pelo launchd)
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.orbstack/bin:$PATH"
cd "$(dirname "$0")"
set -a; source .env; set +a
. ./lib.sh

FIX=0 QUIET=0
for a in "$@"; do case $a in --fix) FIX=1 ;; --quiet) QUIET=1 ;; esac; done
mkdir -p logs
LOG=logs/doctor.log
PROBLEMS=() FIXED=()

out() { [ $QUIET = 1 ] || printf '%s\n' "$*"; }
ok() { out "  ✓ $*"; }
bad() { out "  ✗ $*"; PROBLEMS+=("$*"); }
warn() { out "  ! $*"; PROBLEMS+=("$*"); }
fixed() { out "  ↻ $*"; FIXED+=("$*"); }

# ---------------------------------------------------------------- OrbStack / Docker
out "Docker"
if ! docker info >/dev/null 2>&1; then
  if [ $FIX = 1 ]; then
    command -v orbctl >/dev/null && orbctl start >/dev/null 2>&1
    for _ in $(seq 60); do docker info >/dev/null 2>&1 && break; sleep 2; done
  fi
  if docker info >/dev/null 2>&1; then fixed "OrbStack estava parado — iniciado"; else bad "OrbStack/Docker não responde"; fi
fi
docker info >/dev/null 2>&1 && ok "OrbStack rodando"

# ---------------------------------------------------------------- Containers
if docker info >/dev/null 2>&1; then
  out "Containers"
  services=$(docker compose config --services)
  missing=0
  for s in $services; do
    [ -n "$(docker compose ps -q "$s" 2>/dev/null)" ] || missing=1
  done
  if [ $missing = 1 ] || docker compose ps -a --format '{{.State}}' | grep -qv running; then
    if [ $FIX = 1 ]; then docker compose up -d >/dev/null 2>&1 && fixed "containers parados/ausentes religados"; fi
  fi
  while IFS=$'\t' read -r name state health; do
    case "$state/$health" in
      running/healthy | running/) ok "$name" ;;
      running/starting) ok "$name (iniciando)" ;;
      *)
        if [ $FIX = 1 ]; then docker restart "$name" >/dev/null 2>&1 && fixed "$name estava $state/$health — reiniciado"
        else bad "$name: $state ${health:+($health)}"; fi ;;
    esac
  done < <(docker compose ps -a --format '{{.Name}}\t{{.State}}\t{{.Health}}')
fi

if [ $IS_MAC = 1 ]; then  # nomes .lan/.local (Tailscale, Bonjour) só existem no macOS
# ---------------------------------------------------------------- Domínios
out "Endereços"
TS_IP=$(tailscale ip -4 2>/dev/null)
ans=$(dig +short +time=3 @127.0.0.1 media.lan A 2>/dev/null)
if [ -z "$TS_IP" ]; then warn "Tailscale desligado: endereços .lan indisponíveis"
elif [ "$ans" != "$TS_IP" ]; then
  if [ $FIX = 1 ]; then
    sedi '/^TS_IP=/d' .env; echo "TS_IP=$TS_IP" >>.env
    docker compose up -d --force-recreate dns >/dev/null 2>&1 && fixed "DNS .lan atualizado para $TS_IP"
  else bad "DNS .lan responde '${ans:-nada}', esperado $TS_IP"; fi
else ok "DNS: *.lan -> $TS_IP"; fi
if [ -n "$TS_IP" ]; then
  for h in media jellyfin seerr sonarr radarr lidarr bazarr prowlarr qbittorrent; do
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' --resolve "$h.lan:80:$TS_IP" "http://$h.lan/")
    case $code in 2??|3??) ok "http://$h.lan" ;; *) bad "http://$h.lan não responde (HTTP $code)" ;; esac
  done
fi
dig +short +time=3 media.lan A 2>/dev/null | grep -q . ||
  warn "este Mac não resolve .lan: cadastre o Split DNS no painel do Tailscale (ver README)"

# ---------------------------------------------------------------- Rede local (Bonjour) e Tailscale
out "Rede"
if ! launchctl print "gui/$(id -u)/local.mediaserver.mdns" >/dev/null 2>&1; then
  if [ $FIX = 1 ] && [ -f "$HOME/Library/LaunchAgents/local.mediaserver.mdns.plist" ]; then
    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.mediaserver.mdns.plist" && fixed "anúncio Bonjour religado"
  else bad "anúncio Bonjour (local.mediaserver.mdns) não está rodando"; fi
fi
n=$(pgrep -f 'dns-sd -P Media' | wc -l | tr -d ' ')
if [ "$n" -ge 9 ]; then ok "reserva .local anunciada na rede ($n nomes)"
elif [ $FIX = 1 ]; then launchctl kickstart -k "gui/$(id -u)/local.mediaserver.mdns" && fixed "anúncio Bonjour reiniciado ($n/9 nomes)"
else bad "só $n/9 nomes .local anunciados"; fi
if command -v tailscale >/dev/null && tailscale status >/dev/null 2>&1; then
  TS_HOST=$(tailscale status --json | jq -r '.Self.DNSName | sub("\\.$"; "")')
  code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://$TS_HOST:8096/health")
  [ "$code" = 200 ] && ok "Tailscale: http://$TS_HOST:8096" || warn "Jellyfin não responde pelo Tailscale (HTTP $code)"
fi
fi

# ---------------------------------------------------------------- Saúde interna dos apps
out "Apps"
key() { sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$CONFIG_DIR/$1/config.xml" 2>/dev/null; }
for a in sonarr:v3 radarr:v3 lidarr:v1 prowlarr:v1; do
  app=${a%:*} ver=${a#*:}
  msgs=$(curl -s -m 15 -H "X-Api-Key: $(key "$app")" "$(app_url "$app")/api/$ver/health" | jq -r '.[] | select(.type=="error" or .type=="warning") | .message' 2>/dev/null)
  if [ -z "$msgs" ]; then ok "$app sem alertas"; else while read -r m; do warn "$app: $m"; done <<<"$msgs"; fi
done
BK=$(sed -n '/^auth:/,/^[a-z]/s/^  apikey: //p' "$CONFIG_DIR/bazarr/config/config.yaml" 2>/dev/null)
bz=$(curl -s -m 15 -H "X-API-KEY: $BK" $(app_url bazarr)/api/system/health | jq -r '.data[]? | "\(.object): \(.issue)"' 2>/dev/null)
if [ -z "$bz" ]; then ok "bazarr sem alertas"; else while read -r m; do warn "bazarr: $m"; done <<<"$bz"; fi
curl -sf -m 10 -o /dev/null $(app_url qbittorrent)/api/v2/app/version &&
  ok "qBittorrent: $(curl -s -m 10 $(app_url qbittorrent)/api/v2/transfer/info | jq -r '.connection_status')" ||
  bad "qBittorrent API não responde"

# ---------------------------------------------------------------- Disco
out "Disco"
free_gb=$(df -Pk "$DATA_DIR" | awk 'NR==2 {print int($4/1048576)}')
if [ "$free_gb" -lt 5 ]; then warn "só ${free_gb} GB livres em $DATA_DIR"; else ok "${free_gb} GB livres"; fi

# ---------------------------------------------------------------- Resultado
stamp=$(date '+%F %T')
{
  for f in "${FIXED[@]:-}"; do [ -n "$f" ] && echo "$stamp FIX  $f"; done
  for p in "${PROBLEMS[@]:-}"; do [ -n "$p" ] && echo "$stamp WARN $p"; done
  [ ${#PROBLEMS[@]} = 0 ] && [ ${#FIXED[@]} = 0 ] && echo "$stamp OK"
} >>"$LOG"
tail -n 2000 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"

# Notificação no macOS só quando algo foi corrigido ou a lista de problemas mudou
state=$(printf '%s\n' "${PROBLEMS[@]:-}" | sort)
if [ $QUIET = 1 ]; then
  notify() { { [ $IS_MAC = 1 ] && osascript -e "display notification \"$2\" with title \"Media server\" subtitle \"$1\"" 2>/dev/null; true; }; }
  [ ${#FIXED[@]} -gt 0 ] && notify "Corrigido automaticamente" "${FIXED[0]}"
  if [ "$state" != "$(cat logs/.doctor-state 2>/dev/null)" ] && [ ${#PROBLEMS[@]} -gt 0 ]; then
    notify "${#PROBLEMS[@]} problema(s)" "${PROBLEMS[0]} — veja ./doctor.sh"
  fi
fi
printf '%s' "$state" >logs/.doctor-state

out ""
if [ ${#PROBLEMS[@]} = 0 ]; then out "Tudo certo."; else out "${#PROBLEMS[@]} problema(s). Rode ./doctor.sh --fix para tentar corrigir."; fi
[ ${#PROBLEMS[@]} = 0 ]
