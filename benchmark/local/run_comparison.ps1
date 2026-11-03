# Windows counterpart of run_comparison.sh, for a single workstation or laptop (no SLURM, no admin
# rights). Runs benchmark/comparison/scripts/run_all.jl once per (BLAS backend, thread count, BART
# mode, section), one run at a time, each started with a process affinity mask over its own physical
# cores (one logical CPU per core, never an SMT sibling, same rule as _setup.jl, which then gives each
# Julia thread its CPU as ideal processor inside that mask). Results go where the SLURM runs put them,
# benchmark/comparison/results/runs/, plus a log per run under benchmark/results/local/.
#
# usage (Windows PowerShell 5.1 or PowerShell 7, from the repository root):
#   powershell -ExecutionPolicy Bypass -File benchmark\local\run_comparison.ps1 [--threads=1,2]
#       [--backends=openblas] [--prepare] [--small] [--no-pin] [run_all.jl flags...]
#
#   --threads=LIST    thread counts, comma separated (default: 1..N-physical-cores, powers of two)
#   --backends=LIST   openblas, mkl and/or cuda (default: openblas). cuda runs every section but kspace
#                     on the GPU (run_all.jl --device=cuda) at one host thread, whatever --threads says,
#                     with no affinity mask (the driver's and the toolkits' host threads need more than one core),
#                     with the BART build RISTRETTO_BENCH_BART_CUDA names and the Python interpreter
#                     RISTRETTO_BENCH_GPU_PYTHON names (CuPy and a CUDA build of PyTorch), from site.env
#   --prepare         instantiate the Julia environment, then exit
#   --small           RISTRETTO_BENCH_SMALL=1 smoke sizes (minutes instead of hours)
#   --smt             allow SMT siblings: thread counts up to the logical CPU count (default list then
#                     is just that count), tagged placement "shared" so they never mix with physical-core runs
#   --cooldown=SEC    pause between consecutive runs (never before the first or after the last; default 0)
#   --cooldown-temp=C after the --cooldown pause, keep waiting until the hottest ACPI thermal zone is at
#                     most C degrees (at most --cooldown-max seconds, default 900). Windows exposes the
#                     sensor only to an elevated shell, and not on every machine: without a reading the
#                     wait is skipped with a note.
#   --bart-modes=LIST estimate and/or measure (default both), as in run_comparison.sh
#   --session=DIR     keep the logs and the unit list (units.tsv: status and time per unit) in DIR
#   --resume[=DIR]    continue a session (the newest one by default): done units are skipped, failed and
#                     interrupted ones run again. Pass the same options as the first time. A BART build
#                     configured since adds the units BART was missing from: BART-only reruns of the
#                     done estimate units that ran without one (`<unit>:bart`), and the measure units.
#   --plan-only       write/print the unit list and exit (status 10 when there is nothing left to run)
#   --no-pin          do not set a process affinity mask
#   --priority=P      priority class of each run: normal (default), abovenormal or high
# Everything else (--sections=, --cases=, --frameworks=, --remeasure, --data=...) is passed to run_all.jl.
#
# Machine paths (JULIA_BIN, BART builds, SigPy interpreter, data cache) are read from
# benchmark/slurm/site.env when that file exists, exactly as on the cluster; BART and MRpro rows are
# skipped with a warning when they are not configured, while a SigPy interpreter is required (the run
# stops before its first unit without one). The unit list has the same format as
# the bash script's, so units_report.sh and units_report.ps1 both read it.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
Set-Location -LiteralPath $REPO_ROOT

Import-SiteEnv
$JULIA_BIN = Find-Julia
if (-not $JULIA_BIN) { [Console]::Error.WriteLine('### no julia on PATH: set JULIA_BIN'); exit 1 }
$PROJECT_DIR = 'benchmark/comparison'
$SCRIPT_PATH = 'benchmark/comparison/scripts/run_all.jl'

