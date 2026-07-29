# Opt-in artifact deployment. It never runs terraform apply.
[CmdletBinding()]
param(
    [string]$Region,
    [string]$TerraformDirectory = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "infra/aws"),
    [string]$ArtifactUri,
    [string]$ExpectedSha256,
    [switch]$Package,
    [switch]$Execute,
    [string]$Acknowledge
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "Required tool '$Name' was not found." }
}
function Get-TerraformOutputs {
    if (-not (Test-Path $TerraformDirectory -PathType Container)) { throw "Terraform directory was not found: $TerraformDirectory" }
    $raw = & terraform -chdir=$TerraformDirectory output -json
    if ($LASTEXITCODE -ne 0) { throw "terraform output failed; apply the reviewed Terraform plan separately before deployment." }
    return ($raw | ConvertFrom-Json)
}
function Get-OutputValue($Outputs, [string]$Name) {
    $property = $Outputs.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value.value) { throw "Required Terraform output '$Name' is missing." }
    return $property.Value.value
}
function Test-ArtifactUri([string]$Uri, [string]$ArtifactContract, [string]$Sha256) {
    if ($ArtifactContract -notmatch '^s3://[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]/(?:[A-Za-z0-9._/-]+/)?\*$') {
        throw "Terraform output artifact_contract is not a safe private S3 bucket/prefix pattern."
    }
    if ($Sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw "-ExpectedSha256 must be a SHA-256 digest." }
    if ($Uri -notmatch '^s3://[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]/[A-Za-z0-9._/-]*[a-fA-F0-9]{64}[A-Za-z0-9._-]*\.jar$') {
        throw "Execution requires a safe content-addressed private S3 JAR URI whose filename includes its SHA-256 digest."
    }
    $contractBase = $ArtifactContract.Substring(0, $ArtifactContract.Length - 1)
    if (-not $Uri.StartsWith($contractBase, [System.StringComparison]::Ordinal)) {
        throw "ArtifactUri must be inside the Terraform output artifact_contract bucket/prefix."
    }
    if ($Uri -notmatch [regex]::Escape($Sha256) + '[A-Za-z0-9._-]*\.jar$') {
        throw "ArtifactUri filename must include -ExpectedSha256."
    }
}
function Wait-SsmCommand([string]$CommandId, [string[]]$InstanceIds, [string]$Label) {
    $deadline = [DateTime]::UtcNow.AddMinutes(10)
    do {
        $raw = aws ssm list-command-invocations --region $Region --command-id $CommandId --details --no-cli-pager --output json
        if ($LASTEXITCODE -ne 0) { throw "Could not poll SSM $Label deployment command $CommandId." }
        $invocations = @(($raw | ConvertFrom-Json).CommandInvocations)
        $pending = @($invocations | Where-Object { $_.Status -in @('Pending', 'InProgress', 'Delayed', 'Cancelling') })
        $failed = @($invocations | Where-Object { $_.Status -in @('Cancelled', 'TimedOut', 'Failed') })
        if ($failed.Count -gt 0) {
            throw "SSM $Label deployment failed: $(($failed | Select-Object InstanceId, Status, StatusDetails | ConvertTo-Json -Compress))."
        }
        if ($invocations.Count -eq $InstanceIds.Count -and $pending.Count -eq 0 -and @($invocations | Where-Object { $_.Status -ne 'Success' }).Count -eq 0) {
            Write-Host "SSM $Label deployment succeeded on $($InstanceIds.Count) instance(s)."
            return
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Timed out waiting for SSM $Label deployment command ${CommandId}: $($raw)."
        }
        Start-Sleep -Seconds 5
    } while ($true)
}
function Wait-ApiTargetHealth([string]$TargetGroupArn, [string[]]$ExpectedInstanceIds) {
    $expectedIds = @($ExpectedInstanceIds | ForEach-Object { [string]$_ })
    if ($expectedIds.Count -eq 0 -or @($expectedIds | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0 -or @($expectedIds | Select-Object -Unique).Count -ne $expectedIds.Count) {
        throw "Terraform output api_instance_ids must contain a non-empty exact set of unique instance IDs."
    }
    $deadline = [DateTime]::UtcNow.AddMinutes(10)
    $lastDescriptions = @()
    do {
        $targetHealth = & aws elbv2 describe-target-health --region $Region --target-group-arn $TargetGroupArn --no-cli-pager --output json
        if ($LASTEXITCODE -ne 0) { throw "ALB target-health verification failed." }
        $lastDescriptions = @((($targetHealth | ConvertFrom-Json).TargetHealthDescriptions))
        $actualIds = @($lastDescriptions | ForEach-Object { [string]$_.Target.Id })
        $hasExactTargets = $actualIds.Count -eq $expectedIds.Count -and
            @($actualIds | Select-Object -Unique).Count -eq $actualIds.Count -and
            @($actualIds | Where-Object { $_ -notin $expectedIds }).Count -eq 0
        $allHealthy = @($lastDescriptions | Where-Object { $_.TargetHealth.State -ne 'healthy' }).Count -eq 0
        if ($hasExactTargets -and $allHealthy) {
            Write-Host "ALB reports all expected API targets healthy."
            return
        }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Seconds 5
    } while ($true)
    $actualIds = @($lastDescriptions | ForEach-Object { [string]$_.Target.Id })
    $missingIds = @($expectedIds | Where-Object { $_ -notin $actualIds })
    $unexpectedIds = @($actualIds | Where-Object { $_ -notin $expectedIds })
    $diagnostics = $lastDescriptions | ForEach-Object {
        [pscustomobject]@{
            Id = $_.Target.Id
            State = $_.TargetHealth.State
            Reason = $_.TargetHealth.Reason
            Description = $_.TargetHealth.Description
        }
    } | ConvertTo-Json -Compress
    throw "Timed out waiting for exact healthy API targets. Missing: $($missingIds -join ', '); unexpected: $($unexpectedIds -join ', '); final target health: $diagnostics"
}
function Assert-InstanceIds([string[]]$InstanceIds, [string]$Name) {
    if ($InstanceIds.Count -eq 0 -or
        @($InstanceIds | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -notmatch '^i-[0-9a-f]{8,17}$' }).Count -gt 0 -or
        @($InstanceIds | Select-Object -Unique).Count -ne $InstanceIds.Count) {
        throw "Terraform output $Name must contain a non-empty exact set of unique EC2 instance IDs."
    }
}

