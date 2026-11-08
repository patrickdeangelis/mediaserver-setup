#!/usr/bin/env bash
# Configura automaticamente toda a stack após o primeiro `docker compose up -d`.
# Idempotente: pode rodar de novo sem duplicar nada.
# Sem senhas: as interfaces só são acessíveis pelo Mac via domínios *.local do OrbStack.
set -euo pipefail
cd "$(dirname "$0")"
set -a; source .env; set +a
. ./lib.sh

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
wait_http() { until curl -sf -o /dev/null "$1"; do sleep 2; done; }
xml_key() { sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$CONFIG_DIR/$1/config.xml"; }

# ---------------------------------------------------------------- qBittorrent
QB=$(app_url qbittorrent)
QBJAR=$(mktemp)
wait_http $QB
qb() { curl -sf -b "$QBJAR" -H "Referer: $QB" "$@"; }
if ! qb -o /dev/null $QB/api/v2/app/version; then
  # Primeira execução: usa a senha temporária do log só para desligar a autenticação
  TMP_PW=$(docker logs qbittorrent 2>&1 | sed -n 's/.*temporary password is provided for this session: //p' | tail -1)
  curl -sf -o /dev/null -c "$QBJAR" -H "Referer: $QB" -d username=admin --data-urlencode "password=$TMP_PW" $QB/api/v2/auth/login ||
    { echo "Falha no login do qBittorrent"; exit 1; }
fi
log "qBittorrent: sem senha, pastas e categorias"
qb $QB/api/v2/app/setPreferences --data-urlencode "json=$(jq -nc '{
  bypass_local_auth: true, bypass_auth_subnet_whitelist_enabled: true, bypass_auth_subnet_whitelist: "0.0.0.0/0\n::/0",
  save_path: "/data/torrents", temp_path_enabled: false,
  listen_port: 6881, upnp: false, random_port: false, preallocate_all: false,
  auto_tmm_enabled: true, torrent_changed_tmm_enabled: true,
  save_path_changed_tmm_enabled: true, category_changed_tmm_enabled: true,
  max_ratio_enabled: true, max_ratio: 2, max_seeding_time_enabled: true, max_seeding_time: 10080, max_ratio_act: 0
}')"
for c in tv movies music prowlarr; do
  path=/data/torrents/$c; [ $c = prowlarr ] && path=/data/torrents
  qb $QB/api/v2/torrents/createCategory -d "category=$c" -d "savePath=$path" 2>/dev/null ||
    qb $QB/api/v2/torrents/editCategory -d "category=$c" -d "savePath=$path"
done
rm -f "$QBJAR"

# ---------------------------------------------------------------- Jellyfin
JF=$(app_url jellyfin)
JFAUTH='MediaBrowser Client="mediaserver-setup", Device="cli", DeviceId="mediaserver-setup", Version="1.0"'
wait_http $JF/health
jf() { curl -sf -H "Authorization: $JFAUTH${JFTOKEN:+, Token=\"$JFTOKEN\"}" -H 'Content-Type: application/json' "$@"; }
# O Jellyfin 12 não aceita admin sem senha: cria um "admin" oculto (senha gerada em .env)
# e um usuário comum sem senha, que é o único que aparece na tela de login.
if [ -z "${JELLYFIN_ADMIN_PASS:-}" ]; then
  JELLYFIN_ADMIN_PASS=$(openssl rand -hex 12)
  echo "JELLYFIN_ADMIN_PASS=$JELLYFIN_ADMIN_PASS" >>.env
fi
if [ "$(curl -s $JF/System/Info/Public | jq -r .StartupWizardCompleted)" != "true" ]; then
  log "Jellyfin: assistente inicial"
  jf -X POST $JF/Startup/Configuration -d '{"ServerName":"Media","UICulture":"pt-BR","MetadataCountryCode":"BR","PreferredMetadataLanguage":"pt-br"}'
  jf $JF/Startup/User >/dev/null
  jf -X POST $JF/Startup/User -d "$(jq -nc --arg p "$JELLYFIN_ADMIN_PASS" '{Name:"admin", Password:$p}')"
  jf -X POST $JF/Startup/RemoteAccess -d '{"EnableRemoteAccess":true}'
  jf -X POST $JF/Startup/Complete