$topo = Get-CpuTopology
$PHYS_CPUS = $topo.Phys
$ALL_CPUS = $topo.All
$N_PHYS = $PHYS_CPUS.Count

$THREADS = @(); $BACKENDS = @('openblas'); $PREPARE = $false; $PIN = $true; $SMT = $false
$COOLDOWN = 0; $SESSION = ''; $RESUME = $false; $PLAN_ONLY = $false; $COOL_TEMP = $null; $COOL_MAX = 900
$BART_MODES = @('estimate', 'measure'); $PRIORITY = 'normal'; $PASS_ARGS = @()
foreach ($a in (ConvertTo-FlagList $args)) {
    $v = if ($a -match '^--[^=]+=(.*)$') { $Matches[1] } else { '' }
    switch -Regex ($a) {
        '^--threads=' { $THREADS = @($v.Split(',') | ForEach-Object { [int]$_ }); break }
        '^--backends=' { $BACKENDS = $v.Split(','); break }
        '^--prepare$' { $PREPARE = $true; break }
        '^--small$' { $env:RISTRETTO_BENCH_SMALL = '1'; break }
        '^--cooldown=' { $COOLDOWN = [int]$v; break }
        '^--cooldown-temp=' { $COOL_TEMP = [int]$v; break }
        '^--cooldown-max=' { $COOL_MAX = [int]$v; break }
        '^--bart-modes=' { $BART_MODES = $v.Split(','); break }
        '^--session=' { $SESSION = $v; break }
        '^--resume$' { $RESUME = $true; break }
        '^--resume=' { $RESUME = $true; $SESSION = $v; break }
        '^--plan-only$' { $PLAN_ONLY = $true; break }
        '^--smt$' { $SMT = $true; break }
        '^--no-pin$' { $PIN = $false; break }
        '^--priority=' { $PRIORITY = $v.ToLower(); break }
        default { $PASS_ARGS += $a }
    }
}
if ($PRIORITY -notin 'normal', 'abovenormal', 'high') { [Console]::Error.WriteLine('### --priority must be normal, abovenormal or high'); exit 2 }
if ($SMT) {
    # lowest-numbered siblings first, then their siblings
    $CPU_ORDER = @($PHYS_CPUS) + @($ALL_CPUS | Where-Object { $_ -notin $PHYS_CPUS })
    $N_MAX = $ALL_CPUS.Count
    $env:RISTRETTO_BENCH_ALLOW_SMT = '1'; $env:RISTRETTO_BENCH_PLACEMENT = 'shared'
} else {
    $CPU_ORDER = @($PHYS_CPUS)
    $N_MAX = $N_PHYS
}
if ($THREADS.Count -eq 0) {
    if ($SMT) { $THREADS = @($N_MAX) }   # the physical-core counts are what a run without --smt measures
    else {
        for ($t = 1; $t -le $N_MAX; $t *= 2) { $THREADS += $t }
        if ($THREADS[-1] -ne $N_MAX) { $THREADS += $N_MAX }
    }
}

if ($PREPARE) {
    & $JULIA_BIN --project=$PROJECT_DIR -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'
    exit $LASTEXITCODE
}

foreach ($t in $THREADS) {
    if ($t -gt $N_MAX) {
        [Console]::Error.WriteLine("### $t threads requested but only $N_MAX usable CPUs (use --smt for hyperthreads)")
        exit 2
    }
}

# Same process-wide settings as slurm/common.sh; Windows has no /dev/shm, so the temporary directory
# stays the user's unless TMPDIR_BENCH names one (a RAM disk, say).
if (-not $env:KMP_BLOCKTIME) { $env:KMP_BLOCKTIME = '0' }
if ($env:TMPDIR_BENCH) { $env:TMPDIR = $env:TMPDIR_BENCH; $env:TEMP = $env:TMPDIR_BENCH; $env:TMP = $env:TMPDIR_BENCH }
if (-not $env:RISTRETTO_BENCH_PLACEMENT) { $env:RISTRETTO_BENCH_PLACEMENT = 'isolated' }

