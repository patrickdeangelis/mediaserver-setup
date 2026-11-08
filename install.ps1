# Instala o media server no Windows 10/11 (Docker Desktop + WSL2).
#   PowerShell:  irm https://raw.githubusercontent.com/patrickdeangelis/mediaserver-setup/main/install.ps1 | iex
# Os scripts rodam dentro do WSL2 (sistema de arquivos Linux: rápido e com hardlinks).
$ErrorActionPreference = 'Stop'
$repo = 'https://github.com/patrickdeangelis/mediaserver-setup.git'

if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) { throw 'WSL não encontrado. Rode "wsl --install" num PowerShell admin, reinicie e execute de novo.' }
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Write-Host 'Instalando Docker Desktop...'
  winget install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements
  throw 'Abra o Docker Desktop, ative Settings > Resources > WSL integration para sua distro e rode este script de novo.'
}
docker info *> $null
if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop não está rodando. Abra-o e tente de novo.' }

wsl -e bash -lc "command -v git >/dev/null && command -v jq >/dev/null && command -v curl >/dev/null || (sudo apt-get update && sudo apt-get install -y git jq curl)"
wsl -e bash -lc "docker info >/dev/null 2>&1" ; if ($LASTEXITCODE -ne 0) { throw 'Habilite a integração WSL no Docker Desktop (Settings > Resources > WSL integration).' }
wsl -e bash -lc "[ -d ~/mediaserver/.git ] && git -C ~/mediaserver pull || git clone $repo ~/mediaserver"
wsl -e bash -lc "cd ~/mediaserver && ./install.sh"
Write-Host "`nPronto: http://localhost  (Jellyfin http://localhost:8096, Pedidos http://localhost:5055)"
Start-Process 'http://localhost'
