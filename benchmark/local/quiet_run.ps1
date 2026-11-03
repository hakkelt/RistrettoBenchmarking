# Windows counterpart of quiet_run.sh: a quieter machine for benchmark\local\run_comparison.ps1.
# Windows cannot stop the desktop session or switch SMT at runtime, so this does what it can, as
# administrator (it asks for elevation once, through UAC), and puts everything back afterwards:
#   1. stops the non-essential services that wake up on their own (Windows Search, SysMain, Windows
#      Update, BITS, Delivery Optimization, telemetry, the print spooler, ...); each is started again
#      at the end only if it was running before. Windows Defender is left alone: exclude the
#      repository, the Julia depot and the data cache from real-time scanning yourself if you want
#      file loading out of the timings.
#   2. fixes the CPU through a temporary power scheme (a copy of the active one): minimum and maximum
#      processor state 100 % (no frequency hunting), turbo off (thermal-limited machines drift with the
#      heat), core parking off. The original scheme is reactivated and the copy deleted at the end.
#   3. opens a status window (quiet_status.ps1: clock, performance limit, temperature where Windows
#      exposes it, load, unit list, the benchmark's own log, refreshed every 2 s)
#   4. runs run_comparison.ps1 above normal priority, with the arguments given here
#   5. whatever happens (finish, abort, failure, Ctrl+C), restores every setting.
#
# Abort at any time: press q (then y) in the status window, or Ctrl+C in the benchmark window. From
# elsewhere: create the file benchmark\results\local\.quiet\abort. Closing the benchmark window with
# its X button skips the restore: run `quiet_run.ps1 --restore` afterwards (it reads what was changed
# from benchmark\results\local\.quiet\saved.json).
#
# SMT: Windows has no runtime switch, so "SMT off" is what run_comparison.ps1 does anyway: one logical
# CPU per physical core, the sibling left idle. Thread counts up to the number of physical cores run
# that way; counts above it run with `run_comparison.ps1 --smt`, on the siblings too. The default counts
# are 1, 2, 4, ... up to the logical CPU count. --smt-mode=off drops the counts above the physical
# cores; on and auto are the same here. --threads=LIST overrides the counts.
#
# Resume: every run is a session (benchmark\results\local\session_<stamp>\) with a unit list, units.tsv.
# `--resume` continues the newest session with the arguments it was started with: done units are
# skipped, failed and interrupted ones run again. `--resume=DIR` names a session. Print the list any time:
#   powershell -File benchmark\local\units_report.ps1 benchmark\results\local\session_<stamp>
#
# usage:   powershell -ExecutionPolicy Bypass -File benchmark\local\quiet_run.ps1 [--resume[=DIR]]
#              [--smt-mode=auto|on|off] [--threads=LIST] [--cooldown=SEC] [--cooldown-temp=C]
#              [--dry-run] [--restore] [run_comparison.ps1 flags...]
#   e.g.   ... quiet_run.ps1 --threads=1,2 --backends=openblas
#   --dry-run   print what would be changed and run, change nothing (no elevation needed)
#   --restore   undo the changes of a run whose window was closed before it could restore them
# Save your work first: services are stopped while the benchmark runs.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

# Stopped for the run, started again afterwards if they were running before. Missing ones are skipped.
$NOISY = @('WSearch', 'SysMain', 'wuauserv', 'UsoSvc', 'BITS', 'DoSvc', 'DiagTrack', 'dmwappushservice',
    'Spooler', 'MapsBroker', 'lfsvc', 'WerSvc', 'PcaSvc', 'TabletInputService', 'XblAuthManager', 'XblGameSave')