# A session directory holds the logs and units.tsv, the list of units with their status and time.
$LOCAL_DIR = Join-Path $REPO_ROOT 'benchmark\results\local'
if ($RESUME -and -not $SESSION) {
    $SESSION = Get-ChildItem -LiteralPath $LOCAL_DIR -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Where-Object { (Test-Path (Join-Path $_.FullName 'units.tsv')) -and (Get-Item (Join-Path $_.FullName 'units.tsv')).Length -gt 0 } |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $SESSION) { [Console]::Error.WriteLine('### nothing to resume: no session with a unit list'); exit 1 }
}
if (-not $SESSION) { $SESSION = Join-Path $LOCAL_DIR (Get-Date -Format 'yyyyMMdd_HHmmss') }
$LOG_DIR = [IO.Path]::GetFullPath($SESSION)
$UNITS_FILE = Join-Path $LOG_DIR 'units.tsv'
if ($RESUME -and -not ((Test-Path -LiteralPath $UNITS_FILE) -and (Get-Item -LiteralPath $UNITS_FILE).Length -gt 0)) {
    [Console]::Error.WriteLine("### $LOG_DIR has no units.tsv to resume"); exit 1
}
New-Item -ItemType Directory -Force -Path $LOG_DIR, (Join-Path $REPO_ROOT 'benchmark\comparison\results\runs') | Out-Null
$ENV_FILE = Join-Path $LOG_DIR 'environment.txt'
function Tee-Env([string]$s) { Write-Output $s; Add-Content -LiteralPath $ENV_FILE -Value $s }

$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
Tee-Env "### $(Get-Date -Format o) on $env:COMPUTERNAME"
Tee-Env "### threads: $($THREADS -join ' ')  backends: $($BACKENDS -join ' ')  pass-through: $(if ($PASS_ARGS.Count) { $PASS_ARGS -join ' ' } else { '<none>' })"
Tee-Env "### physical cpus: $($PHYS_CPUS -join ' ')  (logical: $($ALL_CPUS.Count))"
Tee-Env "Model name: $($cpu.Name)  max MHz: $($cpu.MaxClockSpeed)"
Tee-Env "### power scheme: $((& powercfg.exe /getactivescheme) -join ' ')"

# Sections run one by one (each is its own subprocess anyway), so a cooldown can sit between them.
$SECTIONS = @('base', 'noncart', 'cgsense', 'sparsity', 'dynamic', 'kspace', 'accuracy_race')
$REST = @()
foreach ($a in $PASS_ARGS) {
    if ($a -match '^--sections=(.*)$') { $SECTIONS = $Matches[1].Split(',') } else { $REST += $a }
}

# BART modes, as in run_comparison.sh. Without a BART build both modes would measure the same thing.
function Get-BartBin([string]$b) {
    switch ($b) { 'mkl' { $env:RISTRETTO_BENCH_BART_MKL } 'cuda' { $env:RISTRETTO_BENCH_BART_CUDA } default { $env:RISTRETTO_BENCH_BART_OPENBLAS } }
}
foreach ($b in $BACKENDS) {
    if ($b -notin 'openblas', 'mkl', 'cuda') { [Console]::Error.WriteLine("### --backends: unknown backend $b"); exit 2 }
}

$UNITS = @()   # threads:backend:mode:section
foreach ($t in $THREADS) {
    foreach ($b in $BACKENDS) {
        # A GPU run has one host thread (_setup.jl refuses more), so it is one set of units, not one per
        # thread count; FFTW's planner mode means nothing to BART's cuFFT, and GRAPPA has no GPU rows.
        if ($b -eq 'cuda' -and $t -ne $THREADS[0]) { continue }
        $tt = if ($b -eq 'cuda') { 1 } else { $t }
        $bart = Get-BartBin $b
        $modes = if ($b -ne 'cuda' -and $bart -and (Test-Path -LiteralPath $bart -PathType Leaf)) { $BART_MODES } else { @('estimate') }
        foreach ($m in $modes) {
            foreach ($sec in $SECTIONS) {
                # MEASURE changes only BART; base and kspace have no timed BART rows
                if ($m -eq 'measure' -and ($sec -eq 'base' -or $sec -eq 'kspace')) { continue }
                if ($b -eq 'cuda' -and $sec -eq 'kspace') { continue }
                $UNITS += "${tt}:${b}:${m}:${sec}"
            }
        }
    }
}
Tee-Env "### $($UNITS.Count) runs, cooldown $COOLDOWN s between them; bart modes: $($BART_MODES -join ' ')"

