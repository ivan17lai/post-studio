param(
  [string]$Emsdk = "$PSScriptRoot/../work/toolchains/emsdk-4.0.15",
  [string]$Ninja = "$env:LOCALAPPDATA/Android/sdk/cmake/3.22.1/bin/ninja.exe"
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$root = (Resolve-Path "$PSScriptRoot/..").Path
$toolchain = (Resolve-Path $Emsdk).Path
$env:EMSDK = $toolchain
$env:EM_CONFIG = "$toolchain/.emscripten"
$env:PATH = "$toolchain/upstream/emscripten;$env:PATH"
& "$toolchain/upstream/emscripten/emcmake.bat" cmake -S "$root/native" -B "$root/build/hdr-web" -G Ninja "-DCMAKE_MAKE_PROGRAM=$Ninja" -DCMAKE_BUILD_TYPE=Release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
cmake --build "$root/build/hdr-web" --target poststudio_hdr -j 4
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
New-Item -ItemType Directory -Path "$root/web/hdr" -Force | Out-Null
Copy-Item -LiteralPath "$root/build/hdr-web/poststudio_hdr.mjs" -Destination "$root/web/hdr/poststudio_hdr.mjs"
Copy-Item -LiteralPath "$root/build/hdr-web/poststudio_hdr.wasm" -Destination "$root/web/hdr/poststudio_hdr.wasm"
