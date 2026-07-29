# Opt-in deployment of a deterministic k6 package to SSM-only load generators.
[CmdletBinding()]
param(
    [string]$TerraformDirectory = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'infra/aws'),
    [ValidateSet('control', 'external', 'both')][string]$Target = 'both',
    [string]$ArtifactUri,
    [string]$PackageOutput,
    [switch]$OverwritePackageOutput,
    [switch]$Execute,
    [string]$Acknowledge
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageOutputWasExplicit = $PSBoundParameters.ContainsKey('PackageOutput')
if ([string]::IsNullOrWhiteSpace($PackageOutput)) { $PackageOutput = Join-Path $root 'build/loadgen-package/coupon-loadtest.tar.gz' }
function Require-Command([string]$Name) { if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "Required tool '$Name' was not found." } }
function Get-Outputs {
    if (-not (Test-Path $TerraformDirectory -PathType Container)) { throw "Terraform directory was not found: $TerraformDirectory" }
    $raw = & terraform "-chdir=$TerraformDirectory" output -json
    if ($LASTEXITCODE -ne 0) { throw 'terraform output failed.' }; return $raw | ConvertFrom-Json
}
function Output($o, [string]$name) { $p = $o.PSObject.Properties[$name]; if ($null -eq $p -or $null -eq $p.Value.value) { throw "Required Terraform output '$name' is missing." }; return $p.Value.value }
function Test-ContractUri([string]$Uri, [string]$Contract, [string]$Hash) {
    if ($Contract -notmatch '^s3://[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]/[A-Za-z0-9._/-]+/\*$') { throw 'artifact_contract must be a non-empty safe S3 wildcard prefix.' }
    if ($Uri -notmatch '^s3://[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]/[A-Za-z0-9._/-]*[a-f0-9]{64}\.tar\.gz$') { throw 'ArtifactUri must be a safe immutable hash-named .tar.gz S3 URI.' }
    if (-not $Uri.StartsWith($Contract.Substring(0, $Contract.Length - 1), [StringComparison]::Ordinal)) { throw 'ArtifactUri is outside artifact_contract.' }
    if (-not $Uri.EndsWith("$Hash.tar.gz", [StringComparison]::Ordinal)) { throw 'ArtifactUri filename must end with the package SHA-256.' }
}
function Wait-Ssm([string]$Region, [string]$CommandId, [string[]]$Ids) {
    $until = [DateTime]::UtcNow.AddMinutes(15)
    do {
        $raw = & aws ssm list-command-invocations --region $Region --command-id $CommandId --details --no-cli-pager --output json
        if ($LASTEXITCODE -ne 0) { throw "Could not poll SSM command $CommandId." }
        $items = @(($raw | ConvertFrom-Json).CommandInvocations)
        $bad = @($items | Where-Object { $_.Status -in @('Cancelled','TimedOut','Failed','Cancelling') })
        if ($bad.Count) { throw "SSM command failed: $($bad | Select-Object InstanceId,Status,StatusDetails | ConvertTo-Json -Compress)" }
        if ($items.Count -eq $Ids.Count -and @($items | Where-Object Status -ne 'Success').Count -eq 0) { return }
        if ([DateTime]::UtcNow -ge $until) { throw "Timed out waiting for SSM command $CommandId." }; Start-Sleep -Seconds 5
    } while ($true)
}
Require-Command terraform
Require-Command python
$packager = Join-Path $PSScriptRoot 'package_loadgen.py'
if (-not (Test-Path -LiteralPath $packager -PathType Leaf)) { throw "Deterministic packager was not found: $packager" }
if ($packageOutputWasExplicit -and (Test-Path -LiteralPath $PackageOutput -PathType Leaf) -and -not $OverwritePackageOutput) {
    throw "Refusing to overwrite explicitly supplied -PackageOutput. Pass -OverwritePackageOutput to replace it."
}
$packageParent = Split-Path -Parent $PackageOutput
if ([string]::IsNullOrWhiteSpace($packageParent)) { throw "PackageOutput must include a parent directory." }
if (-not (Test-Path -LiteralPath $packageParent -PathType Container)) {
    if ($packageOutputWasExplicit) { throw "Explicit PackageOutput parent directory must already exist." }
    New-Item -ItemType Directory -Path $packageParent -Force | Out-Null
}
$outputs = Get-Outputs
$contract = [string](Output $outputs 'artifact_contract')
$targets = @()
if ($Target -in @('control','both')) {
    $targets += [pscustomobject]@{ Region = 'ap-northeast-2'; Ids = @([string[]](Output $outputs 'control_load_generator_instance_ids')) }
}
if ($Target -in @('external','both')) {
    $targets += [pscustomobject]@{ Region = 'ap-northeast-1'; Ids = @([string[]](Output $outputs 'external_load_generator_instance_ids')) }
}
foreach ($targetSpec in $targets) {
    if ($targetSpec.Ids.Count -eq 0 -or @($targetSpec.Ids | Where-Object { $_ -notmatch '^i-[0-9a-f]{8,17}$' }).Count -gt 0 -or @($targetSpec.Ids | Select-Object -Unique).Count -ne $targetSpec.Ids.Count) {
        throw "Terraform output for $($targetSpec.Region) must contain unique valid EC2 instance IDs."
    }
}
$verificationDirectory = Join-Path ([IO.Path]::GetTempPath()) ("coupon-loadgen-verify-" + [Guid]::NewGuid().ToString('N'))
$verificationArchive = Join-Path $verificationDirectory 'coupon-loadtest.tar.gz'
$manifestProbe = Join-Path $verificationDirectory 'package-manifest.json'
New-Item -ItemType Directory -Path $verificationDirectory | Out-Null
$primaryFailure = $null
try {
    & python $packager --root $root --output $PackageOutput
    if ($LASTEXITCODE -ne 0) { throw 'Deterministic load-generator package creation failed.' }
    & python $packager --root $root --output $verificationArchive
    if ($LASTEXITCODE -ne 0) { throw 'Deterministic package verification build failed.' }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $PackageOutput).Hash.ToLowerInvariant()
    $verificationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $verificationArchive).Hash.ToLowerInvariant()
    if ($hash -cne $verificationHash) { throw 'Load-generator package is not byte-for-byte reproducible.' }
    & python $packager --extract-manifest $PackageOutput --output $manifestProbe
    if ($LASTEXITCODE -ne 0) { throw 'Load-generator embedded manifest extraction failed.' }
    $manifestHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestProbe).Hash.ToLowerInvariant()
} catch {
    $primaryFailure = $_
    throw
} finally {
    try {
        if (Test-Path -LiteralPath $verificationDirectory) {
            Remove-Item -LiteralPath $verificationDirectory -Recurse -Force -ErrorAction Stop
        }
    } catch {
        $cleanupMessage = "Temporary verification directory was retained at $verificationDirectory because cleanup failed: $($_.Exception.Message)"
        if ($null -ne $primaryFailure) {
            Write-Warning "$cleanupMessage Primary failure remains: $($primaryFailure.Exception.Message)"
        } else {
            throw $cleanupMessage
        }
    }
}
Write-Host "Local deterministic package: $PackageOutput SHA256=$hash"
if (-not $Execute) { Write-Host 'DRY RUN: package was created locally; no AWS command or upload was sent. Execute requires -Execute -Acknowledge I_ACKNOWLEDGE_AWS_COST -ArtifactUri s3://.../sha256.tar.gz.'; exit 0 }
if ($Acknowledge -cne 'I_ACKNOWLEDGE_AWS_COST') { throw 'Execution requires -Acknowledge I_ACKNOWLEDGE_AWS_COST.' }
Test-ContractUri $ArtifactUri $contract $hash
Require-Command aws
& aws s3 cp $PackageOutput $ArtifactUri --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Artifact upload failed.' }
$uri64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ArtifactUri))
$hash64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($hash))
$manifestHash64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($manifestHash))
$releaseValidator = @'
import hashlib
import json
import os
import stat
import sys

