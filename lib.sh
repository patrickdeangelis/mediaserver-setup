# Helpers portáveis (macOS / Linux / Windows via WSL2). Use: . ./lib.sh
IS_MAC=0; [ "$(uname)" = Darwin ] && IS_MAC=1
sedi() { if [ $IS_MAC = 1 ]; then sed -i '' "$@"; else sed -i "$@"; fi; }
# URL de um app a partir da máquina que roda os scripts.
# macOS: nomes .local (Caddy + Bonjour). Windows/Linux: localhost:porta.
app_url() {
  if [ $IS_MAC = 1 ]; then echo "http://$1.local"; return; fi
  case $1 in
    jellyfin) echo http://localhost:8096 ;; qbittorrent) echo http://localhost:8085 ;;
    prowlarr) echo http://localhost:9696 ;; sonarr) echo http://localhost:8989 ;;
    radarr) echo http://localhost:7878 ;; lidarr) echo http://localhost:8686 ;;
    bazarr) echo http://localhost:6767 ;; seerr) echo http://localhost:5055 ;;
  esac
}