# ---- unit list: status per unit, kept in units.tsv (unit, status, seconds, finished) ------------------
function Read-Units {
    $h = [ordered]@{}
    if (Test-Path -LiteralPath $UNITS_FILE) {
        foreach ($l in [IO.File]::ReadAllLines($UNITS_FILE)) {
            if ($l -eq '') { continue }
            $c = $l.Split("`t"); while ($c.Count -lt 4) { $c += '' }
            $h[$c[0]] = $c
        }
    }
    $h
}
function Get-UnitStatus([string]$u) { $h = Read-Units; if ($h.Contains($u)) { $h[$u][1] } else { '' } }
function Set-Unit([string]$u, [string]$status, [int]$seconds) {
    $h = Read-Units
    $h[$u] = @($u, $status, "$seconds", $(if ($status -eq 'pending') { '' } else { Get-Date -Format 'HH:mm:ss' }))
    Write-Lines $UNITS_FILE @($h.Values | ForEach-Object { $_ -join "`t" })
}
# A done estimate unit that ran before a BART build was configured has no BART rows (its log carries
# _setup.jl's warning). With a build configured now, a BART-only unit after it (`<unit>:bart`, run with
# --frameworks=bart) fills them in, so resuming completes the session, not only its unfinished units.
# A unit that is not done gets none: rerunning it includes BART anyway.
$h = Read-Units
$all = @()
foreach ($u in $UNITS) {
    $all += $u
    $t, $b, $m, $sec = $u.Split(':')
    $bart = Get-BartBin $b
    if ($m -ne 'estimate' -or -not ($bart -and (Test-Path -LiteralPath $bart -PathType Leaf))) { continue }
    $log = Join-Path $LOG_DIR "${b}_${t}t_${m}_${sec}.log"
    $skipped = $h.Contains($u) -and $h[$u][1] -eq 'done' -and (Test-Path -LiteralPath $log) -and
        (Select-String -LiteralPath $log -SimpleMatch 'No BART build configured' -Quiet)
    if ($h.Contains("${u}:bart") -or $skipped) { $all += "${u}:bart" }
}
$UNITS = $all
foreach ($u in $UNITS) {
    if (-not $h.Contains($u)) { $h[$u] = @($u, 'pending', '0', '') }
    elseif ($RESUME) {
        # interrupted units start over; done ones stay done, failed ones are retried
        if ($h[$u][1] -ne 'done') { $h[$u] = @($u, 'pending', '0', $h[$u][3]) }
    } else { $h[$u] = @($u, 'pending', '0', $h[$u][3]) }
}
Write-Lines $UNITS_FILE @($h.Values | ForEach-Object { $_ -join "`t" })
$TODO = @($UNITS | Where-Object { $h[$_][1] -ne 'done' }).Count
Write-Output "### session: $LOG_DIR ($TODO of $($UNITS.Count) units to run)"
$REPORT = Join-Path $PSScriptRoot 'units_report.ps1'
& $REPORT $LOG_DIR
if ($PLAN_ONLY) { if ($TODO -gt 0) { exit 0 } else { exit 10 } }
$pyErr = Test-BenchPython
if ($pyErr) { [Console]::Error.WriteLine("### $pyErr"); exit 1 }

function Format-Temp { $t = Get-MaxTemp; if ($null -eq $t) { 'n/a' } else { "$t C" } }