fi
AUTH=$(jf -X POST $JF/Users/AuthenticateByName -d "$(jq -nc --arg p "$JELLYFIN_ADMIN_PASS" '{Username:"admin", Pw:$p}')")
JFTOKEN=$(jq -r .AccessToken <<<"$AUTH")

log "Jellyfin: admin oculto, usuário $JELLYFIN_USER sem senha"
jf -X POST "$JF/Users/$(jq -r .User.Id <<<"$AUTH")/Policy" -d "$(jq -c '.User.Policy | .IsHidden=true' <<<"$AUTH")"
ME=$(jf $JF/Users | jq -c --arg u "$JELLYFIN_USER" '.[] | select(.Name==$u)')
[ -n "$ME" ] || ME=$(jf -X POST $JF/Users/New -d "$(jq -nc --arg u "$JELLYFIN_USER" '{Name:$u}')")
ME_ID=$(jq -r .Id <<<"$ME")
jf -X POST "$JF/Users/$ME_ID/Policy" -d "$(jq -c '.Policy | .IsHidden=false' <<<"$ME")"  # aparece na tela de login
jf -X POST "$JF/Users/$ME_ID/Password" -d '{"ResetPassword":true}'                       # sem senha

log "Jellyfin: bibliotecas (metadados pt-BR)"
LIBOPTS='{"PreferredMetadataLanguage":"pt-br","MetadataCountryCode":"BR","EnableRealtimeMonitor":true,"EnableChapterImageExtraction":false}'
existing=$(jf $JF/Library/VirtualFolders | jq -r '.[].Name')
created=0
add_lib() { # nome tipo caminho
  grep -qx "$1" <<<"$existing" && return
  jf -X POST "$JF/Library/VirtualFolders?name=$(jq -rn --arg s "$1" '$s|@uri')&collectionType=$2&paths=$3&refreshLibrary=true" \
    -d "{\"LibraryOptions\":$LIBOPTS}"
  created=1
}
add_lib "Filmes" movies /data/media/movies
add_lib "Séries" tvshows /data/media/tv
add_lib "Música" music /data/media/music
# Garante pt-BR no servidor e nas bibliotecas (também corrige instalações antigas com "pt")
jf -X POST $JF/System/Configuration -d "$(jf $JF/System/Configuration | jq -c '.PreferredMetadataLanguage="pt-br" | .MetadataCountryCode="BR" | .UICulture="pt-BR"')"
jf $JF/Library/VirtualFolders | jq -c --argjson o "$LIBOPTS" '.[] | {Id:.ItemId, LibraryOptions:(.LibraryOptions + $o)}' |
  while read -r lib; do jf -X POST $JF/Library/VirtualFolders/LibraryOptions -d "$lib"; done
# Bibliotecas criadas pela API só passam a ser monitoradas em tempo real após um scan completo
if [ $created = 1 ]; then
  log "Jellyfin: scan inicial (ativa o monitoramento das pastas)"
  sleep 5; jf -X POST $JF/Library/Refresh
  until jf "$JF/ScheduledTasks?isHidden=false" | jq -e '.[] | select(.Key=="RefreshLibrary" and .State=="Idle")' >/dev/null; do sleep 2; done
fi

# Bibliotecas vazias não são monitoradas: scan a cada 15 min garante que o 1º item de cada
# uma apareça (depois disso, as novidades entram em tempo real)
SCAN_ID=$(jf "$JF/ScheduledTasks?isHidden=false" | jq -r '.[] | select(.Key=="RefreshLibrary") | .Id')
jf -X POST "$JF/ScheduledTasks/$SCAN_ID/Triggers" -d '[{"Type":"IntervalTrigger","IntervalTicks":9000000000}]'

jf $JF/Auth/Keys | jq -e '.Items[] | select(.AppName=="Arr")' >/dev/null || jf -X POST "$JF/Auth/Keys?app=Arr"
JF_KEY=$(jf $JF/Auth/Keys | jq -r '[.Items[] | select(.AppName=="Arr")][0].AccessToken')

