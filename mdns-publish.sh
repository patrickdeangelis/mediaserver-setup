#!/usr/bin/env bash
# Anuncia media.local, jellyfin.local, sonarr.local... na rede local (Bonjour/mDNS) apontando
# para o IP atual do Mac, para que iPhone/TV/outros computadores abram os mesmos endereços.
# Roda sempre via launchd (local.mediaserver.mdns) e se reanuncia quando o IP muda.
NAMES="media jellyfin seerr sonarr radarr lidarr bazarr prowlarr qbittorrent"
PIDS=()
stop() { [ ${#PIDS[@]} -gt 0 ] && kill "${PIDS[@]}" 2>/dev/null; PIDS=(); }
trap 'stop; exit 0' TERM INT

current_ip() {
  local ifc; ifc=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
  [ -n "$ifc" ] && ipconfig getifaddr "$ifc" 2>/dev/null
}

last=""
while true; do
  ip=$(current_ip)
  # Só anuncia em IPs de rede local
  # (ignora túnel/VPN como o do Tailscale); sem rede, anuncia em 127.0.0.1 para o próprio Mac
  case "$ip" in 10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) ;; *) ip=127.0.0.1 ;; esac
  if [ "$ip" != "$last" ]; then
    stop
    if [ -n "$ip" ]; then
      for n in $NAMES; do
        /usr/bin/dns-sd -P "Media $n" _http._tcp local 80 "$n.local" "$ip" >/dev/null 2>&1 &
        PIDS+=($!)
      done
      echo "$(date '+%F %T') anunciando $NAMES em $ip"
    fi
    last=$ip
  fi
  sleep 30
done