function Assert-DeploymentTargets([string[]]$ApiIds, [string[]]$WorkerIds, [string]$TargetGroupArn) {
    Assert-InstanceIds -InstanceIds $ApiIds -Name "api_instance_ids"
    Assert-InstanceIds -InstanceIds $WorkerIds -Name "worker_instance_ids"
    if (@($ApiIds | Where-Object { $_ -in $WorkerIds }).Count -ne 0) {
        throw "Terraform outputs api_instance_ids and worker_instance_ids must be disjoint."
    }
    if ($TargetGroupArn -notmatch '^arn:aws:elasticloadbalancing:ap-northeast-2:[0-9]{12}:targetgroup/[A-Za-z0-9-]{1,32}/[0-9a-f]{32}$') {
        throw "Terraform output api_target_group_arn must be an ap-northeast-2 ELB target-group ARN with a 12-digit account and target-group resource."
    }
}

Require-Command terraform
if ($Region -cne "ap-northeast-2") { throw "The approved target stack region is ap-northeast-2; pass -Region ap-northeast-2." }
if ($Package) {
    Write-Warning "LOCAL BUILD: bootJar is explicitly requested; this does not upload or deploy an artifact."
    & (Join-Path $root "gradlew.bat") bootJar
    if ($LASTEXITCODE -ne 0) { throw "bootJar failed." }
    Write-Host "Package created under build/libs. Upload it through the approved private S3 release process, then pass its versioned s3:// URI as -ArtifactUri."
}

$outputs = Get-TerraformOutputs
$albUrl = Get-OutputValue $outputs "alb_url"
$apiTargetGroupArn = Get-OutputValue $outputs "api_target_group_arn"
$apiIds = @([string[]](Get-OutputValue $outputs "api_instance_ids"))
$workerIds = @([string[]](Get-OutputValue $outputs "worker_instance_ids"))
$mockNotifyId = Get-OutputValue $outputs "mock_notify_instance_id"
$monitoringId = Get-OutputValue $outputs "monitoring_instance_id"
$rdsEndpoint = Get-OutputValue $outputs "rds_endpoint"
$redisEndpoint = Get-OutputValue $outputs "redis_endpoint"
$expiresAt = Get-OutputValue $outputs "expires_at"
$ttlLimitations = Get-OutputValue $outputs "ttl_cleanup_limitations"
$artifactContract = Get-OutputValue $outputs "artifact_contract"
$primaryRegion = Get-OutputValue $outputs "primary_region"
$externalRegion = Get-OutputValue $outputs "external_region"
if ($primaryRegion -cne "ap-northeast-2" -or $externalRegion -cne "ap-northeast-1") {
    throw "Terraform outputs must identify primary_region ap-northeast-2 (Seoul) and external_region ap-northeast-1 (Tokyo)."
}
Assert-DeploymentTargets -ApiIds $apiIds -WorkerIds $workerIds -TargetGroupArn $apiTargetGroupArn

