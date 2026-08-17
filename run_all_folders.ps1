param(
    [string]$Collection  = "test/API_automation.postman_collection.json",
    [string]$Environment = "test/API_automation.postman_environment.json",
    [string]$OutputDir   = "test/reports",
    [string]$Data   = "test/languages.csv",
    # Response-time limit (ms) for every timing assertion. Overrides the
    # maxResponseTime value in the environment file, so CI can loosen or
    # tighten it without editing the collection. Falls back to the
    # MAX_RESPONSE_TIME env var, then to whatever the environment file holds.
    [string]$MaxResponseTime = $env:MAX_RESPONSE_TIME
)

$ErrorActionPreference = "Stop"

# --- Validate required files exist ---
foreach ($file in @($Collection, $Environment, $Data)) {
    if (-not (Test-Path $file)) {
        Write-Error "Required file not found: $file"
        exit 1
    }
}

Write-Host "Using collection:  $Collection"
Write-Host "Using environment: $Environment"
Write-Host "Using data file:   $Data"
Write-Host "Reports output to: $OutputDir"
Write-Host "-----------------------------------------------------"

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

# List of folders to run
$Folders = @("Orchestration", "Content", "Learner AI")

# Iteration count per folder (default is full dataset)
$Iterations = @{
    "Orchestration"   = 1
    "Content" = 6
    "Learner AI" = 1
}

$OverallExitCode = 0
$FolderResults = @{}
$JsonReports = @()

# Working copy of the environment that gets updated after each folder run,
# so tokens/variables saved by one folder (e.g. genarate_virtualId) carry
# forward into the next folder's Newman process. Each `newman run` is a
# separate process and does NOT write pm.environment.set() changes back to
# disk unless --export-environment is used.
$WorkingEnvironment = Join-Path $OutputDir "working-environment_${Timestamp}.json"
Copy-Item -Path $Environment -Destination $WorkingEnvironment -Force

foreach ($Folder in $Folders) {
    Write-Host "Running folder: $Folder"

    $HtmlReport = Join-Path $OutputDir "${Folder}_report_${Timestamp}.html"
    $JsonReport = Join-Path $OutputDir "${Folder}_report_${Timestamp}.json"

    $IterationArgs = @()
    if ($Iterations.ContainsKey($Folder) -and $Iterations[$Folder]) {
        $IterationArgs = @("--iteration-count", $Iterations[$Folder])
    }

    $ThresholdArgs = @()
    if ($MaxResponseTime) {
        $ThresholdArgs = @("--env-var", "maxResponseTime=$MaxResponseTime")
    }

    $NewmanArgs = @(
        "run", $Collection,
        "--folder", $Folder,
        "-e", $WorkingEnvironment,
        "-d", $Data,
        # cli is included so a failing assertion is named in the console (and
        # therefore in the CI log). Without it the only record of *what* failed
        # lives inside the HTML/JSON reports, which meant a CI failure showed
        # nothing but "Folder 'X' FAILED".
        "-r", "cli,htmlextra,json",
        "--insecure",
        # Successful assertions are suppressed so the failures stand out;
        # there are ~1100 per folder and printing them all buries the signal.
        "--reporter-cli-no-success-assertions",
        "--reporter-cli-no-banner",
        "--reporter-htmlextra-export", $HtmlReport,
        "--reporter-json-export", $JsonReport,
        "--reporter-htmlextra-title", "$Folder Test Report",
        "--reporter-htmlextra-browserTitle", "$Folder API Test",
        "--reporter-htmlextra-titleSize", "3",
        "--reporter-htmlextra-showOnlyFails", "false",
        "--reporter-htmlextra-showEnvironmentData", "true",
        "--reporter-htmlextra-logs", "true",
        "--reporter-htmlextra-showFolder=true",
        "--reporter-htmlextra-omitHeaders=false",
        "--export-environment", $WorkingEnvironment
    ) + $IterationArgs + $ThresholdArgs

    & newman @NewmanArgs
    $FolderExitCode = $LASTEXITCODE

    if ($FolderExitCode -ne 0) {
        Write-Host "Folder '$Folder' FAILED (exit code $FolderExitCode)" -ForegroundColor Red
        $FolderResults[$Folder] = "FAILED"
        $OverallExitCode = 1
    } else {
        Write-Host "Folder '$Folder' PASSED" -ForegroundColor Green
        $FolderResults[$Folder] = "PASSED"
    }

    $JsonReports += $JsonReport

    Write-Host "Report: $HtmlReport"
    Write-Host "-----------------------------------------------------"
}

# --- Build the email-safe HTML summary (never fail the run because of this) ---
try {
    & "$PSScriptRoot/build_email_summary.ps1" -Reports $JsonReports -OutputFile (Join-Path $OutputDir "email-summary.html")
} catch {
    Write-Host "WARNING: Failed to build email summary: $($_.Exception.Message)" -ForegroundColor Yellow
}

# --- Summary ---
Write-Host ""
Write-Host "======================= SUMMARY ======================="
foreach ($Folder in $Folders) {
    Write-Host ("{0,-15} {1}" -f $Folder, $FolderResults[$Folder])
}
Write-Host "========================================================"

if ($OverallExitCode -ne 0) {
    Write-Host "One or more folders FAILED. See reports in $OutputDir" -ForegroundColor Red
} else {
    Write-Host "All folders PASSED." -ForegroundColor Green
}

exit $OverallExitCode