# ---------------------------------------------------------------- *arr helpers
arr() { # host versão chave método caminho [json]
  curl -sf -X "$4" -H "X-Api-Key: $3" -H 'Content-Type: application/json' "$(app_url "$1")/api/$2$5" ${6:+-d "$6"}
}
# Preenche .fields[] de um schema a partir de um objeto {nome: valor}
FILL='.fields |= map(if $f[.name] != null then .value = $f[.name] else . end)'
# Liga todos os eventos suportados de uma notificação
ALL_EVENTS='. as $o | with_entries(if (.key|startswith("on")) and (.value|type=="boolean")
  then .value = ($o["supports" + (.key[0:1]|ascii_upcase) + .key[1:]] // false) else . end)'

arr_noauth() { # host versão chave
  local cfg; cfg=$(arr "$1" "$2" "$3" GET /config/host)
  [ "$(jq -r .authenticationMethod <<<"$cfg")" = external ] && return
  cfg=$(jq -c '.authenticationMethod="external"' <<<"$cfg") # sem tela de login
  arr "$1" "$2" "$3" PUT "/config/host/$(jq -r .id <<<"$cfg")" "$cfg" >/dev/null
}

arr_add() { # host versão chave recurso implementação nome camposJSON [jq extra]
  arr "$1" "$2" "$3" GET "/$4" | jq -e --arg n "$6" '.[] | select(.name==$n)' >/dev/null && return
  local body
  body=$(arr "$1" "$2" "$3" GET "/$4/schema" | jq -c --arg i "$5" --arg n "$6" --argjson f "$7" \
    "[.[] | select(.implementation==\$i)][0] | .name=\$n | .enable=true | $FILL | ${8:-.}")
  arr "$1" "$2" "$3" POST "/$4" "$body" >/dev/null || { echo "Falha ao criar $6 em $1"; exit 1; }
}

setup_arr() { # host versão categoriaCampo categoria raiz renomearCampo
  local name=$1 ver=$2 catfield=$3 cat=$4 root=$5 renamefield=$6
  local key; key=$(xml_key "$name")
  wait_http "$(app_url "$name")/ping"
  log "$name: sem login, pasta raiz, qBittorrent, Jellyfin, renomeação"
  arr_noauth "$name" "$ver" "$key"

  if ! arr "$name" "$ver" "$key" GET /rootfolder | jq -e --arg r "$root" '.[] | select(.path==$r)' >/dev/null; then
    if [ "$name" = lidarr ]; then
      local qp mp
      qp=$(arr "$name" "$ver" "$key" GET /qualityprofile | jq '.[0].id')
      mp=$(arr "$name" "$ver" "$key" GET /metadataprofile | jq '[.[] | select(.name!="None")][0].id')
      arr "$name" "$ver" "$key" POST /rootfolder "$(jq -nc --arg r "$root" --argjson q "$qp" --argjson m "$mp" \
        '{name:"Música", path:$r, defaultQualityProfileId:$q, defaultMetadataProfileId:$m,
          defaultMonitorOption:"all", defaultNewItemMonitorOption:"all", defaultTags:[]}')" >/dev/null
    else
      arr "$name" "$ver" "$key" POST /rootfolder "$(jq -nc --arg r "$root" '{path:$r}')" >/dev/null
    fi
  fi

  arr_add "$name" "$ver" "$key" downloadclient QBittorrent qBittorrent \
    "$(jq -nc --arg cf "$catfield" --arg c "$cat" '{host:"qbittorrent", port:8085} + {($cf):$c}')"

  arr_add "$name" "$ver" "$key" notification MediaBrowser Jellyfin \
    "$(jq -nc --arg k "$JF_KEY" '{host:"jellyfin", port:8096, useSsl:false, apiKey:$k, notify:false, updateLibrary:true}')" \
    "$ALL_EVENTS"

  local naming; naming=$(arr "$name" "$ver" "$key" GET /config/naming)
  arr "$name" "$ver" "$key" PUT /config/naming "$(jq -c ".$renamefield=true" <<<"$naming")" >/dev/null
}

setup_arr sonarr v3 tvCategory    tv     /data/media/tv     renameEpisodes
setup_arr radarr v3 movieCategory movies /data/media/movies renameMovies
setup_arr lidarr v1 musicCategory music  /data/media/music  renameTracks