Write-Host "Terraform outputs (read-only):"
[pscustomobject]@{
    alb_url = $albUrl; api_target_group_arn = $apiTargetGroupArn
    primary_region = $primaryRegion; external_region = $externalRegion
    api_instance_ids = ($apiIds -join ","); worker_instance_ids = ($workerIds -join ",")
    mock_notify_instance_id = $mockNotifyId; monitoring_instance_id = $monitoringId
    rds_endpoint = $rdsEndpoint; redis_endpoint = $redisEndpoint; expires_at = $expiresAt
    artifact_contract = $artifactContract
    ttl_cleanup_limitations = $ttlLimitations
} | Format-List | Out-String | Write-Host

if (-not $Execute) {
    Write-Host "DRY RUN: no SSM command or S3 upload was sent. Pass -Execute -Acknowledge I_ACKNOWLEDGE_AWS_COST -ExpectedSha256 <64-hex> -ArtifactUri s3://private-bucket/optional-prefix/content-addressed-sha256.jar to deploy."
    exit 0
}
if ($Acknowledge -cne "I_ACKNOWLEDGE_AWS_COST") { throw "Execution requires -Acknowledge I_ACKNOWLEDGE_AWS_COST." }
Test-ArtifactUri -Uri $ArtifactUri -ArtifactContract $artifactContract -Sha256 $ExpectedSha256
Require-Command aws
function ConvertTo-RemoteBase64([string]$Value) {
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
}
function Get-DeploymentCommand([string]$Unit, [string]$HealthCommand) {
    $uri64 = ConvertTo-RemoteBase64 $ArtifactUri
    $hash64 = ConvertTo-RemoteBase64 $ExpectedSha256.ToLowerInvariant()
    $region64 = ConvertTo-RemoteBase64 $Region
    $unit64 = ConvertTo-RemoteBase64 $Unit
    $rollbackTrap = 'trap ''status=$?; echo "Activation failed; restoring $rollback"; if sudo test -f "$rollback" && sudo ln -sfn "$rollback" /opt/coupon/coupon.jar.rollback && sudo mv -Tf /opt/coupon/coupon.jar.rollback /opt/coupon/coupon.jar && sudo systemctl restart "$unit" && sudo systemctl is-active --quiet "$unit" && {0}; then echo "Rollback succeeded"; else echo "Rollback failed"; fi; exit "$status"'' ERR' -f $HealthCommand
    return @(
        'set -Eeuo pipefail',
        "artifact_uri=`$(printf '%s' '$uri64' | base64 --decode)",
        "expected_sha256=`$(printf '%s' '$hash64' | base64 --decode)",
        "region=`$(printf '%s' '$region64' | base64 --decode)",
        "unit=`$(printf '%s' '$unit64' | base64 --decode)",
        'tmp=$(mktemp)',
        'stage=""',
        'rollback=""',
        'trap ''rm -f "$tmp" "$stage"'' EXIT',
        'aws s3 cp "$artifact_uri" "$tmp" --region "$region" --only-show-errors',
        'printf "%s  %s\n" "$expected_sha256" "$tmp" | sha256sum --check --status',
        'sudo install -d -m 0755 /opt/coupon/releases',
        'test -f /opt/coupon/coupon.jar',
        'previous_sha=$(sha256sum /opt/coupon/coupon.jar | awk ''{print $1}'')',
        'rollback="/opt/coupon/releases/coupon-${previous_sha}.jar"',
        'if ! sudo test -f "$rollback"; then sudo install -m 0644 /opt/coupon/coupon.jar "$rollback"; fi',
        'stage="/opt/coupon/releases/coupon-${expected_sha256}.jar.stage.$$"',
        'sudo install -m 0644 "$tmp" "$stage"',
        'printf "%s  %s\n" "$expected_sha256" "$stage" | sudo sha256sum --check --status',
        'release="/opt/coupon/releases/coupon-${expected_sha256}.jar"',
        'sudo mv -f "$stage" "$release"',
        'stage=""',
        $rollbackTrap,
        'sudo ln -sfn "$release" /opt/coupon/coupon.jar.new',
        'sudo mv -Tf /opt/coupon/coupon.jar.new /opt/coupon/coupon.jar',
        'sudo systemctl enable "$unit"',
        'sudo systemctl restart "$unit"',
        'sudo systemctl is-active --quiet "$unit"',
        $HealthCommand,
        'printf "%s  %s\n" "$expected_sha256" /opt/coupon/coupon.jar | sha256sum --check --status'
    )
}

