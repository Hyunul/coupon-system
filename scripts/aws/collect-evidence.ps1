# Collect immutable raw evidence and separate, text-only redacted derivatives.
# DryRun is the default and never contacts endpoints, Terraform, or AWS.
[CmdletBinding()]
param(
    [string]$CloudWatchExportPath,
    [string]$PrometheusExportPath,
    [string]$AwsDescribePath,
    [string]$RedisConsistencyPath,
    [string]$MySqlConsistencyPath,
    [string]$CloudWatchEndpoint,
    [string]$PrometheusEndpoint,
    [string]$S3PublicationManifestUri,
    [string]$S3PublicationManifestVersionId,
    [string]$LocalPublicationManifestPath,
    [string]$TerraformDirectory = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'infra/aws'),
    [string]$EvidenceDirectory,
    [ValidateRange(1, 104857600)][Int64]$MaximumInputBytes = 10485760,
    [bool]$DryRun = $true,
    [string]$Acknowledge
)

$ErrorActionPreference = 'Stop'
$utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$evidenceDirectoryWasExplicit = $PSBoundParameters.ContainsKey('EvidenceDirectory')
$localInputs = @(
    @{ Path = $CloudWatchExportPath; Name = 'cloudwatch-export.txt' },
    @{ Path = $PrometheusExportPath; Name = 'prometheus-export.txt' },
    @{ Path = $AwsDescribePath; Name = 'aws-describe.json' },
    @{ Path = $RedisConsistencyPath; Name = 'redis-consistency.txt' },
    @{ Path = $MySqlConsistencyPath; Name = 'mysql-consistency.txt' }
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Path) }
$hasRemoteManifest = -not [string]::IsNullOrWhiteSpace($S3PublicationManifestUri) -or -not [string]::IsNullOrWhiteSpace($S3PublicationManifestVersionId)
if ($hasRemoteManifest -and ([string]::IsNullOrWhiteSpace($S3PublicationManifestUri) -or [string]::IsNullOrWhiteSpace($S3PublicationManifestVersionId))) {
    throw 'S3 evidence collection requires both -S3PublicationManifestUri and -S3PublicationManifestVersionId.'
}
if ($hasRemoteManifest -and -not [string]::IsNullOrWhiteSpace($LocalPublicationManifestPath)) { throw 'Specify either an S3 publication manifest or a local publication manifest, not both.' }
if ($localInputs.Count -eq 0 -and [string]::IsNullOrWhiteSpace($CloudWatchEndpoint) -and [string]::IsNullOrWhiteSpace($PrometheusEndpoint) -and -not $hasRemoteManifest -and [string]::IsNullOrWhiteSpace($LocalPublicationManifestPath)) {
    throw 'Provide at least one local export, endpoint, or publication manifest.'
}

