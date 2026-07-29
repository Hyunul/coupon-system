# Local AWS load-test plan builder and opt-in k6 runner. It never changes AWS resources.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('control', 'external', 'capacity', 'worker-recovery', 'generator-calibration')][string]$RunType,
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][long]$EventId,
    [Parameter(Mandatory = $true)][long]$UserOffset,
    [Parameter(Mandatory = $true)][ValidateRange(1, 10000)][int]$Rate,
    [Parameter(Mandatory = $true)][string]$Duration,
    [Parameter(Mandatory = $true)][ValidateSet('normal', 'sold-out', 'calibration')][string]$ResultPolicy,
    [Parameter(Mandatory = $true)][string]$Regions,
    [Parameter(Mandatory = $true)][string]$InstanceTypes,
    [Parameter(Mandatory = $true)][string]$Jvm,
    [Parameter(Mandatory = $true)][string]$Pool,
    [Parameter(Mandatory = $true)][string]$MockNotify,
    [Parameter(Mandatory = $true)][ValidateRange(1, [long]::MaxValue)][long]$Users,
    [Parameter(Mandatory = $true)][ValidateRange(1, [long]::MaxValue)][long]$Stock,
    [Parameter(Mandatory = $true)][string]$Payload,
    [string]$RunId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'),
    [ValidateSet('reactive')][string]$ApplicationProfile = 'reactive',
    [string]$AwsCliProfile = $env:AWS_PROFILE,
    [ValidateRange(1, 20000)][int]$PreAllocatedVUs = 100,
    [ValidateRange(1, 20000)][int]$MaxVUs = 1000,
    [bool]$ClaimMode = $false,
    [bool]$DryRun = $true
)
$ErrorActionPreference = 'Stop'
function ConvertTo-DurationSeconds([string]$Value) {
    if ($Value -notmatch '^(?<amount>[1-9][0-9]*)(?<unit>ms|s|m|h)$') { throw 'Duration must be a positive integer followed by ms, s, m, or h.' }
    $amount = [decimal]$Matches.amount
    $seconds = switch ($Matches.unit) { 'ms' { $amount / 1000 } 's' { $amount } 'm' { $amount * 60 } 'h' { $amount * 3600 } }
    if ($seconds -le 0 -or $seconds -gt 3600) { throw 'Duration must be greater than zero and no more than 60 minutes.' }
    return $seconds
}
function Normalize-HttpsBaseUrl([string]$Value) {
    try { $uri = [Uri]$Value } catch { throw 'BaseUrl must be an absolute HTTPS ALB URL.' }
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Port -ne 443 -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') { throw 'BaseUrl must be an absolute HTTPS ALB URL without a port, path, query, fragment, or credentials.' }
    $normalizedHost = $uri.DnsSafeHost.ToLowerInvariant()
    if ($normalizedHost -notmatch '^[A-Za-z0-9.-]+$') { throw 'BaseUrl must be an absolute HTTPS ALB URL.' }
    return "https://$normalizedHost"
}
function ConvertTo-CanonicalRegions([string]$Value) {
    try { $regions = @(ConvertFrom-Json -InputObject $Value -ErrorAction Stop) } catch { throw 'Regions must be a JSON list of canonical AWS region identifiers.' }
    if (-not $regions.Count -or @($regions | Where-Object { $_ -isnot [string] -or $_ -notmatch '^[a-z]{2}-[a-z]+-[1-9][0-9]*$' }).Count -or @($regions | Select-Object -Unique).Count -ne $regions.Count) {
        throw 'Regions must be a non-empty JSON list of unique canonical AWS region identifiers.'
    }
    $canonical = @($regions | Sort-Object)
    if ((ConvertTo-Json -InputObject $canonical -Compress) -cne (ConvertTo-Json -InputObject $regions -Compress)) {
        throw 'Regions must be a canonically sorted JSON list without aliases.'
    }
    return ,$canonical
}
function Require-Git([string]$Root) {
    $commit = (& git -C $Root rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commit) -or $commit -notmatch '^[0-9a-f]{40}$') { throw 'A successful full git SHA is required for a reproducible plan.' }
    $status = @(& git -C $Root status --porcelain -- . ':(exclude).gjc/**')
    if ($LASTEXITCODE -ne 0) { throw 'A successful git status is required for a reproducible plan.' }
    return @{ Commit = $commit; Status = $status }
}
if ($MaxVUs -lt $PreAllocatedVUs) { throw 'MaxVUs must be greater than or equal to PreAllocatedVUs.' }
if ($EventId -lt 1) { throw 'EventId must be positive.' }
if (-not $ClaimMode) { throw 'ClaimMode must be true for AWS evidence-producing scenarios.' }
$normalizedBaseUrl = Normalize-HttpsBaseUrl $BaseUrl
if ([string]::IsNullOrWhiteSpace($RunId) -or $RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw 'RunId must be 1-64 safe characters.' }
$durationSeconds = ConvertTo-DurationSeconds $Duration
$canonicalRegions = ConvertTo-CanonicalRegions $Regions
if ($Payload -cne 'null-body') { throw "Payload must be the exact descriptor 'null-body' for GET scenarios." }
if ($UserOffset -lt 0 -or $UserOffset -gt [long]::MaxValue - ($Users - 1)) { throw 'UserOffset and Users exceed the supported non-negative user-ID range.' }
$scenario = switch ($RunType) { 'worker-recovery' { 'aws-worker-recovery.js' } 'generator-calibration' { 'aws-generator-calibration.js' } default { 'aws-capacity.js' } }
$allowedPolicies = switch ($RunType) { 'generator-calibration' { @('calibration') } 'worker-recovery' { @('normal') } default { @('normal', 'sold-out') } }
if ($ResultPolicy -notin $allowedPolicies) { throw "ResultPolicy '$ResultPolicy' is incompatible with RunType '$RunType'." }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$utcDate = [DateTime]::UtcNow.ToString('yyyyMMdd')
$evidenceDir = Join-Path $root (Join-Path 'evidence\aws' (Join-Path $utcDate $RunId))
if (Test-Path -LiteralPath $evidenceDir) { throw "Run evidence directory already exists and cannot be reused: $evidenceDir" }
$scenarioPath = Join-Path $root "k6/scenarios/$scenario"
$claimHelper = Join-Path $root 'k6/lib/aws-claim.js'
if (-not (Test-Path -LiteralPath $scenarioPath -PathType Leaf)) { throw "Scenario was not found: $scenarioPath" }
if (-not (Test-Path -LiteralPath $claimHelper -PathType Leaf)) { throw "Required claim capability helper was not found: $claimHelper" }
$git = Require-Git $root
New-Item -ItemType Directory -Path $evidenceDir | Out-Null
$packageManifestPath = Join-Path $evidenceDir 'package-manifest.json'
try {
    & python (Join-Path $root 'scripts/aws/package_loadgen.py') --root $root --output $packageManifestPath --manifest-only
    if ($LASTEXITCODE -ne 0) { throw 'package_loadgen.py manifest-only mode failed.' }
    $packageManifestSha256 = (Get-FileHash -LiteralPath $packageManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $summaryPath = Join-Path $evidenceDir 'k6-summary.json'
    $manifest = [ordered]@{
        run_id = $RunId; run_type = $RunType; created_at_utc = [DateTime]::UtcNow.ToString('o')
        commit = $git.Commit; git_dirty = $git.Status.Count -gt 0; git_status = $git.Status
        application_profile = $ApplicationProfile; aws_cli_profile = $(if ($AwsCliProfile) { $AwsCliProfile } else { 'unset' }); record_mode = 'stream'
        regions = $canonicalRegions; instance_types = $InstanceTypes; jvm = $Jvm; pool = $Pool; mock_notify = $MockNotify
        event_id = $EventId; users = $Users; stock = $Stock; rate = $Rate; duration = $Duration; duration_seconds = $durationSeconds; base_url = $normalizedBaseUrl
        user_offset = $UserOffset; payload_descriptor = $Payload; request_payload_bytes = 0; claim_mode = $ClaimMode; result_policy = $ResultPolicy; dry_run = $DryRun; preallocated_vus = $PreAllocatedVUs; max_vus = $MaxVUs
        scenario = $scenario; scenario_sha256 = (Get-FileHash -LiteralPath $scenarioPath -Algorithm SHA256).Hash.ToLowerInvariant(); package_manifest_sha256 = $packageManifestSha256
        expected_attempts = [decimal]$Rate * $durationSeconds
    }
    $manifestPath = Join-Path $evidenceDir 'manifest.json'
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    if ($DryRun) { Write-Host "DryRun: reviewed plan written to $evidenceDir; k6 was not invoked."; exit 0 }
    $env:BASE_URL=$normalizedBaseUrl; $env:EVENT_ID="$EventId"; $env:USER_OFFSET="$UserOffset"; $env:RATE="$Rate"; $env:DURATION=$Duration; $env:RUN_ID=$RunId
    $env:PRE_ALLOCATED_VUS="$PreAllocatedVUs"; $env:MAX_VUS="$MaxVUs"; $env:CLAIM_MODE="$ClaimMode".ToLowerInvariant(); $env:RESULT_POLICY=$ResultPolicy; $env:STOCK="$Stock"; $env:SUMMARY_PATH=$summaryPath
    & k6 run $scenarioPath
    $k6ExitCode = $LASTEXITCODE
    $summaryPresent = Test-Path -LiteralPath $summaryPath -PathType Leaf
    $completed = [ordered]@{ schema_version = 1; run_id = $RunId; completed_at_utc = [DateTime]::UtcNow.ToString('o'); k6_exit_code = $k6ExitCode; summary_present = $summaryPresent; status = $(if ($k6ExitCode -eq 0 -and $summaryPresent) { 'completed' } else { 'failed' }) }
    $completed | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidenceDir 'execution-result.json') -Encoding UTF8
    if (-not $summaryPresent) { throw "k6 did not produce the required summary. Evidence remains at $evidenceDir." }
    if ($k6ExitCode -ne 0) { throw "k6 exited with code $k6ExitCode. Evidence remains at $evidenceDir." }
} catch {
    if (-not $DryRun -and (Test-Path -LiteralPath $evidenceDir) -and -not (Test-Path -LiteralPath (Join-Path $evidenceDir 'execution-result.json'))) {
        [ordered]@{ schema_version = 1; run_id = $RunId; completed_at_utc = [DateTime]::UtcNow.ToString('o'); status = 'failed'; error = $_.Exception.Message } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidenceDir 'execution-result.json') -Encoding UTF8
    }
    throw
}
