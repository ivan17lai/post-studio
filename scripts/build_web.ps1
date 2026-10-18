param([switch]$RebuildHdr)
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()
$root = (Resolve-Path "$PSScriptRoot/..").Path
Push-Location $root
try {
  if ($RebuildHdr) { & "$PSScriptRoot/build_hdr_web.ps1"; if ($LASTEXITCODE -ne 0) { throw 'HDR build failed' } }
  if (!(Test-Path -LiteralPath 'web/hdr/poststudio_hdr.wasm')) { throw 'Build HDR first with scripts/build_hdr_web.ps1' }
  flutter build web --release --base-href /igapp/
  if ($LASTEXITCODE -ne 0) { throw 'Flutter build failed' }
  python -X utf8 "$PSScriptRoot/prepare_pwa.py"
  if ($LASTEXITCODE -ne 0) { throw 'PWA asset generation failed' }
} finally { Pop-Location }
