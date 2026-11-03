# Status window of quiet_run.ps1, opened by it in a window of its own. Refreshes every 2 s. Keys:
#   q  abort the benchmark and restore the settings (asks y to confirm)
# State comes from benchmark\results\local\.quiet\{state,log,session,start,args,abort}, written by
# quiet_run.ps1. Closing this window stops nothing.
. (Join-Path $PSScriptRoot 'common.ps1')
$RUN = if ($env:RISTRETTO_QUIET_DIR) { $env:RISTRETTO_QUIET_DIR } else { Join-Path $REPO_ROOT 'benchmark\results\local\.quiet' }
$INTERVAL = 2
$host.UI.RawUI.WindowTitle = 'Ristretto quiet benchmark'
function Read-State([string]$name) { $f = Join-Path $RUN $name; if (Test-Path -LiteralPath $f) { (Get-Content -LiteralPath $f -Raw).Trim() } else { '' } }
function Request-Abort { New-Item -ItemType File -Force -Path (Join-Path $RUN 'abort') | Out-Null }
function Cut([string]$s, [int]$n) { if ($s.Length -gt $n) { $s.Substring(0, $n) } else { $s } }
[Console]::TreatControlCAsInput = $true   # Ctrl+C here means abort, not "close the status window"

$confirm = $false
$endedAt = $null
while ($true) {
    $state = Read-State 'state'
    $start = 0; [void][long]::TryParse((Read-State 'start'), [ref]$start)
    if ($start -eq 0) { $start = [DateTimeOffset]::Now.ToUnixTimeSeconds() }
    $cols = [Math]::Max(40, $host.UI.RawUI.WindowSize.Width - 1)
    $clock = Get-CpuClock
    $temp = Get-MaxTemp
    $os = Get-CimInstance Win32_OperatingSystem
    $lines = @(
        "=== Ristretto quiet benchmark ===   $(Get-Date -Format HH:mm:ss)   elapsed $([int](([DateTimeOffset]::Now.ToUnixTimeSeconds() - $start) / 60)) min"
        "state     : $(if ($state) { $state } else { '?' })"
        "frequency : $(if ($clock) { "$($clock.MHz) MHz avg, performance limit $($clock.Limit) %" } else { 'n/a' })    temp: $(if ($null -ne $temp) { "$temp C" } else { 'n/a' })"
        "load      : $(if ($clock) { "$($clock.Load) %" } else { 'n/a' })    mem: $([int](($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1024)) / $([int]($os.TotalVisibleMemorySize / 1024)) MB used"
        "args      : $(Read-State 'args')"
        '---'
    )
    $session = Read-State 'session'
    if ($session) { $lines += @(& (Join-Path $PSScriptRoot 'units_report.ps1') $session brief 2>$null) }
    $lines += '---'
    if ($session -and (Test-Path -LiteralPath $session)) {
        $runlog = Get-ChildItem -LiteralPath $session -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($runlog) {
            $lines += $runlog.FullName
            # progress meters rewrite their line with CR: split on it, as the bash version does
            $text = try { [IO.File]::ReadAllText($runlog.FullName) } catch { '' }
            $lines += @($text -split "[`r`n]+" | Where-Object { $_.Trim() } | Select-Object -Last 6)
        }
    }
    $lines += '---'
    $qlog = Read-State 'log'
    if ($qlog -and (Test-Path -LiteralPath $qlog)) { $lines += @(Get-Content -LiteralPath $qlog -Tail 4) }
    $lines += ''
    if ($state -like 'done*' -or $state -like 'aborted*') {
        $lines += 'Finished: settings are being restored. This window closes on its own.'
        if (-not $endedAt) { $endedAt = Get-Date }
    } elseif ($confirm) { $lines += '>>> ABORT the benchmark and restore the settings?  y = yes, any other key = no' }
    else { $lines += '[q] abort benchmark and restore the settings' }
    if (Test-Path -LiteralPath (Join-Path $RUN 'abort')) { $lines += 'abort requested...' }

    Clear-Host
    foreach ($l in $lines) { Write-Host (Cut "$l" $cols) }
    if ($endedAt -and ((Get-Date) - $endedAt).TotalSeconds -gt 10) { exit 0 }

    $deadline = (Get-Date).AddSeconds($INTERVAL)
    while ((Get-Date) -lt $deadline) {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            $ctrlC = $k.Key -eq 'C' -and ($k.Modifiers -band [ConsoleModifiers]::Control)
            if ($ctrlC) { Request-Abort }
            elseif ($confirm) { if ($k.KeyChar -eq 'y') { Request-Abort }; $confirm = $false }
            elseif ($k.KeyChar -eq 'q') { $confirm = $true }
            break
        }
        Start-Sleep -Milliseconds 100
    }
}