# One run: cmd's `start /affinity` gives julia its mask at creation, so every thread and every child
# (a launcher shim's julia, bart, python) inherits it; cmd does the redirection into the log.
# An empty $cpus starts it without a mask.
function Invoke-Unit([string]$cpus, [string[]]$juliaArgs, [string]$log) {
    $q = { param($s) if ($s -match '[\s"&|<>^()]') { '"' + ($s -replace '"', '\"') + '"' } else { $s } }
    $line = (@($JULIA_BIN) + $juliaArgs | ForEach-Object { & $q $_ }) -join ' '
    $start = 'start "" /b /wait'
    if ($PRIORITY -ne 'normal') { $start += " /$PRIORITY" }
    if ($PIN -and $cpus) { $start += ' /affinity ' + (Get-AffinityHex ([int[]]$cpus.Split(','))) }
    $cmdline = "/d /v:on /s /c `"$start $line > `"$log`" 2>&1 & exit !errorlevel!`""
    $p = Start-Process -FilePath cmd.exe -ArgumentList $cmdline -NoNewWindow -PassThru
    $null = $p.Handle   # without the handle cached now, ExitCode reads empty after the exit
    # quiet_run.ps1 aborts by creating this file; anyone else can, too
    $abortFile = if ($env:RISTRETTO_QUIET_DIR) { Join-Path $env:RISTRETTO_QUIET_DIR 'abort' } else { $null }
    # Crash watchdog: when several Julia threads fault at once (EXCEPTION_ACCESS_VIOLATION), Julia's
    # crash handler can deadlock instead of exiting, and the unit would hang for days with no CPU
    # use. The log is read from where the last look ended, shared with cmd, which keeps it open.
    $offset = 0L; $crashedAt = $null
    while (-not $p.WaitForExit(1000)) {
        if ($abortFile -and (Test-Path -LiteralPath $abortFile)) {
            Stop-ProcessTree $p.Id
            $p.WaitForExit() | Out-Null
            return -1
        }
        if ($null -eq $crashedAt) {
            $new = Read-LogFrom $log ([ref]$offset)
            if ($new -match 'EXCEPTION_ACCESS_VIOLATION') { $crashedAt = [DateTime]::Now }
        } elseif (([DateTime]::Now - $crashedAt).TotalSeconds -ge 30) {
            # a handler that does exit has had time to; this one is stuck
            Stop-ProcessTree $p.Id
            $p.WaitForExit() | Out-Null
            return -2
        }
    }
    $p.ExitCode
}

# The text appended to $path since byte $offset (advanced past it); a partial line at the end is
# left for the next call, so a pattern is never split between two reads.
function Read-LogFrom([string]$path, [ref]$offset) {
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try {
        $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite, Delete')
        try {
            if ($fs.Length -le $offset.Value) { return '' }
            $null = $fs.Seek($offset.Value, 'Begin')
            $buf = New-Object byte[] ($fs.Length - $offset.Value)
            $n = $fs.Read($buf, 0, $buf.Length)
            $end = [Array]::LastIndexOf($buf, [byte]10, $n - 1)
            if ($end -lt 0) { return '' }
            $offset.Value += $end + 1
            return [Text.Encoding]::UTF8.GetString($buf, 0, $end + 1)
        } finally { $fs.Close() }
    } catch { return '' }
}

