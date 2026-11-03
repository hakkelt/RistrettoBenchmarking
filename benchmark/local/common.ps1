# Helpers shared by the Windows benchmark scripts (run_comparison.ps1, quiet_run.ps1,
# quiet_status.ps1), dot-sourced by each. Windows PowerShell 5.1 or newer; nothing here needs admin
# rights except the temperature sensor, which reads as unavailable without them.

$script:REPO_ROOT = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

# Raw `--flag=value` arguments. PowerShell turns an unquoted `--threads=1,2` into the array
# ('--threads=1', 2), so an array argument is joined back with commas.
function ConvertTo-FlagList([object[]]$Raw) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($a in $Raw) {
        if ($a -is [array]) { $out.Add((($a | ForEach-Object { "$_" }) -join ',')) } else { $out.Add("$a") }
    }
    , $out.ToArray()
}

# KEY=value lines of benchmark/slurm/site.env into the environment, for keys not already set: the
# same rule as `load_site_env!` (benchmark/utils/config.jl), so the scripts see what Julia will.
function Import-SiteEnv {
    $path = Join-Path $script:REPO_ROOT 'benchmark\slurm\site.env'
    if (-not (Test-Path -LiteralPath $path)) { return }
    foreach ($line in Get-Content -LiteralPath $path) {
        $s = $line.Trim()
        if ($s -eq '' -or $s.StartsWith('#')) { continue }
        if ($s -notmatch '^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { continue }
        $key = $Matches[1]; $val = $Matches[2].Trim()
        if ($val.Length -ge 2 -and $val[0] -eq $val[-1] -and ($val[0] -eq '"' -or $val[0] -eq "'")) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        if ([Environment]::GetEnvironmentVariable($key) -ne $null) { continue }
        [Environment]::SetEnvironmentVariable($key, $val)
    }
}

function Find-Julia {
    $j = $env:JULIA_BIN
    if ($j -and (Test-Path -LiteralPath $j)) { return (Resolve-Path -LiteralPath $j).Path }
    $c = Get-Command julia -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    $j = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\julia.exe'   # juliaup
    if (Test-Path -LiteralPath $j) { return $j }
    return $null
}

# The comparison setup imports SigPy unconditionally (_setup.jl), so without it every unit fails a
# few seconds in. Returns $null when RISTRETTO_BENCH_SIGPY_PYTHON imports SigPy, otherwise the reason;
# MRpro is optional (its rows are skipped), so its absence is only a warning.
function Test-BenchPython {
    $py = $env:RISTRETTO_BENCH_SIGPY_PYTHON
    if (-not $py) { return 'RISTRETTO_BENCH_SIGPY_PYTHON is not set (benchmark/slurm/site.env)' }
    if (-not (Test-Path -LiteralPath $py)) { return "RISTRETTO_BENCH_SIGPY_PYTHON=$py does not exist" }
    & $py -c 'import sigpy' 2>$null
    if ($LASTEXITCODE -ne 0) { return "SigPy does not import in $py" }
    & $py -c 'import mrpro' 2>$null
    if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine("### MRpro does not import in ${py}: its rows are skipped") }
    return $null
}