function Test-ReparsePoint([string]$Path, [string]$Label) {
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Label must not be a reparse point or symbolic link." }
}
function New-OwnedEvidenceDirectory {
    $ownedDirectory = $EvidenceDirectory
    if ([string]::IsNullOrWhiteSpace($ownedDirectory)) {
        $base = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'evidence\aws'
        $ownedDirectory = Join-Path $base (([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')) + '-' + [Guid]::NewGuid().ToString('N'))
    }
    if (Test-Path -LiteralPath $ownedDirectory) { throw 'EvidenceDirectory must not already exist; collector never reuses caller trees.' }
    $parent = Split-Path -Parent $ownedDirectory
    if ([string]::IsNullOrWhiteSpace($parent)) { throw 'EvidenceDirectory must include a parent directory.' }
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        if ($evidenceDirectoryWasExplicit) { throw 'Explicit EvidenceDirectory parent must already exist.' }
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
    Test-ReparsePoint $parent 'EvidenceDirectory parent'
    New-Item -ItemType Directory -Path $ownedDirectory -ErrorAction Stop | Out-Null
    Test-ReparsePoint $ownedDirectory 'EvidenceDirectory'
    foreach ($name in @('raw', 'redacted')) { New-Item -ItemType Directory -Path (Join-Path $ownedDirectory $name) -ErrorAction Stop | Out-Null }
    $script:EvidenceDirectory = $ownedDirectory
    return $script:EvidenceDirectory
}
function Get-RelativeHashLines([string]$Directory) {
    @(Get-ChildItem -LiteralPath $Directory -File | Sort-Object Name | ForEach-Object {
        '{0}  {1}' -f (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant(), $_.Name
    })
}
function Assert-TextFile([string]$Path, [string]$Label) {
    Test-ReparsePoint $Path $Label
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Length -gt $MaximumInputBytes) { throw "$Label exceeds MaximumInputBytes." }
    $bytes = [IO.File]::ReadAllBytes($Path)
    try { $text = $utf8Strict.GetString($bytes) } catch { throw "$Label is not valid UTF-8 text; binary or non-UTF-8 inputs are rejected." }
    if ($text.IndexOf([char]0) -ge 0) { throw "$Label contains NUL bytes and is rejected as binary." }
    return $text
}
function Copy-LocalInput([hashtable]$Entry) {
    if (-not (Test-Path -LiteralPath $Entry.Path -PathType Leaf)) { throw 'A local evidence input does not exist.' }
    [void](Assert-TextFile $Entry.Path 'Local evidence input')
    [IO.File]::Copy((Get-Item -LiteralPath $Entry.Path -Force).FullName, (Join-Path $EvidenceDirectory "raw/$($Entry.Name)"), $false)
}
function Redact-Text([string]$Text) {
    $Text = [regex]::Replace($Text, '\b(?:AKIA|ASIA)[0-9A-Z]{16}\b', '[REDACTED_AWS_ACCESS_KEY]', 'IgnoreCase')
    $Text = [regex]::Replace($Text, '(?im)(["'']authorization["'']\s*:\s*)("(?:\\.|[^"\\\r\n])*"|[^\s,}\r\n]+)', '$1[REDACTED]')
    $Text = [regex]::Replace($Text, '(?im)(\bauthorization\s*[:=]\s*)[^\r\n]*', '$1[REDACTED]')
    $Text = [regex]::Replace($Text, '(?im)\b(session(?:[_ -]?token)?|x-amz-security-token|api[_ -]?key|cookie|password|secret(?:[_ -]?access)?[_ -]?key|token|client[_ -]?secret|refresh[_ -]?token|private[_ -]?key|access[_ -]?token)\b(\s*[:=]\s*|"\s*:\s*")([^\s,;"}\r\n]+|"[^"]*")', '$1$2[REDACTED]')
    $Text = [regex]::Replace($Text, '([?&](?:(?:access|refresh)[_-]?token|client[_-]?secret|private[_-]?key|api[_-]?key|token|signature|x-amz-signature|x-amz-credential|password|session)=)[^&#\s]+', '$1[REDACTED]', 'IgnoreCase')
    $Text = [regex]::Replace($Text, '\b\d{12}\b', '[REDACTED_AWS_ACCOUNT]')
    $Text = [regex]::Replace($Text, '(?i)(?<![0-9a-f:.])(?<ip>(?:(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}|(?:[0-9a-f]{0,4}:){2,7}(?:\d{1,3}\.){3}\d{1,3}))(?![0-9a-f:.])', {
        param($match)
        $candidate = $match.Groups['ip'].Value
        [Net.IPAddress]$parsed = $null
        if ([Net.IPAddress]::TryParse($candidate, [ref]$parsed) -and $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6 -and ($candidate.Contains('::') -or @($candidate.Split(':')).Count -eq 8)) { return '[REDACTED_IPV6]' }
        return $candidate
    })
    $Text = [regex]::Replace($Text, '\b(?:\d{1,3}\.){3}\d{1,3}\b', '[REDACTED_IPV4]')
    return $Text
}
function Write-RedactedDerivative([string]$RawFile) {
    $text = Assert-TextFile $RawFile 'Raw evidence file'
    $name = Split-Path -Leaf $RawFile
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory "redacted/$name"), (Redact-Text $text), $utf8NoBom)
}
function Get-TerraformOutput([string]$Name) {
    if (-not (Test-Path -LiteralPath $TerraformDirectory -PathType Container)) { throw 'Terraform directory was not found.' }
    $raw = & terraform "-chdir=$TerraformDirectory" output -json
    if ($LASTEXITCODE -ne 0) { throw 'terraform output failed.' }
    $property = ($raw | ConvertFrom-Json).PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value.value) { throw "Required Terraform output '$Name' is missing." }
    return [string]$property.Value.value
}
function Parse-S3Uri([string]$Uri, [string]$Label) {
    if ($Uri -notmatch '^s3://([a-z0-9][a-z0-9.-]{1,61}[a-z0-9])/([A-Za-z0-9._/-]+)$') { throw "$Label must be a safe S3 object URI." }
    return @{ Bucket = $Matches[1]; Key = $Matches[2] }
}
function Assert-WithinEvidenceAuthority([string]$Bucket, [string]$Key, [string]$Authority) {
    if ($Authority -notmatch '^s3://([a-z0-9][a-z0-9.-]{1,61}[a-z0-9])/(.+)/\*$') { throw 'generator_evidence_s3_uri is not a safe non-empty wildcard prefix.' }
    if ($Bucket -cne $Matches[1] -or -not $Key.StartsWith($Matches[2] + '/', [StringComparison]::Ordinal)) { throw 'Publication evidence object is outside generator_evidence_s3_uri.' }
}
function Assert-ExactProperties([object]$Value, [string[]]$Expected, [string]$Label) {
    if ($null -eq $Value) { throw "$Label is required." }
    $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actual.Count -ne $Expected.Count -or @($actual | Where-Object { $_ -cnotin $Expected }).Count -ne 0 -or @($Expected | Where-Object { $_ -cnotin $actual }).Count -ne 0) {
        throw "$Label has an invalid schema."
    }
}
function Get-ManifestObjects([object]$Manifest) {
    Assert-ExactProperties $Manifest @('schema_version', 'objects') 'Publication manifest'
    if (($Manifest.schema_version -isnot [Int32] -and $Manifest.schema_version -isnot [Int64]) -or $Manifest.schema_version -ne 1) { throw 'Publication manifest schema_version must be the JSON number 1.' }
    if ($Manifest.objects -isnot [Array]) { throw 'Publication manifest objects must be an array.' }

    $requiredNames = @('plan-manifest.json', 'runtime-manifest.json', 'execution-result.json', 'package-manifest.json', 'k6-summary.json', 'k6-console.txt')
    $entries = @($Manifest.objects)
    if ($entries.Count -ne $requiredNames.Count) { throw 'Publication manifest must contain exactly six objects.' }

    $seenNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $validated = @()
    $commonBucket = $null
    $commonDirectory = $null
    foreach ($entry in $entries) {
        Assert-ExactProperties $entry @('name', 'bucket', 'key', 'sha256', 'version_id') 'Publication object'
        if ($entry.name -isnot [string] -or $entry.bucket -isnot [string] -or $entry.key -isnot [string] -or $entry.sha256 -isnot [string] -or $entry.version_id -isnot [string]) { throw 'Publication object fields must be strings.' }
        $name = [string]$entry.name
        $bucket = [string]$entry.bucket
        $key = [string]$entry.key
        $version = [string]$entry.version_id
        $sha256 = [string]$entry.sha256
        if ($name -cnotin $requiredNames -or -not $seenNames.Add($name)) { throw 'Publication manifest object names must be the six unique required names.' }
        if ([string]::IsNullOrWhiteSpace($bucket) -or [string]::IsNullOrWhiteSpace($key) -or [string]::IsNullOrWhiteSpace($version)) { throw 'Each publication object requires explicit name, bucket, key, and version_id.' }
        if ($key -notmatch '^[A-Za-z0-9._/-]+$' -or $sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Publication object key or SHA-256 is invalid.' }
        $separator = $key.LastIndexOf('/')
        if ($separator -le 0 -or $separator -eq $key.Length - 1 -or $key.Substring($separator + 1) -cne $name) { throw 'Publication object key basename must exactly match its declared name in a non-empty run directory.' }
        $directory = $key.Substring(0, $separator)
        if ($null -eq $commonBucket) {
            $commonBucket = $bucket
            $commonDirectory = $directory
        } elseif ($bucket -cne $commonBucket -or $directory -cne $commonDirectory) {
            throw 'Publication objects must share one bucket and common run directory.'
        }
        $validated += @{ Name = $name; Bucket = $bucket; Key = $key; Directory = $directory; VersionId = $version; Sha256 = $sha256.ToLowerInvariant() }
    }
    if ($seenNames.Count -ne $requiredNames.Count) { throw 'Publication manifest is missing a required object.' }
    return $validated
}
function Get-VersionedS3ContentLength([string]$Bucket, [string]$Key, [string]$VersionId) {
    $headOutput = & aws s3api head-object --bucket $Bucket --key $Key --version-id $VersionId --output json --no-cli-pager
    if ($LASTEXITCODE -ne 0) { throw 'Exact-version S3 head-object failed.' }
    try { $head = $headOutput | ConvertFrom-Json } catch { throw 'Exact-version S3 head-object returned invalid JSON.' }
    if ($null -eq $head.PSObject.Properties['ContentLength']) { throw 'Exact-version S3 head-object omitted ContentLength.' }
    try { $contentLength = [Int64]$head.ContentLength } catch { throw 'Exact-version S3 ContentLength is invalid.' }
    if ($contentLength -lt 0 -or $contentLength -gt $MaximumInputBytes) { throw 'Exact-version S3 object exceeds MaximumInputBytes.' }
    return $contentLength
}
function Download-VersionedS3Evidence([string]$Bucket, [string]$Key, [string]$VersionId, [string]$Destination, [string]$ExpectedSha256) {
    $contentLength = Get-VersionedS3ContentLength $Bucket $Key $VersionId
    $completed = $false
    try {
        & aws s3api get-object --bucket $Bucket --key $Key --version-id $VersionId $Destination --no-cli-pager | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Exact-version S3 evidence download failed.' }
        if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) { throw 'Exact-version S3 evidence download produced no file.' }
        $actualLength = (Get-Item -LiteralPath $Destination -Force).Length
        if ($actualLength -ne $contentLength -or $actualLength -gt $MaximumInputBytes) { throw 'Downloaded S3 evidence exceeds its verified ContentLength or MaximumInputBytes.' }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash.ToLowerInvariant()
            if ($actual -cne $ExpectedSha256) { throw 'Downloaded S3 evidence SHA-256 does not match its publication manifest.' }
        }
        $completed = $true
    } finally {
        if (-not $completed -and (Test-Path -LiteralPath $Destination -PathType Leaf)) { Remove-Item -LiteralPath $Destination -Force -ErrorAction Stop }
    }
}
function Copy-VersionedS3Evidence {
    if (-not $hasRemoteManifest -and [string]::IsNullOrWhiteSpace($LocalPublicationManifestPath)) { return }
    if ($Acknowledge -cne 'I_ACKNOWLEDGE_AWS_COST') { throw 'Credentialed S3 evidence reads require -Acknowledge I_ACKNOWLEDGE_AWS_COST.' }
    if (-not (Get-Command terraform -ErrorAction SilentlyContinue) -or -not (Get-Command aws -ErrorAction SilentlyContinue)) { throw 'S3 evidence download requires terraform and aws.' }
    $authority = Get-TerraformOutput 'generator_evidence_s3_uri'
    if ($hasRemoteManifest) {
        $manifestLocation = Parse-S3Uri $S3PublicationManifestUri 'S3PublicationManifestUri'
        Assert-WithinEvidenceAuthority $manifestLocation.Bucket $manifestLocation.Key $authority
        $manifestRaw = Join-Path $EvidenceDirectory 'raw/publication-manifest.json'
        Download-VersionedS3Evidence $manifestLocation.Bucket $manifestLocation.Key $S3PublicationManifestVersionId $manifestRaw ''
    } else {
        if (-not (Test-Path -LiteralPath $LocalPublicationManifestPath -PathType Leaf)) { throw 'LocalPublicationManifestPath does not exist.' }
        [void](Assert-TextFile $LocalPublicationManifestPath 'Local publication manifest')
        $manifestLocation = @{ Bucket = ''; Key = '' }
        [IO.File]::Copy((Get-Item -LiteralPath $LocalPublicationManifestPath).FullName, (Join-Path $EvidenceDirectory 'raw/publication-manifest.json'), $false)
        $manifestRaw = Join-Path $EvidenceDirectory 'raw/publication-manifest.json'
    }
    $manifestText = Assert-TextFile $manifestRaw 'Publication manifest'
    try { $manifest = $manifestText | ConvertFrom-Json } catch { throw 'Publication manifest must be valid JSON.' }
    $objects = Get-ManifestObjects $manifest
    if ($hasRemoteManifest) {
        $runDirectory = $objects[0].Directory
        if ($manifestLocation.Bucket -cne $objects[0].Bucket -or $manifestLocation.Key.LastIndexOf('/') -le 0 -or $manifestLocation.Key.Substring(0, $manifestLocation.Key.LastIndexOf('/')) -cne $runDirectory) {
            throw 'Remote publication manifest URI must be in the publication run directory.'
        }
    }
    foreach ($object in $objects) {
        Assert-WithinEvidenceAuthority $object.Bucket $object.Key $authority
        $destination = Join-Path $EvidenceDirectory ('raw/s3-' + ('{0:D3}' -f ([array]::IndexOf($objects, $object) + 1)) + '-' + [IO.Path]::GetFileName($object.Key))
        Download-VersionedS3Evidence $object.Bucket $object.Key $object.VersionId $destination $object.Sha256
    }
}