$FAILED = 0
$first = $true
$sw = [Diagnostics.Stopwatch]::StartNew()
foreach ($u in $UNITS) {
    $t, $b, $m, $sec, $only = $u.Split(':')
    if ((Get-UnitStatus $u) -eq 'done') { Write-Output "### skipping ${u}: done already"; continue }
    if (-not $first) {
        Write-Output "### $(Get-Date -Format HH:mm:ss) temperature at the end of the last run: $(Format-Temp)"
        if ($COOLDOWN -gt 0) { Write-Output "### cooldown $COOLDOWN s"; Start-Sleep -Seconds $COOLDOWN }
        if ($null -ne $COOL_TEMP) {
            if ($null -eq (Get-MaxTemp)) { Write-Output '### no temperature sensor readable (needs an elevated shell): --cooldown-temp skipped' }
            else {
                $waited = 0
                while ((Get-MaxTemp) -gt $COOL_TEMP -and $waited -lt $COOL_MAX) { Start-Sleep -Seconds 5; $waited += 5 }
                Write-Output "### waited $waited s more for <= $COOL_TEMP C (max $COOL_MAX s)"
            }
        }
        Write-Output "### $(Get-Date -Format HH:mm:ss) temperature at the start of the next run: $(Format-Temp)"
    } else {
        Write-Output "### temperature at the start of the first run: $(Format-Temp)"
    }
    $first = $false
    $runArgs = @("--threads=$t", "--sections=$sec")
    if ($b -eq 'mkl') { $runArgs += '--use-mkl' }
    if ($b -eq 'cuda') { $runArgs += '--device=cuda' }
    # A GPU unit gets no mask: its one Julia thread is still pinned by _setup.jl, but the CUDA driver's
    # threads and the Python toolkits' would otherwise share that core with it, and starved of it the
    # host side that feeds the device ran a 13 ms CG-SENSE in 17 s.
    $cpus = if ($b -eq 'cuda') { '' } else { ($CPU_ORDER[0..([int]$t - 1)]) -join ',' }
    $measure = '0'; if ($m -eq 'measure') { $measure = '1'; $runArgs += '--frameworks=bart' }
    if ($only -eq 'bart') { $runArgs += '--frameworks=bart' }
    $log = Join-Path $LOG_DIR "${b}_${t}t_${m}_${sec}$(if ($only) { "_$only" }).log"
    Write-Output "### $(Get-Date -Format HH:mm:ss) $b, $t thread(s), bart $m, section $sec, cpus $cpus -> $log"
    Set-Unit $u running 0
    $unitStart = $sw.Elapsed.TotalSeconds
    foreach ($n in 'JULIA_NUM_THREADS', 'OMP_NUM_THREADS', 'OPENBLAS_NUM_THREADS', 'MKL_NUM_THREADS') { Set-Item "env:$n" $t }
    $env:RISTRETTO_BENCH_BART_MEASURE = $measure
    $rc = Invoke-Unit $cpus (@("--project=$PROJECT_DIR", '-t', $t, $SCRIPT_PATH) + $runArgs + $REST) $log
    $took = [int]($sw.Elapsed.TotalSeconds - $unitStart)
    if ($rc -eq -1) {
        Write-Output "### $u aborted"
        Set-Unit $u failed $took; $FAILED = 1
        break
    }
    if ($rc -eq -2) {
        [Console]::Error.WriteLine("### $b/$t/$m/$sec crashed (EXCEPTION_ACCESS_VIOLATION) and hung: killed, see $log")
        Set-Unit $u failed $took; $FAILED = 1
        & $REPORT $LOG_DIR brief
        continue
    }
    # run_all.jl only warns when a section dies, so the exit status is not enough: a unit failed when it
    # exited with an error or reported a failed section. A clean run that recorded nothing (the case
    # filter matched no case of this section) counts as done, with a note.
    if ($rc -eq 0 -and -not (Select-String -LiteralPath $log -SimpleMatch "section $sec failed" -Quiet)) {
        if (-not (Select-String -LiteralPath $log -SimpleMatch 'flushed run' -Quiet)) {
            Write-Output "### note: $u recorded no rows (no case of this section matched?)"
        }
        Set-Unit $u done $took
    } else {
        [Console]::Error.WriteLine("### $b/$t/$m/$sec failed (exit $rc, see $log)")
        Set-Unit $u failed $took; $FAILED = 1
    }
    & $REPORT $LOG_DIR brief
}
& $REPORT $LOG_DIR
Write-Output "### done $(Get-Date -Format HH:mm:ss); results: benchmark/comparison/results/runs/, logs: $LOG_DIR"
exit $FAILED
