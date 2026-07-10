param(
    # One or more Newman JSON report files (produced by the `json` reporter).
    [string[]]$Reports,
    # Where the generated, email-safe HTML summary is written.
    [string]$OutputFile = "test/reports/email-summary.html"
)

$ErrorActionPreference = "Stop"

# --- Aggregates across every folder/report ---
$overall = [ordered]@{
    total    = 0
    passed   = 0
    failed   = 0
    skipped  = 0
    duration = 0    # milliseconds
}
$envName    = "N/A"
$folderRows = @()
$failures   = @()

function Get-FolderName([string]$path) {
    # Report files are named "<Folder>_report_<timestamp>.json"; recover "<Folder>".
    $base = [System.IO.Path]::GetFileNameWithoutExtension($path)
    $idx  = $base.IndexOf("_report_")
    if ($idx -gt 0) { return $base.Substring(0, $idx) }
    return $base
}

foreach ($path in $Reports) {
    if (-not (Test-Path $path)) { continue }

    $json = Get-Content $path -Raw | ConvertFrom-Json
    $run  = $json.run
    if (-not $run) { continue }

    $folder = Get-FolderName $path

    # Assertion-level counts are the closest thing Newman has to "tests".
    $a       = $run.stats.assertions
    $total   = [int]$a.total
    $failed  = [int]$a.failed
    $skipped = 0
    if ($a.PSObject.Properties.Name -contains "pending") { $skipped = [int]$a.pending }
    $passed  = $total - $failed - $skipped
    if ($passed -lt 0) { $passed = 0 }

    $started   = [int64]$run.timings.started
    $completed = [int64]$run.timings.completed
    $durationMs = $completed - $started

    if ($json.environment -and $json.environment.name) { $envName = $json.environment.name }

    $overall.total    += $total
    $overall.passed   += $passed
    $overall.failed   += $failed
    $overall.skipped  += $skipped
    $overall.duration += $durationMs

    $status = if ($failed -gt 0) { "FAILED" } else { "PASSED" }
    $folderRows += [pscustomobject]@{
        Folder   = $folder
        Status   = $status
        Total    = $total
        Passed   = $passed
        Failed   = $failed
        Skipped  = $skipped
        Duration = $durationMs
    }

    # Collect individual failures with their error messages.
    if ($run.failures) {
        foreach ($f in $run.failures) {
            $source = if ($f.source -and $f.source.name) { $f.source.name } else { "(unknown request)" }
            $test   = if ($f.error -and $f.error.test) { $f.error.test } else { "" }
            $msg    = if ($f.error -and $f.error.message) { $f.error.message } else { "(no message)" }
            $failures += [pscustomobject]@{
                Folder  = $folder
                Request = $source
                Test    = $test
                Message = $msg
            }
        }
    }
}

# --- Helpers -----------------------------------------------------------------
function HtmlEncode([string]$s) {
    if ($null -eq $s) { return "" }
    return [System.Net.WebUtility]::HtmlEncode($s)
}

function Format-Duration([int64]$ms) {
    if ($ms -lt 0) { $ms = 0 }
    $ts = [TimeSpan]::FromMilliseconds($ms)
    if ($ts.TotalMinutes -ge 1) {
        return ("{0}m {1}s" -f [int]$ts.TotalMinutes, $ts.Seconds)
    }
    return ("{0:N1}s" -f $ts.TotalSeconds)
}

$passPct = if ($overall.total -gt 0) {
    [math]::Round(($overall.passed / $overall.total) * 100, 1)
} else { 0 }

$overallStatus = if ($overall.failed -gt 0) { "FAILED" } else { "PASSED" }
$bannerColor   = if ($overall.failed -gt 0) { "#c0392b" } else { "#1e8449" }

# Link back to the CI run/logs when running inside GitHub Actions.
$runUrl = $null
if ($env:GITHUB_SERVER_URL -and $env:GITHUB_REPOSITORY -and $env:GITHUB_RUN_ID) {
    $runUrl = "$($env:GITHUB_SERVER_URL)/$($env:GITHUB_REPOSITORY)/actions/runs/$($env:GITHUB_RUN_ID)"
}

