# Media server

Prowlarr → Sonarr / Radarr / Lidarr / Bazarr → qBittorrent → Jellyfin, tudo em Docker (OrbStack).

## Endereços

Padrão em qualquer lugar (casa ou rua), com o **Tailscale ligado**: página inicial em **http://media.lan**

| App | Endereço | Pra quê |
|---|---|---|
| Jellyfin | http://jellyfin.lan | Assistir (usuário `patrick`, senha em branco) |
| **Pedidos** (Seerr) | http://seerr.lan | Pedir filmes e séries: busque e toque em **Solicitar** (entre com `patrick`, senha em branco) |
| Sonarr | http://sonarr.lan | Séries |
| Radarr | http://radarr.lan | Filmes |
| Lidarr | http://lidarr.lan | Música |
| Bazarr | http://bazarr.lan | Legendas (pt-BR + inglês) |
| Prowlarr | http://prowlarr.lan | Indexadores |
| qBittorrent | http://qbittorrent.lan | Downloads |

Em casa o Tailscale conecta direto pela rede local, então não há perda de velocidade.

**Reserva sem Tailscale** (TV, visitas; só na rede de casa): os mesmos nomes com `.local` (http://media.local, http://jellyfin.local…)
ou `http://<IP do Mac>:porta`. Portas: Jellyfin 8096, Pedidos 5055, Sonarr 8989, Radarr 7878, Lidarr 8686, Bazarr 6767, Prowlarr 9696, qBittorrent 8085.

**iPhone:** app **Swiftfin** ou **Jellyfin** (oficiais, grátis) ou **Infuse**, servidor `http://jellyfin.lan`.
Para pedir: abra `http://seerr.lan` no Safari → Compartilhar → **Adicionar à Tela de Início**.

### Como funciona

- `.lan`: um DNS no Mac (CoreDNS, `dns/Corefile`) responde `*.lan` com o IP do Mac no Tailscale. Ele está cadastrado
  como Split DNS da tailnet, e o Caddy na porta 80 (`Caddyfile`) entrega cada nome ao app certo.
- `.local`: o Mac anuncia os nomes na rede de casa via Bonjour (`mdns-publish.sh`, launchd `local.mediaserver.mdns`).

### Split DNS (uma vez só)

No painel do Tailscale, em https://login.tailscale.com/admin/dns: **Nameservers → Add nameserver → Custom**.
- Nameserver: `<tailscale ip -4>` (IP do Mac no Tailscale; `tailscale ip -4`)
- Ligue **Restrict to domain (Split DNS)**, com domínio `lan`
- Save

## Uso

1. Indexadores já configurados no Prowlarr e sincronizados: 1337x, YTS, EZTV, The Pirate Bay, LimeTorrents, Knaben,
   Torrent Downloads e os brasileiros BLUDV e Torrent dos Filmes (dublado/dual áudio, via container `torrent-indexer`).
   A lista fica em `configure.sh`. Os sites BR fora do ar são retentados a cada execução.
2. Peça filmes e séries em **http://seerr.lan** (ou adicione direto no Radarr/Sonarr; música no Lidarr). Eles buscam, mandam pro qBittorrent,
   organizam em `data/media/` (via hardlink, sem ocupar espaço em dobro) e avisam o Jellyfin.
3. O Bazarr baixa as legendas automaticamente.

## Idioma (perfis no pedido)

No Seerr, ao solicitar, abra **Opções avançadas → Perfil de qualidade**:

| Perfil | O que baixa |
|---|---|
| **Dual áudio (dublado + legendado)**, o padrão | Prefere DUAL (áudio PT-BR + original no mesmo arquivo; no player você escolhe). Sem DUAL, baixa o original com legenda e troca pelo DUAL quando aparecer |
| Legendado (original) | Só áudio original; o Bazarr baixa a legenda PT-BR |
| Dublado (PT-BR) | Só áudio em português |

No Jellyfin, troque o áudio ou a legenda pelo ícone de balão durante o vídeo.

## Estrutura

```
data/torrents/{movies,tv,music}   downloads do qBittorrent
data/media/{movies,tv,music}      biblioteca do Jellyfin
config/<app>/                     configurações de cada app
```

Para usar um HD externo, mude `DATA_DIR` no `.env` (ex.: `/Volumes/HD/data`), crie lá as mesmas pastas e rode `docker compose up -d`.

## Persistência e autocura

- Todo o estado fica em pastas no disco (`config/` e `data/`). Apagar ou recriar os containers não perde nada.
- Cada container tem healthcheck. O `autoheal` reinicia quem ficar *unhealthy*, e `restart: unless-stopped` religa quem cair.
- O `doctor.sh` roda sozinho a cada 10 min e no login (launchd `local.mediaserver.doctor`). Ele liga o OrbStack se estiver parado,
  sobe containers ausentes, corrige o DNS .lan se o IP do Tailscale mudar, religa o anúncio Bonjour, confere endereços, alertas dos apps e disco,
  e manda notificação no macOS quando algo muda. O histórico fica em `logs/doctor.log`.
- O OrbStack inicia junto com o login do Mac.

## Comandos

```sh
docker compose up -d        # sobe (os containers também voltam sozinhos com o OrbStack)
docker compose down         # para tudo
docker compose pull && docker compose up -d   # atualiza
./configure.sh              # reaplica a configuração (idempotente)
./doctor.sh                 # diagnóstico  (--fix corrige)
```

## Detalhes

- Sem senha em nada e tudo aberto na rede em que o Mac estiver. Em Wi-Fi público (hotel, café), qualquer pessoa da
  mesma rede consegue abrir os painéis. Se for usar fora de casa, pare a stack (`docker compose stop`) ou ligue o firewall do macOS.
- Portas: 53 (DNS .lan), 80 (nomes .lan/.local), 5055, 8096, 8085, 9696, 8989, 7878, 8686, 6767 (apps), 7359/udp (descoberta do Jellyfin), 6881 (BitTorrent).
- qBittorrent aparece como "firewalled": o roteador não encaminha a porta 6881. Funciona do mesmo jeito; encaminhar a porta aumenta a velocidade.
- O Jellyfin 12 exige senha para administrador. Existe um usuário `admin` oculto, com a senha em `JELLYFIN_ADMIN_PASS` no `.env`,
  usado só pelo script. No dia a dia, use `patrick`.

## Windows (Docker Desktop + WSL2)

```powershell
irm https://raw.githubusercontent.com/patrickdeangelis/mediaserver-setup/main/install.ps1 | iex
```

Requisitos: Windows 10/11 com WSL2 (`wsl --install`) e Docker Desktop (o script instala via winget; ative a integração WSL em Settings → Resources).
O projeto fica em `~/mediaserver` dentro do WSL (rápido e com hardlinks). Acesso: http://localhost (página inicial) ou `localhost:porta` (Jellyfin 8096, Pedidos 5055, Sonarr 8989, Radarr 7878, Lidarr 8686, Bazarr 6767, Prowlarr 9696, qBittorrent 8085).
Diferenças do macOS: sem nomes `.local`/`.lan` (Bonjour, CoreDNS e Tailscale são opcionais e só do macOS) e sem launchd; o Docker Desktop religa os containers
(marque "Start Docker Desktop when you sign in"). Para outros aparelhos da rede use `http://<IP do PC>:porta` e libere as portas no firewall do Windows.
Para guardar a mídia em outro disco, ajuste `DATA_DIR` no `.env` (ex.: `/mnt/d/data`; hardlinks exigem torrents/ e media/ no mesmo disco).