$EvidenceDirectory = New-OwnedEvidenceDirectory
try {
$sanitizedProvenance = [ordered]@{ collected_at_utc = [DateTime]::UtcNow.ToString('o'); dry_run = $DryRun; local_input_count = $localInputs.Count; cloudwatch_endpoint_requested = -not [string]::IsNullOrWhiteSpace($CloudWatchEndpoint); prometheus_endpoint_requested = -not [string]::IsNullOrWhiteSpace($PrometheusEndpoint); remote_publication_manifest_requested = $hasRemoteManifest; local_publication_manifest_requested = -not [string]::IsNullOrWhiteSpace($LocalPublicationManifestPath) }
$sanitizedProvenance | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'collection-provenance.json') -Encoding UTF8
if ($DryRun) { Write-Host 'DryRun: owned evidence directory contains sanitized provenance only; no network access or input copies occurred.'; exit 0 }

foreach ($input in $localInputs) { Copy-LocalInput $input }
function Get-ReadOnlyExport([string]$Endpoint, [string]$DestinationName) {
    if ([string]::IsNullOrWhiteSpace($Endpoint)) { return }
    if ($Endpoint -notmatch '^https://') { throw 'Endpoint must be an absolute HTTPS URL.' }
    $destination = Join-Path $EvidenceDirectory "raw/$DestinationName"
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $response = $null
    $source = $null
    $target = $null
    $completed = $false
    try {
        $response = $client.GetAsync($Endpoint, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) { throw 'Endpoint returned a non-success status.' }
        $contentLength = $response.Content.Headers.ContentLength
        if ($null -ne $contentLength -and [Int64]$contentLength -gt $MaximumInputBytes) { throw 'Endpoint export exceeds MaximumInputBytes.' }

        $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $target = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] 81920
        [Int64]$total = 0
        while (($read = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($total + $read -gt $MaximumInputBytes) { throw 'Endpoint export exceeds MaximumInputBytes.' }
            $target.Write($buffer, 0, $read)
            $total += $read
        }
        if ($null -ne $contentLength -and $total -ne [Int64]$contentLength) { throw 'Endpoint export length does not match Content-Length.' }
        $completed = $true
    } finally {
        if ($null -ne $target) { $target.Dispose() }
        if ($null -ne $source) { $source.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        $client.Dispose()
        if (-not $completed -and (Test-Path -LiteralPath $destination -PathType Leaf)) { Remove-Item -LiteralPath $destination -Force -ErrorAction Stop }
    }
    [void](Assert-TextFile $destination 'Endpoint export')
}
Get-ReadOnlyExport $CloudWatchEndpoint 'cloudwatch-endpoint.txt'
Get-ReadOnlyExport $PrometheusEndpoint 'prometheus-endpoint.txt'
Copy-VersionedS3Evidence
Get-ChildItem -LiteralPath (Join-Path $EvidenceDirectory 'raw') -File | ForEach-Object { Write-RedactedDerivative $_.FullName }
Get-RelativeHashLines (Join-Path $EvidenceDirectory 'raw') | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'raw/SHA256SUMS') -Encoding ASCII
Get-RelativeHashLines (Join-Path $EvidenceDirectory 'redacted') | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'redacted/SHA256SUMS') -Encoding ASCII
Write-Host 'Raw and separately redacted evidence with SHA256SUMS were written to the owned evidence directory.'
} catch {
    $primary = $_
    if (Test-Path -LiteralPath $EvidenceDirectory) {
        try { Remove-Item -LiteralPath $EvidenceDirectory -Recurse -Force -ErrorAction Stop }
        catch { throw "$($primary.Exception.Message) Evidence directory cleanup also failed for '$EvidenceDirectory': $($_.Exception.Message)" }
    }
    throw $primary
}