# Processor topology of processor group 0 (at most 64 logical CPUs, which is all a desktop or laptop
# has). Windows has no runtime SMT switch, so "SMT off" means pinning to one logical CPU per core
# and leaving its sibling idle.
if (-not ('RistrettoBench.Topology' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace RistrettoBench {
    public static class Topology {
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetLogicalProcessorInformation(IntPtr buffer, ref uint length);
        // One mask of logical CPUs per physical core (RelationProcessorCore = 0).
        public static ulong[] CoreMasks() {
            uint len = 0;
            GetLogicalProcessorInformation(IntPtr.Zero, ref len);
            IntPtr buf = Marshal.AllocHGlobal((int)len);
            try {
                if (!GetLogicalProcessorInformation(buf, ref len))
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                // SYSTEM_LOGICAL_PROCESSOR_INFORMATION: ULONG_PTR mask, int relationship, 16-byte union
                int size = IntPtr.Size == 8 ? 32 : 24;
                var masks = new List<ulong>();
                for (int off = 0; off + size <= len; off += size) {
                    IntPtr p = new IntPtr(buf.ToInt64() + off);
                    ulong mask = IntPtr.Size == 8 ? (ulong)Marshal.ReadInt64(p) : (uint)Marshal.ReadInt32(p);
                    int rel = Marshal.ReadInt32(p, IntPtr.Size);
                    if (rel == 0) masks.Add(mask);
                }
                return masks.ToArray();
            } finally { Marshal.FreeHGlobal(buf); }
        }
    }
}
'@
}

# @{ Phys = lowest logical CPU of every core, sorted; All = every logical CPU, sorted }
function Get-CpuTopology {
    $phys = @(); $all = @()
    foreach ($m in [RistrettoBench.Topology]::CoreMasks()) {
        $cpus = @(0..63 | Where-Object { ($m -shr $_) -band 1 })
        $phys += $cpus[0]
        $all += $cpus
    }
    @{ Phys = @($phys | Sort-Object); All = @($all | Sort-Object) }
}

# Affinity mask of a CPU list, as the hex number `start /affinity` takes.
function Get-AffinityHex([int[]]$Cpus) {
    [uint64]$m = 0
    foreach ($c in $Cpus) { $m = $m -bor ([uint64]1 -shl $c) }
    '{0:X}' -f $m
}

# Hottest ACPI thermal zone in whole degrees C, or $null when Windows exposes none (it needs admin
# rights, and many machines report a fixed or no value: a hardware-monitor tool is more reliable).
function Get-MaxTemp {
    try {
        $z = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
        $t = ($z | ForEach-Object { $_.CurrentTemperature } | Measure-Object -Maximum).Maximum
        if ($t) { return [int][math]::Round($t / 10 - 273.15) }
    } catch {}
    return $null
}

# Average current clock in MHz, the performance limit (below 100: power or thermal capping) and the load, from the processor counters.
function Get-CpuClock {
    try {
        $p = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop
        $base = (Get-CimInstance Win32_Processor | Select-Object -First 1).MaxClockSpeed
        return @{ MHz = [int]($base * $p.PercentProcessorPerformance / 100); Limit = $p.PercentPerformanceLimit; Load = $p.PercentProcessorTime }
    } catch { return $null }
}

# Kill a process and all its descendants (julia under a launcher shim, bart, python), leaves first.
# Not `taskkill /T`: it fails on the julia that juliaup's launcher starts ("There is no running
# instance of the task") while Stop-Process kills it, and under $ErrorActionPreference = 'Stop' its
# stderr line throws, ending the caller mid-abort. A child must be younger than its parent, which
# keeps a reused parent PID from pulling in unrelated processes.
function Stop-ProcessTree([int]$ProcessId) {
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $tree = New-Object System.Collections.Generic.List[object]
    $root = $procs | Where-Object { $_.ProcessId -eq $ProcessId } | Select-Object -First 1
    if ($root) { $tree.Add($root) }
    for ($i = 0; $i -lt $tree.Count; $i++) {
        $parent = $tree[$i]
        foreach ($c in $procs) {
            if ($c.ParentProcessId -eq $parent.ProcessId -and $c.CreationDate -ge $parent.CreationDate -and -not $tree.Contains($c)) { $tree.Add($c) }
        }
    }
    if (-not $root) { $tree.Add([pscustomobject]@{ ProcessId = $ProcessId }) }
    for ($i = $tree.Count - 1; $i -ge 0; $i--) {
        try { Stop-Process -Id $tree[$i].ProcessId -Force -ErrorAction Stop } catch {}
    }
}

# Write a file atomically enough for a concurrent reader: LF line ends, no BOM, so the bash
# units_report.sh can read the same units.tsv.
function Write-Lines([string]$Path, [string[]]$Lines) {
    $tmp = "$Path.tmp$PID"
    $text = if ($Lines.Count) { ($Lines -join "`n") + "`n" } else { '' }
    [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding $false))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
}