function Invoke-DeploymentCommand([string]$InstanceId, [string[]]$Command, [string]$Label) {
    $result = aws ssm send-command --region $Region --document-name AWS-RunShellScript --instance-ids $InstanceId --parameters ("commands=" + ($Command | ConvertTo-Json -Compress)) --comment "coupon $Label deployment" --no-cli-pager --output json
    if ($LASTEXITCODE -ne 0) { throw "SSM $Label deployment command was rejected for $InstanceId." }
    $commandId = ($result | ConvertFrom-Json).Command.CommandId
    if ([string]::IsNullOrWhiteSpace($commandId)) { throw "SSM $Label deployment response did not include a command ID for $InstanceId." }
    Wait-SsmCommand -CommandId $commandId -InstanceIds @($InstanceId) -Label "$Label on $InstanceId"
}

$apiHealthCommand = 'curl --fail --silent --show-error http://127.0.0.1:8080/actuator/health >/dev/null'
$workerHealthCommand = 'systemctl is-active --quiet coupon-worker-stream'
$apiCommand = Get-DeploymentCommand -Unit "coupon-api-reactive" -HealthCommand $apiHealthCommand
$workerCommand = Get-DeploymentCommand -Unit "coupon-worker-stream" -HealthCommand $workerHealthCommand
Write-Warning "MUTATING: rolling out one instance at a time to API profile 'reactive' and Redis Stream worker profile 'worker'."
foreach ($instanceId in $apiIds) { Invoke-DeploymentCommand -InstanceId $instanceId -Command $apiCommand -Label "API reactive" }
foreach ($instanceId in $workerIds) { Invoke-DeploymentCommand -InstanceId $instanceId -Command $workerCommand -Label "Redis Stream worker" }

Wait-ApiTargetHealth -TargetGroupArn $apiTargetGroupArn -ExpectedInstanceIds $apiIds
$healthResult = & aws ssm send-command --region $Region --document-name AWS-RunShellScript --instance-ids $apiIds --parameters ("commands=" + (@($apiHealthCommand) | ConvertTo-Json -Compress)) --comment "coupon API internal health verification" --no-cli-pager --output json
if ($LASTEXITCODE -ne 0) { throw "SSM internal API health command was rejected." }
$healthCommandId = ($healthResult | ConvertFrom-Json).Command.CommandId
if ([string]::IsNullOrWhiteSpace($healthCommandId)) { throw "SSM internal API health response did not include a command ID." }
Wait-SsmCommand -CommandId $healthCommandId -InstanceIds $apiIds -Label "internal API health"

$workerServiceResult = & aws ssm send-command --region $Region --document-name AWS-RunShellScript --instance-ids $workerIds --parameters ("commands=" + (@($workerHealthCommand) | ConvertTo-Json -Compress)) --comment "coupon worker service verification" --no-cli-pager --output json
if ($LASTEXITCODE -ne 0) { throw "SSM worker service verification command was rejected." }
$workerServiceCommandId = ($workerServiceResult | ConvertFrom-Json).Command.CommandId
if ([string]::IsNullOrWhiteSpace($workerServiceCommandId)) { throw "SSM worker service verification response did not include a command ID." }
Wait-SsmCommand -CommandId $workerServiceCommandId -InstanceIds $workerIds -Label "worker service health"
Write-Host "Deployment commands completed. Per-instance rollback-protected activation, ALB target health, SSM internal API health, and worker service verification succeeded; public /actuator/* is intentionally blocked."