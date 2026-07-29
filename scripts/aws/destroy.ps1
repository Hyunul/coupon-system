# Opt-in teardown. Dry run is the default and all AWS reads are non-mutating.
[CmdletBinding()]
param(
    [string]$Region = "ap-northeast-2",
    [string]$TerraformDirectory = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "infra/aws"),
    [string]$ExperimentTagValue,
    [switch]$Execute,
    [string]$Confirm
)

$ErrorActionPreference = "Stop"
function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "Required tool '$Name' was not found." }
}
function Get-TerraformOutputs {
    $raw = & terraform -chdir=$TerraformDirectory output -json
    if ($LASTEXITCODE -ne 0) { throw "terraform output failed; inspect the Terraform state manually." }
    return ($raw | ConvertFrom-Json)
}
function Get-OutputValue($Outputs, [string]$Name) {
    $property = $Outputs.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value.value) { return "<missing>" }
    return $property.Value.value
}
function Get-TaggedResiduals([string]$CheckRegion, [string]$VerifiedProject) {
    $raw = & aws resourcegroupstaggingapi get-resources --region $CheckRegion --tag-filters "Key=Project,Values=$VerifiedProject" --no-cli-pager --output json
    if ($LASTEXITCODE -ne 0) { throw "Tagged-resource residual check failed in $CheckRegion." }
    return @((($raw | ConvertFrom-Json).ResourceTagMappingList))
}
function Get-TerraformStateAddresses {
    $raw = & terraform -chdir=$TerraformDirectory show -json
    if ($LASTEXITCODE -ne 0) { throw "terraform show -json failed during residual verification." }
    $state = $raw | ConvertFrom-Json
    function Get-StateModuleAddresses($Module) {
        $addresses = @($Module.resources | ForEach-Object { $_.address })
        foreach ($child in @($Module.child_modules)) { $addresses += Get-StateModuleAddresses $child }
        return $addresses
    }
    if ($null -eq $state.values.root_module) { return @() }
    return @(Get-StateModuleAddresses $state.values.root_module)
}
function Assert-NoResiduals([string]$VerifiedProject) {
    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    $lastState = @()
    $lastTagged = @()
    do {
        $lastState = @(Get-TerraformStateAddresses)
        $lastTagged = @()
        foreach ($checkRegion in @("ap-northeast-2", "ap-northeast-1")) {
            $lastTagged += @(Get-TaggedResiduals $checkRegion $VerifiedProject | ForEach-Object { [pscustomobject]@{ Region = $checkRegion; Arn = $_.ResourceARN } })
        }
        if ($lastState.Count -eq 0 -and $lastTagged.Count -eq 0) {
            Write-Host "Terraform JSON state and Seoul/Tokyo tagged-resource residual checks are clear."
            Write-Warning "Service-specific and manual billing checks remain required for untaggable resources."
            return
        }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Seconds 10
    } while ($true)
    throw "Residual resources remain after bounded consistency retries. Terraform JSON state: $($lastState -join ', '); tagged resources: $(($lastTagged | ConvertTo-Json -Compress)). Service-specific/manual billing checks remain required for untaggable resources."
}

Require-Command terraform
if ($Region -cne "ap-northeast-2") { throw "The primary teardown region is ap-northeast-2." }
if (-not (Test-Path $TerraformDirectory -PathType Container)) { throw "Terraform directory was not found: $TerraformDirectory" }

$outputs = Get-TerraformOutputs
Write-Host "Chargeable resources to be destroyed (read-only Terraform state inventory):"
& terraform -chdir=$TerraformDirectory state list
if ($LASTEXITCODE -ne 0) { throw "terraform state list failed." }
Write-Host "Output inventory:"
[pscustomobject]@{
    alb_url = Get-OutputValue $outputs "alb_url"
    control_load_generator_instance_ids = ((@(Get-OutputValue $outputs "control_load_generator_instance_ids")) -join ",")
    external_load_generator_instance_ids = ((@(Get-OutputValue $outputs "external_load_generator_instance_ids")) -join ",")
    generator_evidence_s3_uri = Get-OutputValue $outputs "generator_evidence_s3_uri"
    api_instance_ids = ((@(Get-OutputValue $outputs "api_instance_ids")) -join ",")
    worker_instance_ids = ((@(Get-OutputValue $outputs "worker_instance_ids")) -join ",")
    mock_notify_instance_id = Get-OutputValue $outputs "mock_notify_instance_id"
    monitoring_instance_id = Get-OutputValue $outputs "monitoring_instance_id"
    rds_endpoint = Get-OutputValue $outputs "rds_endpoint"
    redis_endpoint = Get-OutputValue $outputs "redis_endpoint"
    expires_at = Get-OutputValue $outputs "expires_at"
    project = Get-OutputValue $outputs "project"
    ttl_cleanup_limitations = Get-OutputValue $outputs "ttl_cleanup_limitations"
} | Format-List | Out-String | Write-Host
Write-Warning "TTL only stops EC2/RDS. ALB, ElastiCache, EBS, and CloudWatch Logs can continue charging until full terraform destroy completes."

if (-not $Execute) {
    Write-Host "DRY RUN: terraform destroy was not invoked. To destroy, pass -Execute -ExperimentTagValue <exact Project tag value> -Confirm DESTROY_AWS_EXPERIMENT."
    exit 0
}
if ([string]::IsNullOrWhiteSpace($ExperimentTagValue)) { throw "Execution requires -ExperimentTagValue for Seoul/Tokyo residual verification." }
if ($ExperimentTagValue -notmatch '^[a-z][a-z0-9-]{1,26}[a-z0-9]$') { throw "Residual verification requires the exact Project key and an AWS-safe project tag value." }
$verifiedProject = Get-OutputValue $outputs "project"
if ($verifiedProject -eq "<missing>" -or $verifiedProject -isnot [string] -or [string]::IsNullOrWhiteSpace($verifiedProject)) {
    throw "Terraform state identity is unavailable: required project output is missing."
}
if ($verifiedProject -cne $ExperimentTagValue) {
    throw "Execution requires -ExperimentTagValue to exactly match Terraform output project."
}
if ($Confirm -cne "DESTROY_AWS_EXPERIMENT") { throw "Destruction requires the exact typed confirmation: -Confirm DESTROY_AWS_EXPERIMENT" }
Require-Command aws
Write-Warning "MUTATING: terraform destroy will delete every resource in $TerraformDirectory."
& terraform -chdir=$TerraformDirectory destroy -auto-approve
if ($LASTEXITCODE -ne 0) { throw "terraform destroy failed; do not assume charges have stopped. Investigate state and cloud resources." }
Assert-NoResiduals -VerifiedProject $verifiedProject