$LOCAL_DIR = Join-Path $REPO_ROOT 'benchmark\results\local'
$RUN = Join-Path $LOCAL_DIR '.quiet'
$SAVED = Join-Path $RUN 'saved.json'
$argv = ConvertTo-FlagList $args

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Start-Elevated([string[]]$scriptArgs) {
    $q = ($scriptArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $q"
}

# ---- restore: also the --restore entry point --------------------------------------------------------
function Restore-Settings {
    if (-not (Test-Path -LiteralPath $SAVED)) { Write-Output '### nothing to restore'; return }
    $s = Get-Content -LiteralPath $SAVED -Raw | ConvertFrom-Json
    Write-Output "### restoring $(Get-Date -Format o)"
    if ($s.Scheme) {
        & powercfg.exe /setactive $s.Scheme | Out-Null
        Write-Output "### power scheme $($s.Scheme) active again"
    }
    if ($s.TempScheme) { & powercfg.exe /delete $s.TempScheme 2>&1 | Out-Null }
    foreach ($n in @($s.Stopped)) {
        if (-not $n) { continue }
        try { Start-Service -Name $n -ErrorAction Stop; Write-Output "### started $n" }
        catch { Write-Output "### could not start ${n}: $($_.Exception.Message)" }
    }
    Remove-Item -LiteralPath $SAVED -Force
    Write-Output "### restored $(Get-Date -Format o)"
}
function Save-State($s) { $s | ConvertTo-Json | Set-Content -LiteralPath $SAVED -Encoding UTF8 }

if ($argv -contains '--restore') {
    if (-not (Test-Admin)) { Start-Elevated @('--restore'); exit 0 }
    Restore-Settings
    Read-Host 'press Enter to close' | Out-Null
    exit 0
}

if ($argv.Count -eq 0 -or $argv[0] -ne '--inner') {
    # ---- outer: the user's shell ------------------------------------------------------------------
    $RESUME = ''; $DRY = $false; $ARGV2 = @()
    foreach ($a in $argv) {
        if ($a -eq '--resume') { $RESUME = 'latest' }
        elseif ($a -match '^--resume=(.*)$') { $RESUME = $Matches[1] }
        elseif ($a -eq '--dry-run') { $DRY = $true }
        else { $ARGV2 += $a }
    }
    if (Test-Path -LiteralPath $SAVED) {
        [Console]::Error.WriteLine("### $SAVED exists: a quiet run is going on, or one ended without restoring (then run quiet_run.ps1 --restore)")
        exit 1
    }
    New-Item -ItemType Directory -Force -Path $LOCAL_DIR | Out-Null
    if ($RESUME) {
        # continue a session: it keeps the arguments of the first run, so the unit list matches
        $SESSION = if ($RESUME -eq 'latest') {
            Get-ChildItem -LiteralPath $LOCAL_DIR -Directory -Filter 'session_*' | Sort-Object LastWriteTime -Descending |
                Where-Object { Test-Path (Join-Path $_.FullName 'quiet_args.txt') } | Select-Object -First 1 -ExpandProperty FullName
        } else { [IO.Path]::GetFullPath($RESUME) }
        if (-not $SESSION -or -not (Test-Path (Join-Path $SESSION 'quiet_args.txt'))) {
            [Console]::Error.WriteLine("no session to resume (looked in $LOCAL_DIR\session_*)"); exit 1
        }
        if ($ARGV2.Count) { Write-Output "note: arguments are taken from the session; ignoring: $($ARGV2 -join ' ')" }
        $RESUME_FLAG = '1'
        Write-Output "Resuming $SESSION"
        & (Join-Path $PSScriptRoot 'units_report.ps1') $SESSION
    } else {
        $SESSION = Join-Path $LOCAL_DIR ('session_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
        if (-not $DRY) {
            New-Item -ItemType Directory -Force -Path $SESSION | Out-Null
            Write-Lines (Join-Path $SESSION 'quiet_args.txt') $ARGV2
        }
        $RESUME_FLAG = '0'
    }
    $LOG = Join-Path $LOCAL_DIR ('quiet_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
    # The elevated half grants this account write access to what it creates (see Grant-ResultAccess);
    # passed as a SID, since the elevated account may be another one (an administrator's credentials).
    $USER_SID = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $inner = @('--inner', $SESSION, $LOG, $RESUME_FLAG, $USER_SID)
    if ($DRY) {
        # the arguments of a new session are not on disk in a dry run: hand them over directly
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @($inner + '--dry-run' + $ARGV2)
        exit $LASTEXITCODE
    }
    Write-Output "Stopping background services and fixing the CPU clock (asks for elevation). Log: $LOG, session: $SESSION"
    Write-Output 'A status window will open; q (then y) there aborts and restores everything.'
    Write-Output "Continue later with: $PSCommandPath --resume"
    Start-Elevated $inner
    exit 0
}

# ---- inner: elevated --------------------------------------------------------------------------------
$SESSION = $argv[1]; $BENCH_LOG = $argv[2]; $RESUME_FLAG = $argv[3]; $USER_SID = $argv[4]
$rest = @($argv | Select-Object -Skip 5)
$DRY = $rest -contains '--dry-run'
$rest = @($rest | Where-Object { $_ -ne '--dry-run' })
if (-not $DRY) {
    if (-not (Test-Admin)) { [Console]::Error.WriteLine('### --inner needs administrator rights'); exit 1 }
    $rest = @(Get-Content -LiteralPath (Join-Path $SESSION 'quiet_args.txt') | Where-Object { $_ -ne '' })
}
$SMT_MODE = 'auto'; $COOLDOWN = 30; $COOL_TEMP = 50; $THREADS_ARG = ''; $ARGS2 = @()
foreach ($a in $rest) {
    switch -Regex ($a) {
        '^--smt-mode=(.*)$' { $SMT_MODE = $Matches[1]; break }
        '^--smt-off$' { $SMT_MODE = 'off'; break }
        '^--threads=(.*)$' { $THREADS_ARG = $Matches[1]; break }
        '^--cooldown=(.*)$' { $COOLDOWN = [int]$Matches[1]; break }
        '^--cooldown-temp=(.*)$' { $COOL_TEMP = [int]$Matches[1]; break }
        default { $ARGS2 += $a }
    }
}
if ($SMT_MODE -notin 'auto', 'on', 'off') { [Console]::Error.WriteLine('### --smt-mode must be auto, on or off'); exit 1 }

function Log([string]$s) { Write-Host $s; if (-not $DRY) { Add-Content -LiteralPath $BENCH_LOG -Value $s } }
function State([string]$s) { if (-not $DRY) { Set-Content -LiteralPath (Join-Path $RUN 'state') -Value $s }; Log "### state: $s ($(Get-Date -Format HH:mm:ss))" }
function Invoke-Step([string]$what, [scriptblock]$action) { if ($DRY) { Write-Host "would: $what" } else { & $action } }

$topo = Get-CpuTopology
$N_PHYS = $topo.Phys.Count; $N_LOGICAL = $topo.All.Count
if ($THREADS_ARG) { $TLIST = @($THREADS_ARG.Split(',') | ForEach-Object { [int]$_ }) }
else {
    $TLIST = @(); for ($t = 1; $t -le $N_LOGICAL; $t *= 2) { $TLIST += $t }
    if ($TLIST[-1] -ne $N_LOGICAL) { $TLIST += $N_LOGICAL }
}
$LOW = @(); $HIGH = @()
foreach ($t in $TLIST) {
    if ($t -le $N_PHYS) { $LOW += $t }
    elseif ($SMT_MODE -eq 'off') { Log "### dropping $t threads: more than the $N_PHYS physical cores and --smt-mode=off" }
    else { $HIGH += $t }
}

# Everything below runs elevated, so the logs, the unit list and the result files it creates belong to
# Administrators and inherit only what their directory grants; under a drive root such as D:\ that is
# read-only for Users, and the account that started the run could not edit or delete its own results.
# Modify for that account on both trees, inherited by new files and applied to the existing ones.
function Grant-ResultAccess([string]$sid) {
    if (-not $sid) { return }
    foreach ($d in @($LOCAL_DIR, (Join-Path $REPO_ROOT 'benchmark\comparison\results\runs'))) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        & icacls.exe $d /grant "*${sid}:(OI)(CI)M" /T /C /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { Log "### could not grant write access on $d (icacls exit $LASTEXITCODE)" }
    }
}

if (-not $DRY) {
    New-Item -ItemType Directory -Force -Path $RUN | Out-Null
    Grant-ResultAccess $USER_SID
    Remove-Item -LiteralPath (Join-Path $RUN 'abort') -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath (Join-Path $RUN 'log') -Value $BENCH_LOG
    Set-Content -LiteralPath (Join-Path $RUN 'session') -Value $SESSION
    Set-Content -LiteralPath (Join-Path $RUN 'start') -Value ([DateTimeOffset]::Now.ToUnixTimeSeconds())
    Set-Content -LiteralPath (Join-Path $RUN 'args') -Value $(if ($rest.Count) { $rest -join ' ' } else { '<defaults>' })
}
Log "### quiet_run start $(Get-Date -Format o), user $env:USERNAME, cores $N_PHYS, logical $N_LOGICAL$(if ($DRY) { ' (dry run)' })"
# Before any setting changes: without SigPy every unit would fail (run_comparison.ps1 checks it too).
Import-SiteEnv
$pyErr = Test-BenchPython
if ($pyErr) {
    Log "### $pyErr; nothing changed"
    if (-not $DRY) { Set-Content -LiteralPath (Join-Path $RUN 'state') -Value "failed: $pyErr"; Read-Host 'Press Enter to close this window' | Out-Null }
    exit 1
}
$abortFile = Join-Path $RUN 'abort'
function Test-Abort { (-not $DRY) -and (Test-Path -LiteralPath $abortFile) }

$state = @{ Scheme = $null; TempScheme = $null; Stopped = @() }
$status = $null
try {
    # 1. background services ---------------------------------------------------------------------
    State 'stopping background services'
    foreach ($n in $NOISY) {
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        if (-not $svc -or $svc.Status -ne 'Running') { continue }
        Invoke-Step "stop service $n ($($svc.DisplayName))" {
            try {
                Stop-Service -Name $n -Force -ErrorAction Stop
                $state.Stopped += $n; Save-State $state
            } catch { Log "### could not stop ${n}: $($_.Exception.Message)" }
        }
    }
    Log "### stopped: $($state.Stopped -join ' ')"

    # 2. performance profile: a temporary copy of the active power scheme ------------------------
    State 'setting performance profile'
    $active = [regex]::Match((& powercfg.exe /getactivescheme) -join ' ', '[0-9a-fA-F-]{36}').Value
    Invoke-Step "copy power scheme $active, set processor state 100 %/100 %, turbo off, core parking off, activate the copy" {
        $state.Scheme = $active; Save-State $state
        $copy = [regex]::Match((& powercfg.exe /duplicatescheme $active) -join ' ', '[0-9a-fA-F-]{36}').Value
        $state.TempScheme = $copy; Save-State $state
        & powercfg.exe /changename $copy 'Ristretto quiet benchmark' 'temporary, deleted by quiet_run.ps1' | Out-Null
        # PERFBOOSTMODE 0 = turbo disabled; CPMINCORES 100 = no core parking
        foreach ($kv in @(@('PROCTHROTTLEMIN', 100), @('PROCTHROTTLEMAX', 100), @('PERFBOOSTMODE', 0), @('CPMINCORES', 100))) {
            foreach ($mode in '/setacvalueindex', '/setdcvalueindex') {
                & powercfg.exe $mode $copy SUB_PROCESSOR $kv[0] $kv[1] 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { Log "### could not set $($kv[0]) ($mode)" }
            }
        }
        & powercfg.exe /setactive $copy | Out-Null
    }
    $clock = Get-CpuClock
    Log "### power scheme: $((& powercfg.exe /getactivescheme) -join ' '); clock $(if ($clock) { "$($clock.MHz) MHz, limit $($clock.Limit) %" } else { 'n/a' })"
    Log "### physical-core counts: $(if ($LOW.Count) { $LOW -join ' ' } else { 'none' }); SMT counts: $(if ($HIGH.Count) { $HIGH -join ' ' } else { 'none' })"

    # 3. status window ------------------------------------------------------------------------------
    Invoke-Step 'open the status window (quiet_status.ps1)' {
        $script:status = Start-Process powershell.exe -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'quiet_status.ps1')`""
    }

    # 4. benchmark groups ---------------------------------------------------------------------------
    $runner = Join-Path $PSScriptRoot 'run_comparison.ps1'
    $resumeArg = @(); if ($RESUME_FLAG -eq '1') { $resumeArg = @('--resume') }
    $env:RISTRETTO_QUIET_DIR = $RUN
    function Get-GroupArgs([string]$g) {
        if ($g -eq 'low') { @("--threads=$($LOW -join ',')") } else { @("--threads=$($HIGH -join ',')", '--smt') }
    }
    # Write every group's units into the session's unit list up front, so the status screen can show
    # what is left; a group with nothing left to run (everything done in an earlier run) is skipped.
    $groups = @()
    foreach ($g in @(@('low', $LOW), @('high', $HIGH))) {
        if ($g[1].Count -eq 0) { continue }
        if ($DRY) { $groups += $g[0]; continue }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner --plan-only "--session=$SESSION" @(Get-GroupArgs $g[0]) @ARGS2 @resumeArg | Out-Null
        if ($LASTEXITCODE -ne 10) { $groups += $g[0] }
    }
    Log "### session $SESSION (resume: $RESUME_FLAG), groups: $($groups -join ' ')"

    $first = $true
    foreach ($g in $groups) {
        if (Test-Abort) { break }
        if (-not $first) {   # cooldown between groups only, as run_comparison.ps1 does between runs
            State 'cooldown between groups'
            for ($i = 0; $i -lt $COOLDOWN -and -not (Test-Abort) -and -not $DRY; $i++) { Start-Sleep -Seconds 1 }
            $waited = 0
            while (-not $DRY -and $null -ne (Get-MaxTemp) -and (Get-MaxTemp) -gt $COOL_TEMP -and $waited -lt 900 -and -not (Test-Abort)) {
                Start-Sleep -Seconds 5; $waited += 5
            }
        }
        $first = $false
        $gargs = @(Get-GroupArgs $g) + @("--cooldown=$COOLDOWN", "--cooldown-temp=$COOL_TEMP", "--session=$SESSION", '--priority=abovenormal') + $ARGS2 + $resumeArg
        State "running benchmark: group $g ($($gargs[0]))"
        Invoke-Step "run run_comparison.ps1 $($gargs -join ' ')" {
            $ErrorActionPreference = 'Continue'
            # Log, not Tee-Object: PowerShell 5.1's Tee-Object -Append writes UTF-16 into the ANSI log
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner @gargs 2>&1 | ForEach-Object { Log "$_" }
            Log "### group $g exit status $LASTEXITCODE"
            $ErrorActionPreference = 'Stop'
        }
    }
    if (Test-Abort) { State 'aborted' } else { State 'done' }
} finally {
    # 5. restore, also after Ctrl+C or an error
    if (-not $DRY) {
        Restore-Settings *>&1 | ForEach-Object { Log "$_" }
        Set-Content -LiteralPath (Join-Path $RUN 'state') -Value 'done: settings restored'
        if ($status) { Start-Sleep -Seconds 3; if (-not $status.HasExited) { Stop-Process -Id $status.Id -Force -ErrorAction SilentlyContinue } }
        Write-Host 'Finished. Press Enter to close this window.'
        Read-Host | Out-Null
    }
}