# --- Build the email-safe HTML (inline styles only) --------------------------
$sb = [System.Text.StringBuilder]::new()
[void]$sb.Append(@"
<div style="font-family:Segoe UI,Arial,sans-serif;color:#2c3e50;max-width:760px;margin:0 auto;">
  <div style="background:$bannerColor;color:#ffffff;padding:16px 20px;border-radius:6px 6px 0 0;">
    <h2 style="margin:0;font-size:20px;">API Automation Tests: $overallStatus</h2>
    <div style="font-size:13px;opacity:.9;margin-top:4px;">Environment: $(HtmlEncode $envName)</div>
  </div>
  <div style="border:1px solid #e1e4e8;border-top:none;padding:20px;border-radius:0 0 6px 6px;">
"@)

# Summary tiles
[void]$sb.Append(@"
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:20px;border-collapse:collapse;">
      <tr>
        <td style="padding:10px;text-align:center;background:#f6f8fa;border:1px solid #e1e4e8;">
          <div style="font-size:22px;font-weight:bold;">$($overall.total)</div>
          <div style="font-size:12px;color:#57606a;">Total</div>
        </td>
        <td style="padding:10px;text-align:center;background:#f6f8fa;border:1px solid #e1e4e8;">
          <div style="font-size:22px;font-weight:bold;color:#1e8449;">$($overall.passed)</div>
          <div style="font-size:12px;color:#57606a;">Passed</div>
        </td>
        <td style="padding:10px;text-align:center;background:#f6f8fa;border:1px solid #e1e4e8;">
          <div style="font-size:22px;font-weight:bold;color:#c0392b;">$($overall.failed)</div>
          <div style="font-size:12px;color:#57606a;">Failed</div>
        </td>
        <td style="padding:10px;text-align:center;background:#f6f8fa;border:1px solid #e1e4e8;">
          <div style="font-size:22px;font-weight:bold;color:#b7791f;">$($overall.skipped)</div>
          <div style="font-size:12px;color:#57606a;">Skipped</div>
        </td>
        <td style="padding:10px;text-align:center;background:#f6f8fa;border:1px solid #e1e4e8;">
          <div style="font-size:22px;font-weight:bold;">$passPct%</div>
          <div style="font-size:12px;color:#57606a;">Pass rate</div>
        </td>
        <td style="padding:10px;text-align:center;background:#f6f8fa;border:1px solid #e1e4e8;">
          <div style="font-size:22px;font-weight:bold;">$(Format-Duration $overall.duration)</div>
          <div style="font-size:12px;color:#57606a;">Duration</div>
        </td>
      </tr>
    </table>
"@)

# Per-folder breakdown
[void]$sb.Append(@"
    <h3 style="font-size:15px;margin:0 0 8px;">Per-folder results</h3>
    <table width="100%" cellpadding="6" cellspacing="0" style="border-collapse:collapse;font-size:13px;margin-bottom:20px;">
      <tr style="background:#f6f8fa;text-align:left;">
        <th style="border:1px solid #e1e4e8;">Folder</th>
        <th style="border:1px solid #e1e4e8;">Status</th>
        <th style="border:1px solid #e1e4e8;">Total</th>
        <th style="border:1px solid #e1e4e8;">Passed</th>
        <th style="border:1px solid #e1e4e8;">Failed</th>
        <th style="border:1px solid #e1e4e8;">Skipped</th>
        <th style="border:1px solid #e1e4e8;">Duration</th>
      </tr>
"@)
foreach ($row in $folderRows) {
    $stColor = if ($row.Status -eq "FAILED") { "#c0392b" } else { "#1e8449" }
    [void]$sb.Append(@"
      <tr>
        <td style="border:1px solid #e1e4e8;">$(HtmlEncode $row.Folder)</td>
        <td style="border:1px solid #e1e4e8;color:$stColor;font-weight:bold;">$($row.Status)</td>
        <td style="border:1px solid #e1e4e8;">$($row.Total)</td>
        <td style="border:1px solid #e1e4e8;">$($row.Passed)</td>
        <td style="border:1px solid #e1e4e8;">$($row.Failed)</td>
        <td style="border:1px solid #e1e4e8;">$($row.Skipped)</td>
        <td style="border:1px solid #e1e4e8;">$(Format-Duration $row.Duration)</td>
      </tr>
"@)
}
[void]$sb.Append("    </table>`n")

# Failed-test summary
if ($failures.Count -gt 0) {
    $maxShown = 50
    [void]$sb.Append(@"
    <h3 style="font-size:15px;margin:0 0 8px;color:#c0392b;">Failed tests ($($failures.Count))</h3>
    <table width="100%" cellpadding="6" cellspacing="0" style="border-collapse:collapse;font-size:13px;margin-bottom:12px;">
      <tr style="background:#fdecea;text-align:left;">
        <th style="border:1px solid #e1e4e8;">Folder</th>
        <th style="border:1px solid #e1e4e8;">Request</th>
        <th style="border:1px solid #e1e4e8;">Error</th>
      </tr>
"@)
    $shown = 0
    foreach ($f in $failures) {
        if ($shown -ge $maxShown) { break }
        $detail = $f.Message
        if ($f.Test) { $detail = "$($f.Test): $($f.Message)" }
        [void]$sb.Append(@"
      <tr>
        <td style="border:1px solid #e1e4e8;">$(HtmlEncode $f.Folder)</td>
        <td style="border:1px solid #e1e4e8;">$(HtmlEncode $f.Request)</td>
        <td style="border:1px solid #e1e4e8;color:#c0392b;">$(HtmlEncode $detail)</td>
      </tr>
"@)
        $shown++
    }
    [void]$sb.Append("    </table>`n")
    if ($failures.Count -gt $maxShown) {
        [void]$sb.Append("    <p style='font-size:12px;color:#57606a;'>Showing first $maxShown of $($failures.Count) failures. See the attached report for the rest.</p>`n")
    }
} else {
    [void]$sb.Append("    <p style='color:#1e8449;font-weight:bold;'>All tests passed. &#127881;</p>`n")
}

# Links / footer
[void]$sb.Append("    <hr style='border:none;border-top:1px solid #e1e4e8;margin:16px 0;'>`n")
if ($runUrl) {
    [void]$sb.Append("    <p style='font-size:13px;'>&#128279; <a href='$runUrl'>View full run &amp; download detailed HTML reports</a></p>`n")
}
[void]$sb.Append("    <p style='font-size:12px;color:#57606a;'>The complete per-folder HTML reports are attached to this email.</p>`n")
[void]$sb.Append("  </div>`n</div>`n")

# --- Write it out ------------------------------------------------------------
$outDir = Split-Path -Parent $OutputFile
if ($outDir -and -not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}
Set-Content -Path $OutputFile -Value $sb.ToString() -Encoding UTF8
Write-Host "Email summary written to: $OutputFile"
