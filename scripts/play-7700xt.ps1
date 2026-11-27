# Profile for a Ryzen 5 5600X (6 cores / 12 threads), 32 GB RAM, RX 7700 XT (12 GB).
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\play-7700xt.ps1 -Exe <game_scarlett_master.exe>
# Same settings as play.ps1, plus:
#   - renderer patches CONSTANTS, DESCRIPTORS, GUARD, JOURNAL (PORT_CBV left out: it changes the shader
#     cache key, so every shader and pipeline is made again and the picture stays black for minutes)
#   - native 1080p: the Series X profile drawn at 1920x1080 (output 1920x1080, render scale 1.0). Both
#     consoles' profiles otherwise draw at 2/3 of their output (Series S: 1280x720 for 1080p), which made
#     the picture soft; the frame rate is set by the CPU, so drawing 2.25x the pixels costs next to nothing
#   - the stand-in for the ray-traced indirect light at full strength, and the air of rooms bounded by the
#     light around (without rays it holds the sky's light indoors: a brown veil at sunset)
#   - fewer helper threads than the defaults, which were set for a 24-thread i9-12900K
#   - title buffers of 1 MiB and more kept in the card's memory, where the card itself finds what its
#     shaders wrote. On the console's APU CPU and GPU share memory; here a buffer left in the PC's
#     memory is snapshotted and compared on the CPU after each submission (230 MB a frame, about
#     21 ms of the submitting thread on this CPU). The default on cards of 12 GB or less is 16 MiB.
# -Stock       keep the default thread counts and card buffer limits (to compare)
# -SeriesS     the Series S profile instead (1080p output drawn at 720p by FidelityFX; -Output and
#              -RenderScale do not apply); -SeriesX is the default and is accepted for older command lines
# -Build       release (default: no diagnostics, less CPU) or diag (logs every cost, for measuring)
# -CardMinMB   smallest title buffer kept in card memory (default 1)
# -CardMB      most MB of title buffers in card memory (default 1024)
# -Log         also write the output to this file
# -Output      output size the title renders to itself (default 1920x1080; one of 1280x720, 1664x936,
#              1920x1080, 2560x1440, 3840x2160)
# -RenderScale the title's own upscaler's scale, 0.5 to 1.0 (default 1.0 = native; the title's is 2/3)
# -Ambient     share of the stand-in for the ray-traced indirect light (default 1.0 = all of it)
# -AmbientAir  bound on what the air of a room scatters, as a multiple of the light around (default 1.0;
#              0 = the title's own)
# -Profile     VICTORY_PROFILE=<from s>,<to s>,<ms>,<file>: samples the busiest threads' stacks (diag build)
# -ThinThreads threads translating the title's list calls (default 8)
# -BarMB       MB of console windows put in card memory the CPU writes directly (Resizable BAR / SAM must be on;
#              measured: no gain on this PC)
param(
    [Parameter(Mandatory)][string]$Exe,
    [switch]$Stock,
    [switch]$SeriesS,
    [switch]$SeriesX,
    [ValidateSet('release', 'diag')][string]$Build = 'release',
    [int]$CardMinMB = 1,
    [int]$CardMB = 1024,
    [int]$BarMB = 0,
    [int]$ThinThreads = 8,
    [string]$Output = '1920x1080',
    [string]$RenderScale = '1.0',
    [string]$Ambient = '1.0',
    [string]$AmbientAir = '1.0',
    [string]$Profile = '',
    [string]$Log,
    [hashtable]$More = @{}
)
$settings = @{
    VICTORY_TEXTURE_NO_WAIT = '1'; VICTORY_RELAY = '2'; VICTORY_WIDE_BACK = '1'; VICTORY_CARD_REHASH_RUNS = '1'
    VICTORY_JOIN_COPIES = '1'; VICTORY_INDIRECT_WINDOW = '1'; VICTORY_RELAY_COPY = '1'; VICTORY_CARD_STEPS = '2'
    VICTORY_INDIRECT_BATCH = '2'; VICTORY_MAP_THREADS = '1'; VICTORY_TITLE_PRIORITIES = '0'; VICTORY_CARD_AWAKE = '1'
    VICTORY_SHOW_AFTER = '1'; VICTORY_AMBIENT = '0.8'; VICTORY_D3D12_DRED = 'light'
    VICTORY_THIN = '1'; VICTORY_JOIN_PARTS = '8'; VICTORY_UPLOAD_AHEAD = '1'
    VICTORY_PORT_CONSTANTS = '1'; VICTORY_PORT_DESCRIPTORS = '1'; VICTORY_PORT_GUARD = '1'; VICTORY_PORT_JOURNAL = '1'
    # Every pipeline the title creates is written down, so `victory warm` can make them ahead of a run.
    VICTORY_PIPELINE_BOOK = '1'
}
if (-not $Stock) {
    # Defaults: THIN 8, UNDER 6, VIEW 6, LAND 3. The list calls' translation (THIN) is the wall once the
    # buffers are on the card (41,000 calls, ~280 ms of work a frame): it keeps its 8 threads.
    $settings.VICTORY_THIN_THREADS = "$ThinThreads"
    $settings.VICTORY_UNDER_THREADS = '4'
    $settings.VICTORY_VIEW_THREADS = '4'
    $settings.VICTORY_LAND_THREADS = '2'
    $settings.VICTORY_CARD_BUFFERS_MIN_MB = "$CardMinMB"
    $settings.VICTORY_CARD_BUFFERS_MB = "$CardMB"
    # Textures leave room for those buffers (they are made in one burst as the world loads).
    $settings.VICTORY_CARD_ROOM_FOR_BUFFERS = '1'
}
if ($BarMB -gt 0) { $settings.VICTORY_WINDOWS_BAR_MB = "$BarMB" }
if (-not $SeriesS) {
    if ($Output) { $settings.VICTORY_OUTPUT = $Output }
    if ($RenderScale) { $settings.VICTORY_RENDER_SCALE = $RenderScale }
}
$settings.VICTORY_AMBIENT = $Ambient
if ($AmbientAir -and $AmbientAir -ne '0') { $settings.VICTORY_AMBIENT_AIR = $AmbientAir }
if ($Profile) { $settings.VICTORY_PROFILE = $Profile }
# Thousands of log lines a second (frame statistics, renderer port 2's warnings) cost the threads that
# write them: only errors, unless the run is a measurement (-Log, or the diag build).
if (-not $Log -and $Build -eq 'release') { $settings.VICTORY_LOG = 'error' }
if ($Profile) { $settings.VICTORY_LOG = 'error' }   # the profile shows the port's costs, not the log's
foreach ($k in $More.Keys) { $settings[$k] = $More[$k] }

$root = Join-Path $PSScriptRoot '..'
$victory = Join-Path $root "target\$Build\victory.exe"
if (-not (Test-Path $victory)) { Write-Host "No $victory. Build it first (README.md)."; exit 1 }
if (-not (Test-Path $Exe)) { Write-Host "No $Exe."; exit 1 }
$paths = 'VICTORY_CONFIG', 'VICTORY_GAME_DIR', 'VICTORY_CACHE_DIR', 'VICTORY_DATA_DIR'
Get-ChildItem Env:VICTORY_* | Where-Object { $_.Name -notin $paths } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
foreach ($k in $settings.Keys) { Set-Item "Env:$k" $settings[$k] }
$Exe = (Resolve-Path $Exe).Path
$console = if ($SeriesS) { 'series-s' } else { 'series-x' }
Push-Location $root
try {
    if ($Log) { & $victory run $Exe --execute --console $console *>&1 | Tee-Object -FilePath $Log }
    else { & $victory run $Exe --execute --console $console }
} finally { Pop-Location }
