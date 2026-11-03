# Windows counterpart of units_report.sh: progress report of a measurement session, which
# (threads, backend, BART mode, section) units are done and how long each took, which are left and
# how long they should take.
#   powershell -File benchmark\local\units_report.ps1 SESSION_DIR [full|brief]
# Reads SESSION_DIR\units.tsv (unit<TAB>status<TAB>seconds<TAB>finished), written by run_comparison.ps1
# (or run_comparison.sh: the format is the same). The estimate for a unit that has not run is the mean
# time of the done units of the same section (any thread count), else the mean of all done units; units
# of a section never seen are not counted. Exit status 10 while units are left or failed, else 0.
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Session,
    [Parameter(Position = 1)][ValidateSet('full', 'brief')][string]$Mode = 'full'
)

$f = Join-Path $Session 'units.tsv'
if (-not (Test-Path -LiteralPath $f) -or (Get-Item -LiteralPath $f).Length -eq 0) {
    Write-Output "no unit list in $Session"
    exit 0
}

function Hms([double]$s) {
    $s = [int][math]::Floor($s + 0.5)
    '{0}:{1:00}:{2:00}' -f [int][math]::Floor($s / 3600), [int][math]::Floor(($s % 3600) / 60), ($s % 60)
}
function Pretty([string]$u) {
    $p = $u.Split(':')
    '{0} thread{1}, {2}, bart {3}, {4}{5}' -f $p[0], $(if ($p[0] -eq '1') { '' } else { 's' }), $p[1], $p[2], $p[3],
        $(if ($p.Count -gt 4) { " ($($p[4]) only)" } else { '' })
}
# What a unit's estimate is the mean of: its section, apart for a framework-restricted unit (`...:bart`).
function SectionKey([string]$u) { $p = $u.Split(':'); (@($p[3]) + @($p | Select-Object -Skip 4)) -join ':' }

$rows = @()
foreach ($line in [System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $f).Path)) {
    if ($line -eq '') { continue }
    $c = $line.Split("`t")
    $rows += [pscustomobject]@{
        Unit = $c[0]; Status = $c[1]
        Sec = $(if ($c.Count -gt 2 -and $c[2] -ne '') { [double]$c[2] } else { 0 })
        Fin = $(if ($c.Count -gt 3) { $c[3] } else { '' })
        Section = SectionKey $c[0]; Est = $null
    }
}
$d = 0; $fl = 0; $r = 0; $pend = 0; $tot = 0.0
$ssum = @{}; $scnt = @{}
foreach ($x in $rows) {
    switch ($x.Status) {
        'done' { $d++; $tot += $x.Sec; $ssum[$x.Section] += $x.Sec; $scnt[$x.Section] += 1 }
        'failed' { $fl++ }
        'running' { $r++ }
        default { $pend++ }
    }
}
$est = 0.0; $guess = $false
foreach ($x in $rows) {
    if ($x.Status -eq 'done' -or $x.Status -eq 'failed') { continue }
    if ($scnt[$x.Section] -gt 0) { $x.Est = $ssum[$x.Section] / $scnt[$x.Section]; $est += $x.Est }
    elseif ($d -gt 0) { $x.Est = $tot / $d; $est += $x.Est; $guess = $true }
}

$head = 'Progress: {0}/{1} done, {2} failed, {3} running, {4} pending.  Time in done units: {5}' -f $d, $rows.Count, $fl, $r, $pend, (Hms $tot)
if ($pend + $r -gt 0) {
    if ($d -gt 0) { $head += '.  Estimated remaining: ' + (Hms $est) + $(if ($guess) { ' (rough: some sections not measured yet)' } else { '' }) }
    else { $head += '.  No unit has finished yet, so no estimate' }
}
Write-Output $head

function Line($x) {
    switch ($x.Status) {
        'done' { '  [x] {0}  {1}  (finished {2})' -f (Hms $x.Sec), (Pretty $x.Unit), $x.Fin }
        'failed' { '  [!] failed after {0}  {1}  (finished {2})' -f (Hms $x.Sec), (Pretty $x.Unit), $x.Fin }
        'running' { '  [>] running      {0}' -f (Pretty $x.Unit) }
        default { '  [ ] pending{0}  {1}' -f $(if ($null -ne $x.Est) { ' ~' + (Hms $x.Est) } else { '' }), (Pretty $x.Unit) }
    }
}

if ($Mode -eq 'brief') {
    # the last four done units, every running one, the first five pending or failed ones
    $done = @($rows | Where-Object Status -EQ 'done')
    foreach ($x in ($done | Select-Object -Last 4)) { '  [x] {0}  {1}' -f (Hms $x.Sec), (Pretty $x.Unit) }
    $np = 0
    foreach ($x in $rows) {
        if ($x.Status -eq 'done') { continue }
        if ($x.Status -ne 'running' -and ++$np -gt 5) { continue }
        Line $x
    }
    if ($np -gt 5) { '  ... and {0} more pending' -f ($np - 5) }
} else {
    foreach ($x in $rows) { Line $x }
}
if ($pend + $r + $fl -gt 0) { exit 10 } else { exit 0 }
