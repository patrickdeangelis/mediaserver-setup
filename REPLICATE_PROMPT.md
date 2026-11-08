# Prompt para replicar o media server

Cole o bloco abaixo no Claude Code (ou outro agente) em um Mac novo.

---

Monte um media server doméstico num Mac (Apple Silicon, macOS) usando OrbStack/Docker Compose, em `~/mediaserver`.
Tudo em português do Brasil, sem senhas (uso doméstico), idempotente e com autocura. Se existir o repo
`github.com/patrickdeangelis/mediaserver-setup`, clone-o e rode `./install.sh`; caso contrário construa assim:

**Stack (`docker-compose.yml`, rede `mediaserver_default`, `restart: unless-stopped`, PUID/PGID/TZ do `.env`, TZ=America/Fortaleza):**
- jellyfin (8096, 7359/udp) · qbittorrent (8085 web, 6881 tcp/udp) · prowlarr (9696) · sonarr (8989) · radarr (7878) · lidarr (8686) · bazarr (6767) — imagens `lscr.io/linuxserver/*:latest`
- seerr `ghcr.io/seerr-team/seerr` (5055) · flaresolverr · torrent-indexer `felipemarinho97/torrent-indexer` (+ redis:alpine, `--save 300 1 --appendonly no`)
- caddy:alpine (porta 80, `Caddyfile` via reverse_proxy, `auto_https off`, `admin off`) · coredns (53 tcp/udp) · willfarrell/autoheal
- Estado em `./config/<app>` e `./data` (`torrents/{movies,tv,music}` e `media/{movies,tv,music}`; sonarr/radarr/lidarr/qbittorrent montam `./data:/data` inteiro para permitir hardlinks; jellyfin/bazarr só `media`). `DATA_DIR` pode ser um HD externo.
- Todo serviço com healthcheck (curl no /ping, /health etc.) e label `autoheal=true`.

**Rede/nomes:**
- `*.local` (casa): `mdns-publish.sh` anuncia `media jellyfin seerr sonarr radarr lidarr bazarr prowlarr qbittorrent` via `dns-sd -P` apontando para o IP LAN do Mac (launchd `local.mediaserver.mdns`, KeepAlive).
- `*.lan` (Tailscale): CoreDNS responde `*.lan` com o IP Tailscale do Mac (`TS_IP`); cadastrar Split DNS `lan` no painel do Tailscale. Caddy mapeia cada nome para o app; `:80` serve `home/index.html` (página inicial).

**`configure.sh` (idempotente, via APIs):** qBittorrent sem login, categorias e paths; Jellyfin com usuário `admin` oculto (senha em `.env`) + usuário `patrick` sem senha, bibliotecas movies/tv/music, pt-BR; root folders, download client, renomeação e notificação Jellyfin no Sonarr/Radarr/Lidarr; perfis de qualidade "Dual áudio (dublado+legendado)" (padrão), "Legendado (original)" e "Dublado (PT-BR)" com custom formats, mais as versões 4K (2160p) "Dual áudio 4K (dublado + legendado)", "Legendado 4K (original)" e "Dublado 4K (PT-BR)" acrescentadas sem substituir as de 1080p; Prowlarr sem login com FlareSolverr (tag) e indexadores 1337x, YTS, EZTV, The Pirate Bay, LimeTorrents, Knaben, Torrent Downloads + BR (BLUDV, Comando, Torrent dos Filmes, Filme Torrent, Rede Torrent, Starck Filmes, Vaca Torrent) via `torrent-indexer` e apps sincronizados (fullSync); Bazarr com Sonarr/Radarr e legendas pt-BR + inglês; Seerr (pt-BR, região BR) ligado ao Jellyfin, Radarr e Sonarr.

**`doctor.sh [--fix] [--quiet]`** (launchd `local.mediaserver.doctor`, a cada 600s e no login): liga OrbStack, sobe containers, corrige DNS se o IP Tailscale mudar, confere endereços, health dos apps e disco, notifica no macOS, log em `logs/doctor.log`.

Ao final: rode `./doctor.sh` e mostre o resultado; liste o que ficou manual (Split DNS no Tailscale, port-forward 6881 opcional).

**Windows:** Docker Desktop + WSL2. Rode `install.ps1` (ou, no WSL, `./install.sh`). Scripts usam `lib.sh` (`app_url` → `localhost:porta`, `sedi`); sem Bonjour/CoreDNS/Tailscale/launchd (o serviço `dns` fica no profile `tailscale`). Acesso em http://localhost.