root = sys.argv[1]
expected_manifest_sha256 = sys.argv[2]
manifest_path = os.path.join(root, "package-manifest.json")
root_details = os.lstat(root)
if not stat.S_ISDIR(root_details.st_mode) or stat.S_ISLNK(root_details.st_mode):
    raise SystemExit("release root is not a real directory")
with open(manifest_path, "rb") as handle:
    manifest = handle.read()
if hashlib.sha256(manifest).hexdigest() != expected_manifest_sha256:
    raise SystemExit("release manifest hash does not match the requested package")
try:
    document = json.loads(manifest.decode("utf-8"))
except (UnicodeDecodeError, json.JSONDecodeError) as error:
    raise SystemExit("release manifest is not valid UTF-8 JSON: " + str(error))
canonical = json.dumps(document, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"
if not isinstance(document, dict) or manifest != canonical or set(document) != {"schema_version", "files"} or document["schema_version"] != 1 or not isinstance(document["files"], list):
    raise SystemExit("release manifest is not canonical schema version 1")
expected = {"package-manifest.json": None}
for entry in document["files"]:
    if not isinstance(entry, dict) or set(entry) != {"path", "sha256", "bytes"}:
        raise SystemExit("release manifest contains an invalid entry")
    name, digest, size = entry["path"], entry["sha256"], entry["bytes"]
    prefix = "coupon-loadtest/"
    if (
        not isinstance(name, str)
        or not name.startswith(prefix)
        or any(part in {"", ".", ".."} for part in name.split("/"))
        or not isinstance(digest, str)
        or len(digest) != 64
        or any(character not in "0123456789abcdef" for character in digest)
        or not isinstance(size, int)
        or isinstance(size, bool)
        or size < 0
    ):
        raise SystemExit("release manifest contains an unsafe entry")
    relative = name[len(prefix):]
    if relative == "package-manifest.json" or relative in expected:
        raise SystemExit("release manifest contains a duplicate payload")
    expected[relative] = (digest, size)
actual = {}
for directory, directories, files in os.walk(root, followlinks=False):
    for child in directories:
        child_path = os.path.join(directory, child)
        if stat.S_ISLNK(os.lstat(child_path).st_mode):
            raise SystemExit("release contains a symlinked directory")
    for child in files:
        child_path = os.path.join(directory, child)
        relative = os.path.relpath(child_path, root).replace(os.sep, "/")
        details = os.lstat(child_path)
        if not stat.S_ISREG(details.st_mode):
            raise SystemExit("release contains a non-regular payload: " + relative)
        actual[relative] = child_path
if set(actual) != set(expected):
    raise SystemExit("release regular-file set does not match its manifest")
for relative, metadata in expected.items():
    if metadata is None:
        continue
    digest, size = metadata
    actual_size = os.path.getsize(actual[relative])
    with open(actual[relative], "rb") as handle:
        actual_digest = hashlib.sha256(handle.read()).hexdigest()
    if actual_size != size or actual_digest != digest:
        raise SystemExit("release payload does not match its manifest: " + relative)
'@
$releaseValidator64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($releaseValidator))
foreach ($targetSpec in $targets) {
    $region64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($targetSpec.Region))
    $commands = @(
        'set -euo pipefail',
        "uri=`$(printf '%s' '$uri64' | base64 --decode)",
        "expected=`$(printf '%s' '$hash64' | base64 --decode)",
        "manifest_expected=`$(printf '%s' '$manifestHash64' | base64 --decode)",
        "region=`$(printf '%s' '$region64' | base64 --decode)",
        "validator64='$releaseValidator64'",
        'tmp=$(mktemp)',
        'stage=$(mktemp -d)',
        'release_stage=',
        'cleanup(){ status=$?; cleanup_failed=0; if [ -n "${tmp:-}" ] && [ -e "$tmp" ] && ! rm -f "$tmp"; then printf "Could not remove temporary archive; retained: %s\n" "$tmp" >&2; cleanup_failed=1; fi; if [ -n "${stage:-}" ] && [ -e "$stage" ] && ! rm -rf "$stage"; then printf "Could not remove temporary extraction directory; retained: %s\n" "$stage" >&2; cleanup_failed=1; fi; if [ -n "${release_stage:-}" ] && ! sudo rm -rf "$release_stage"; then printf "Could not remove temporary release directory; retained: %s\n" "$release_stage" >&2; cleanup_failed=1; fi; if [ "$cleanup_failed" -ne 0 ]; then printf "Temporary cleanup failed; retained paths are listed above.\n" >&2; if [ "$status" -eq 0 ]; then status=1; fi; fi; exit "$status"; }',
        'trap cleanup EXIT',
        'aws s3 cp "$uri" "$tmp" --region "$region" --only-show-errors',
        'printf "%s  %s\n" "$expected" "$tmp" | sha256sum --check --status',
        'tar -xzf "$tmp" -C "$stage"',
        'printf "%s" "$validator64" | base64 --decode > "$stage/validate_release.py"',
        'validate_release(){ python3 "$stage/validate_release.py" "$1" "$manifest_expected"; }',
        'validate_release "$stage/coupon-loadtest"',
        'test -x /usr/local/bin/k6',
        'k6_version=$(/usr/local/bin/k6 version)',
        'test -n "$k6_version"',
        'printf "BOOTSTRAP_K6_VERSION=%s\n" "$k6_version"',
        'sudo install -d -m 0755 /opt/coupon-loadtest-releases',
        'release_root=/opt/coupon-loadtest-releases',
        'release="$release_root/$expected"',
        'bootstrap_marker="$release_root/$expected.bootstrap-ok"',
        'if [ -e "$release" ]; then validate_release "$release"; else release_stage=$(sudo mktemp -d "$release_root/.${expected}.XXXXXX"); sudo tar -xzf "$tmp" -C "$release_stage"; validate_release "$release_stage/coupon-loadtest"; if sudo mv -T "$release_stage/coupon-loadtest" "$release"; then :; elif [ -e "$release" ]; then validate_release "$release"; else exit 1; fi; fi',
        'if [ -e "$bootstrap_marker" ]; then test "$(sudo cat "$bootstrap_marker")" = "$k6_version"; else marker_stage=$(sudo mktemp "$release_root/.${expected}.bootstrap.XXXXXX"); printf "%s\n" "$k6_version" | sudo tee "$marker_stage" >/dev/null; sudo chmod 0644 "$marker_stage"; sudo mv -Tf "$marker_stage" "$bootstrap_marker"; fi',
        'validate_release "$release"',
        'sudo ln -sfn "$release" /opt/coupon-loadtest.next',
        'sudo mv -Tf /opt/coupon-loadtest.next /opt/coupon-loadtest'
    )
    $result = & aws ssm send-command --region $targetSpec.Region --document-name AWS-RunShellScript --instance-ids $targetSpec.Ids --parameters ("commands=" + ($commands | ConvertTo-Json -Compress)) --comment 'coupon load-generator package deployment' --no-cli-pager --output json
    if ($LASTEXITCODE -ne 0) { throw "SSM deployment command was rejected in $($targetSpec.Region)." }; $id = ($result | ConvertFrom-Json).Command.CommandId; if ([string]::IsNullOrWhiteSpace($id)) { throw 'SSM response omitted command ID.' }; Wait-Ssm $targetSpec.Region $id $targetSpec.Ids; Write-Host "SSM load-generator deployment succeeded in $($targetSpec.Region): $id"
}