# ---------------------------------------------------------------- Idioma do áudio
# Formatos PT-BR/Dual + perfis no Radarr e no Sonarr. No Seerr, o perfil escolhido no pedido define o idioma:
#   Dual áudio (dublado + legendado)  padrão: prefere DUAL (PT-BR + original no mesmo arquivo);
#                                     sem DUAL, baixa o original e segue procurando o DUAL
#   Legendado (original)              só áudio original (legenda PT-BR pelo Bazarr)
#   Dublado (PT-BR)                   só aceita áudio em português
PTBR_REGEX='(?i)\b(dublado|dual[ ._-]?(audio|áudio)?|pt[ ._-]?br|nacional|brazilian)\b'
DUAL_REGEX='(?i)\bdual\b'
STOCK_PROFILES='["Any","SD","HD-720p","HD-1080p","Ultra-HD","HD - 720p/1080p"]'
setup_languages() { # app langId-PT-BR recurso(movie|series)
  local app=$1 lang=$2 media=$3 key; key=$(xml_key "$app")
  cf_add() { # nome implementação valor
    arr "$app" v3 "$key" GET /customformat | jq -e --arg n "$1" '.[] | select(.name==$n)' >/dev/null && return
    arr "$app" v3 "$key" POST /customformat "$(jq -nc --arg n "$1" --arg i "$2" --argjson v "$3" '{name:$n,
      includeCustomFormatWhenRenaming:false, specifications:[{name:$n, implementation:$i, negate:false, required:false,
      fields:([{name:"value", value:$v}] + (if $i=="LanguageSpecification" then [{name:"exceptLanguage", value:false}] else [] end))}]}')" >/dev/null
  }
  cf_add "PT-BR (áudio)" LanguageSpecification "$lang"
  cf_add "PT-BR (nome)" ReleaseTitleSpecification "$(jq -nc --arg r "$PTBR_REGEX" '$r')"
  cf_add "Dual áudio" ReleaseTitleSpecification "$(jq -nc --arg r "$DUAL_REGEX" '$r')"
  local cfs profiles base
  cfs=$(arr "$app" v3 "$key" GET /customformat)
  profiles=$(arr "$app" v3 "$key" GET /qualityprofile)
  # modelo de qualidade: HD-1080p de fábrica (ou um perfil nosso, se os de fábrica já foram removidos)
  base=$(jq -c '[.[] | select(.name=="HD-1080p" or .name=="Legendado (original)")] | sort_by(.name!="HD-1080p") | .[0]' <<<"$profiles")
  profile() { # nome {formato:pontos} mínimo corte idioma-radarr
    local body cur
    body=$(jq -c --arg n "$1" --argjson sc "$2" --argjson min "$3" --argjson cut "$4" --argjson lg "$5" --argjson cfs "$cfs" '
      del(.id) | .name=$n | .upgradeAllowed=true | .minFormatScore=$min | .cutoffFormatScore=$cut
      | .formatItems=[$cfs[] | {format:.id, name:.name, score:($sc[.name] // 0)}]
      | if has("language") then .language=$lg else . end' <<<"$base")
    cur=$(jq -c --arg n "$1" '.[] | select(.name==$n)' <<<"$profiles")
    if [ -n "$cur" ]; then arr "$app" v3 "$key" PUT "/qualityprofile/$(jq .id <<<"$cur")" "$(jq -c --argjson id "$(jq .id <<<"$cur")" '.id=$id' <<<"$body")" >/dev/null
    else arr "$app" v3 "$key" POST /qualityprofile "$body" >/dev/null; fi
  }
  profile "Dual áudio (dublado + legendado)" '{"Dual áudio":200,"PT-BR (áudio)":-50,"PT-BR (nome)":-50}' -100 150 '{"id":-1,"name":"Any"}'
  profile "Legendado (original)" '{}' 0 0 '{"id":-2,"name":"Original"}'
  profile "Dublado (PT-BR)" '{"PT-BR (áudio)":100,"PT-BR (nome)":100}' 100 100 '{"id":-1,"name":"Any"}'
  # remove perfis de fábrica que nada usa, para o pedido no Seerr mostrar só as três opções
  profiles=$(arr "$app" v3 "$key" GET /qualityprofile)
  if [ "$app" = radarr ]; then # coleções criadas junto com os filmes também prendem perfis
    local dual; dual=$(jq '.[] | select(.name|startswith("Dual")) | .id' <<<"$profiles")
    arr radarr v3 "$key" GET /collection | jq -c --argjson s "$STOCK_PROFILES" --argjson p "$profiles" --argjson d "$dual" '
      .[] | select(.qualityProfileId as $q | [$p[] | select(.id==$q) | .name][0] as $n | $s | index($n)) | .qualityProfileId=$d' |
      while read -r c; do arr radarr v3 "$key" PUT "/collection/$(jq .id <<<"$c")" "$c" >/dev/null; done
  fi
  local used; used=$(arr "$app" v3 "$key" GET "/$media" | jq -c '[.[].qualityProfileId] | unique')
  for id in $(jq -r --argjson s "$STOCK_PROFILES" --argjson u "$used" '.[] | select((.name as $n | $s | index($n)) and ((.id as $i | $u | index($i)) | not)) | .id' <<<"$profiles"); do
    arr "$app" v3 "$key" DELETE "/qualityprofile/$id" >/dev/null
  done
}
log "radarr/sonarr: perfis Dual áudio / Legendado / Dublado"
setup_languages radarr 30 movie
setup_languages sonarr 33 series

# ---------------------------------------------------------------- Prowlarr
PK=$(xml_key prowlarr)
DEF="$CONFIG_DIR/prowlarr/Definitions/Custom/torrent-indexer.yml"
if ! cmp -s prowlarr/torrent-indexer.yml "$DEF"; then
  mkdir -p "$(dirname "$DEF")"; cp prowlarr/torrent-indexer.yml "$DEF"
  docker restart prowlarr >/dev/null; sleep 3
fi
wait_http $(app_url prowlarr)/ping
log "prowlarr: sem login, FlareSolverr, qBittorrent, indexadores, Sonarr/Radarr/Lidarr"
arr_noauth prowlarr v1 "$PK"

TAG=$(arr prowlarr v1 "$PK" GET /tag | jq '.[] | select(.label=="flaresolverr") | .id')
[ -n "$TAG" ] || TAG=$(arr prowlarr v1 "$PK" POST /tag '{"label":"flaresolverr"}' | jq .id)
arr_add prowlarr v1 "$PK" indexerProxy FlareSolverr FlareSolverr '{"host":"http://flaresolverr:8191/","requestTimeout":60}' ".tags=[$TAG]"

arr_add prowlarr v1 "$PK" downloadclient QBittorrent qBittorrent '{"host":"qbittorrent","port":8085,"category":"prowlarr"}'

# Indexadores mais recomendados (TorrentFreak 2026, megathread do r/Piracy, guias de Prowlarr)
# + sites brasileiros (dublado/dual áudio) via container torrent-indexer.
# Formato: nome | definição do Prowlarr | opção (só p/ torrent-indexer) | tag
# A tag flaresolverr só entra em ação quando o site mostra o desafio do Cloudflare.
INDEXERS=(
  "1337x|1337x||flaresolverr"
  "YTS|yts||flaresolverr"
  "EZTV|eztv||flaresolverr"
  "The Pirate Bay|thepiratebay||flaresolverr"
  "LimeTorrents|limetorrents||flaresolverr"
  "Knaben|Knaben||flaresolverr"
  "Torrent Downloads|torrentdownloads||flaresolverr"
  "BR BLUDV|torrent-indexer|BLUDV|"
  "BR Comando Torrents|torrent-indexer|Comando Torrents|"
  "BR Torrent dos Filmes|torrent-indexer|Torrent dos Filmes|"
  "BR Filme Torrent|torrent-indexer|Filme Torrent|"
  "BR Rede Torrent|torrent-indexer|Rede Torrent|"
  "BR Starck Filmes|torrent-indexer|Starck Filmes|"
  "BR Vaca Torrent|torrent-indexer|Vaca Torrent|"
)
SCHEMA=$(arr prowlarr v1 "$PK" GET /indexer/schema)
CURRENT=$(arr prowlarr v1 "$PK" GET /indexer)
# O Internet Archive (usado no teste inicial) só gera ruído nas buscas
for id in $(jq '.[] | select(.definitionName=="internetarchive") | .id' <<<"$CURRENT"); do
  arr prowlarr v1 "$PK" DELETE "/indexer/$id" >/dev/null
done
for spec in "${INDEXERS[@]}"; do
  IFS='|' read -r name def opt tag <<<"$spec"
  tags='[]'; [ "$tag" = flaresolverr ] && tags="[$TAG]"
  if cur=$(jq -ec --arg n "$name" '.[] | select(.name==$n)' <<<"$CURRENT"); then
    # já existe: só garante a tag da FlareSolverr
    if [ "$tag" = flaresolverr ] && ! jq -e --argjson t "$TAG" '.tags | index($t)' <<<"$cur" >/dev/null; then
      arr prowlarr v1 "$PK" PUT "/indexer/$(jq .id <<<"$cur")" "$(jq -c --argjson t "$TAG" '.tags += [$t]' <<<"$cur")" >/dev/null &&
        echo "   ~ $name: FlareSolverr ativada"
    fi
    continue
  fi
  body=$(jq -c --arg d "$def" --arg n "$name" --arg o "$opt" --argjson t "$tags" '
    [.[] | select(.definitionName==$d)][0] | .name=$n | .enable=true | .appProfileId=1 | .tags=$t
    | .indexerUrls[0] as $u
    | .fields |= map(
        if .name=="baseUrl" then .value=$u
        elif .name=="indexer" and $o != "" then .value=([.selectOptions[] | select(.name==$o)][0].value)
        else . end)' <<<"$SCHEMA")
  if err=$(curl -s -X POST -H "X-Api-Key: $PK" -H 'Content-Type: application/json' \
      -d "$body" -w '\n%{http_code}' $(app_url prowlarr)/api/v1/indexer) && [ "$(tail -1 <<<"$err")" = 201 ]; then
    echo "   + $name"
  else
    echo "   ! $name: não passou no teste ($(sed '$d' <<<"$err" | jq -r '.[0].errorMessage? // .message? // "erro"' 2>/dev/null | head -c 120))"
  fi
done

for app in "Sonarr sonarr 8989" "Radarr radarr 7878" "Lidarr lidarr 8686"; do
  set -- $app
  arr_add prowlarr v1 "$PK" applications "$1" "$1" \
    "$(jq -nc --arg u "http://$2:$3" --arg k "$(xml_key "$2")" '{prowlarrUrl:"http://prowlarr:9696", baseUrl:$u, apiKey:$k}')" \
    '.syncLevel="fullSync"'
done
arr prowlarr v1 "$PK" POST /command '{"name":"ApplicationIndexerSync"}' >/dev/null

# ---------------------------------------------------------------- Bazarr
BZ=$(app_url bazarr)
BK=$(sed -n '/^auth:/,/^[a-z]/s/^  apikey: //p' "$CONFIG_DIR/bazarr/config/config.yaml")
wait_http "$BZ/api/system/status?apikey=$BK"
log "bazarr: Sonarr, Radarr, legendas pt-BR + en, provedores"
PROFILE='[{"profileId":1,"name":"Português (BR) + Inglês","cutoff":null,"mustContain":[],"mustNotContain":[],"originalFormat":null,
  "items":[{"id":1,"language":"pb","audio_exclude":"False","audio_only_include":"False","hi":"False","forced":"False"},
           {"id":2,"language":"en","audio_exclude":"False","audio_only_include":"False","hi":"False","forced":"False"}]}]'
curl -sf -X POST -H "X-API-KEY: $BK" "$BZ/api/system/settings" \
  -d languages-enabled=pb -d languages-enabled=en --data-urlencode "languages-profiles=$PROFILE" \
  -d settings-general-use_sonarr=true -d settings-general-use_radarr=true \
  -d settings-sonarr-ip=sonarr -d settings-sonarr-port=8989 --data-urlencode "settings-sonarr-apikey=$(xml_key sonarr)" \
  -d settings-radarr-ip=radarr -d settings-radarr-port=7878 --data-urlencode "settings-radarr-apikey=$(xml_key radarr)" \
  -d settings-general-serie_default_enabled=true -d settings-general-serie_default_profile=1 \
  -d settings-general-movie_default_enabled=true -d settings-general-movie_default_profile=1 \
  -d settings-general-enabled_providers=embeddedsubtitles -d settings-general-enabled_providers=gestdown \
  -d settings-general-enabled_providers=yifysubtitles

# ---------------------------------------------------------------- Seerr (pedidos)
SR=http://127.0.0.1:5055/api/v1
SJAR=$(mktemp)
wait_http $SR/status
if [ "$(curl -s $SR/settings/public | jq -r .initialized)" != true ]; then
  log "seerr: Jellyfin, bibliotecas, Radarr, Sonarr, pt-BR, usuário $JELLYFIN_USER"
  sr() { curl -sf -b "$SJAR" -c "$SJAR" -H 'Content-Type: application/json' "$@"; }
  sr -X POST $SR/auth/jellyfin -d "$(jq -nc --arg p "$JELLYFIN_ADMIN_PASS" '{username:"admin", password:$p,
    hostname:"jellyfin", port:8096, useSsl:false, urlBase:"", email:"admin@media.lan", serverType:2}')" >/dev/null
  for id in $(sr -X POST $SR/settings/jellyfin/library/sync | jq -r '.[].id'); do
    sr -X PUT $SR/settings/jellyfin/library/$id -d '{"enabled":true}' >/dev/null
  done
  for a in "radarr 7878 /data/media/movies" "sonarr 8989 /data/media/tv"; do
    set -- $a
    q=$(arr "$1" v3 "$(xml_key "$1")" GET /qualityprofile | jq -c '[.[] | select(.name=="Dual áudio (dublado + legendado)")][0] | {id,name}')
    sr -X POST $SR/settings/$1 -d "$(jq -nc --arg n "$1" --argjson p "$2" --arg d "$3" --arg k "$(xml_key "$1")" --argjson q "$q" '{
      name:($n|ascii_upcase[0:1] + $n[1:]), hostname:$n, port:$p, apiKey:$k, useSsl:false, baseUrl:"",
      activeProfileId:$q.id, activeProfileName:$q.name, activeDirectory:$d,
      activeAnimeProfileId:$q.id, activeAnimeProfileName:$q.name, activeAnimeDirectory:$d, activeLanguageProfileId:1,
      minimumAvailability:"released", enableSeasonFolders:true, is4k:false, isDefault:true,
      externalUrl:("http://" + $n + ".lan"), syncEnabled:true, preventSearch:false, tags:[], animeTags:[]}')" >/dev/null
  done
  sr -X POST $SR/settings/main -d '{"applicationTitle":"Pedidos","applicationUrl":"http://seerr.lan","locale":"pt-BR","discoverRegion":"BR","streamingRegion":"BR","originalLanguage":""}' >/dev/null
  sr -X POST $SR/settings/initialize >/dev/null
  jfid=$(sr $SR/settings/jellyfin/users | jq -r --arg u "$JELLYFIN_USER" '.[] | select(.username==$u) | .id')
  sr -X POST $SR/user/import-from-jellyfin -d "{\"jellyfinUserIds\":[\"$jfid\"]}" >/dev/null
  uid=$(sr "$SR/user?take=50" | jq --arg u "$JELLYFIN_USER" '.results[] | select(.jellyfinUsername==$u) | .id')
  sr -X PUT $SR/user/$uid -d '{"permissions":2}' >/dev/null   # admin: pedidos aprovados na hora
fi
rm -f "$SJAR"

# ---------------------------------------------------------------- DNS .lan (Tailscale)
# *.lan -> IP do Mac na tailnet (dns/Corefile). O Split DNS "lan" é cadastrado uma vez no painel do Tailscale.
if command -v tailscale >/dev/null && ip=$(tailscale ip -4 2>/dev/null) && [ -n "$ip" ]; then
  if [ "$ip" != "${TS_IP:-}" ]; then
    sedi '/^TS_IP=/d' .env; echo "TS_IP=$ip" >>.env
    docker compose up -d --force-recreate dns >/dev/null 2>&1
  fi
  log "dns: *.lan -> $ip"
fi
log "Pronto: http://media.lan (Tailscale ligado) | reserva sem Tailscale em casa: http://media.local"
