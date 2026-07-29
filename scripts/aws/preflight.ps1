# Read-only AWS deployment gate. This script never creates, changes, or deletes resources.
[CmdletBinding()]
param(
    [string]$Region,
    [string]$TerraformDirectory = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "infra/aws"),
    [Parameter(Mandatory = $true)][string]$TerraformPlan,
    [decimal]$EstimatedHourlyUsd,
    [datetime]$ExpiresAt,
    [switch]$Execute,
    [string]$Acknowledge
)

$ErrorActionPreference = "Stop"
if ($Execute -and $Acknowledge -cne "I_ACKNOWLEDGE_AWS_COST") {
    throw "-Execute is an acknowledgement-only gate and requires -Acknowledge I_ACKNOWLEDGE_AWS_COST."
}
$requiredTerraformVariables = @(
    "artifact_bucket_arn", "artifact_key_prefix", "generator_evidence_key_prefix"
)
$calculatorTwelveHourLimit = [decimal]60
$maximumLifetime = [TimeSpan]::FromHours(12)
$now = [DateTime]::UtcNow

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' was not found. Install it before continuing."
    }
}
function Get-RequiredTerraformVariable([string]$Name) {
    return [Environment]::GetEnvironmentVariable("TF_VAR_$Name")
}
function Test-ChildPrefix([string]$ArtifactPrefix, [string]$EvidencePrefix) {
    $artifact = $ArtifactPrefix.Trim('/')
    $evidence = $EvidencePrefix.Trim('/')
    if ([string]::IsNullOrWhiteSpace($artifact) -or $artifact -notmatch '^[A-Za-z0-9._/-]+$') {
        throw "TF_VAR_artifact_key_prefix must be a non-empty safe S3 key prefix."
    }
    if ([string]::IsNullOrWhiteSpace($evidence) -or $evidence -notmatch '^[A-Za-z0-9._/-]+$') {
        throw "TF_VAR_generator_evidence_key_prefix must be a non-empty safe S3 key prefix."
    }
    if (-not $evidence.StartsWith("$artifact/", [System.StringComparison]::Ordinal)) {
        throw "TF_VAR_generator_evidence_key_prefix must be a child prefix of TF_VAR_artifact_key_prefix."
    }
}
function Get-PlannedResources($Module) {
    $resources = @($Module.resources)
    if ($null -ne $Module.child_modules) {
        foreach ($child in @($Module.child_modules)) { $resources += Get-PlannedResources $child }
    }
    return $resources
}
function Require-PlannedAddress([object[]]$Resources, [string]$Address) {
    $matches = @($Resources | Where-Object { $_.address -eq $Address -or ([string]$_.address).StartsWith("$Address[", [StringComparison]::Ordinal) })
    if ($matches.Count -eq 0) { throw "Reviewed Terraform plan is missing required resource '$Address'." }
    return $matches
}
function Get-PlanProperty($Object, [string]$Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}
function Get-RequiredStringArray($Object, [string]$Name, [string]$Context) {
    $value = Get-PlanProperty $Object $Name
    if ($null -eq $value) { throw "$Context is missing '$Name'." }
    $items = @($value)
    if ($items.Count -eq 0 -or @($items | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw "$Context has a malformed '$Name'."
    }
    return @($items | ForEach-Object { [string]$_ })
}
function Test-ExactStringSet([string[]]$Actual, [string[]]$Expected) {
    return $Actual.Count -eq $Expected.Count -and
        @($Actual | Select-Object -Unique).Count -eq $Actual.Count -and
        @($Actual | Where-Object { $_ -notin $Expected }).Count -eq 0
}
function Test-ExactPropertyNames($Object, [string[]]$Expected) {
    if ($null -eq $Object) { return $false }
    return Test-ExactStringSet -Actual @($Object.PSObject.Properties.Name) -Expected $Expected
}
function ConvertTo-UtcTimestamp($Value, [string]$Context) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "$Context is missing."
    }
    try {
        return [DateTimeOffset]::Parse(
            [string]$Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AllowWhiteSpaces
        ).ToUniversalTime()
    } catch {
        throw "$Context must be an unambiguous RFC3339 timestamp."
    }
}
function Assert-PlannedTtl([object[]]$Resources, [DateTimeOffset]$ExpectedExpiresAt) {
    foreach ($address in @("aws_lambda_function.ttl_cleanup", "aws_lambda_function.ttl_cleanup_tokyo")) {
        $functions = @(Require-PlannedAddress $Resources $address)
        if ($functions.Count -ne 1) { throw "Reviewed Terraform plan must contain exactly one '$address' resource." }
        $environment = Get-PlanProperty $functions[0].values "environment"
        $variables = if ($null -eq $environment) { $null } else { Get-PlanProperty $environment "variables" }
        $plannedExpiresAt = ConvertTo-UtcTimestamp (Get-PlanProperty $variables "EXPIRES_AT") "$address EXPIRES_AT"
        if ($plannedExpiresAt.UtcDateTime.Ticks -ne $ExpectedExpiresAt.UtcDateTime.Ticks) {
            throw "$address EXPIRES_AT must exactly match caller -ExpiresAt after UTC normalization."
        }
    }
    foreach ($address in @("aws_cloudwatch_event_rule.ttl_cleanup", "aws_cloudwatch_event_rule.ttl_cleanup_tokyo")) {
        $rules = @(Require-PlannedAddress $Resources $address)
        if ($rules.Count -ne 1 -or (Get-PlanProperty $rules[0].values "schedule_expression") -cne "rate(5 minutes)") {
            throw "Reviewed Terraform plan must schedule '$address' exactly every five minutes."
        }
    }
}
function Assert-PlannedBudgets([object[]]$Resources) {
    $budgets = @(Require-PlannedAddress $Resources "aws_budgets_budget.delayed_alert")
    $expectedLimits = @("100", "120", "200")
    if ($budgets.Count -ne $expectedLimits.Count) { throw "Reviewed Terraform plan must contain exactly three delayed budget resources." }
    $actualLimits = @()
    foreach ($budget in $budgets) {
        if ((Get-PlanProperty $budget.values "budget_type") -cne "COST" -or
            (Get-PlanProperty $budget.values "limit_unit") -cne "USD" -or
            (Get-PlanProperty $budget.values "time_unit") -cne "MONTHLY") {
            throw "Reviewed Terraform plan has an invalid delayed budget configuration in '$($budget.address)'."
        }
        $limit = Get-PlanProperty $budget.values "limit_amount"
        if ($null -eq $limit) { throw "Reviewed Terraform plan is missing a budget limit in '$($budget.address)'." }
        $actualLimits += [string]$limit
    }
    if (-not (Test-ExactStringSet -Actual $actualLimits -Expected $expectedLimits)) {
        throw "Reviewed Terraform plan must set the exact delayed budget limits of `$100, `$120, and `$200."
    }
}
function Get-NormalizedIngressRules([object[]]$Resources) {
    $groupById = @{}
    foreach ($group in @($Resources | Where-Object { $_.type -eq "aws_security_group" })) {
        $groupId = Get-PlanProperty $group.values "id"
        if (-not [string]::IsNullOrWhiteSpace([string]$groupId)) { $groupById[[string]$groupId] = $group.address }
    }

    $rules = @()
    foreach ($resource in $Resources) {
        if ($resource.type -eq "aws_vpc_security_group_ingress_rule") {
            throw "Reviewed Terraform plan uses unsupported aws_vpc_security_group_ingress_rule '$($resource.address)'; ingress normalization must be updated before this resource type is permitted."
        }
        if ($resource.type -eq "aws_security_group") {
            foreach ($ingress in @(Get-PlanProperty $resource.values "ingress")) {
                if ($null -ne $ingress) {
                    $rules += [pscustomobject]@{ Address = $resource.address; Values = $ingress; Source = $resource.address }
                }
            }
            continue
        }
        if ($resource.type -ne "aws_security_group_rule") { continue }
        if ($resource.type -eq "aws_security_group_rule" -and (Get-PlanProperty $resource.values "type") -ne "ingress") { continue }
        $groupId = Get-PlanProperty $resource.values "security_group_id"
        if ([string]::IsNullOrWhiteSpace([string]$groupId) -or -not $groupById.ContainsKey([string]$groupId)) {
            throw "Ingress rule '$($resource.address)' does not identify a planned security group."
        }
        $rules += [pscustomobject]@{ Address = $groupById[[string]$groupId]; Values = $resource.values; Source = $resource.address }
    }
    return $rules
}

function Assert-PlannedRegions([object]$Plan) {
    $expected = @{ primary_region = "ap-northeast-2"; external_region = "ap-northeast-1" }
    foreach ($name in $expected.Keys) {
        $change = $Plan.output_changes.PSObject.Properties[$name]
        if ($null -eq $change -or [string]$change.Value.after -cne $expected[$name]) {
            throw "Reviewed Terraform plan must set output '$name' exactly to '$($expected[$name])'."
        }
    }
}
function Test-ReviewedPlan([object]$Plan, [string]$BucketArn, [string]$ArtifactPrefix, [string]$EvidencePrefix, [DateTimeOffset]$ExpectedExpiresAt) {
    if ($null -eq $Plan.planned_values.root_module) { throw "Terraform plan JSON has no planned_values.root_module." }
    $resources = @(Get-PlannedResources $Plan.planned_values.root_module)
    $httpsListeners = @(Require-PlannedAddress $resources "aws_lb_listener.https")
    foreach ($listener in $httpsListeners) {
        if ($listener.values.protocol -ne "HTTPS" -or $listener.values.port -ne 443 -or [string]::IsNullOrWhiteSpace($listener.values.certificate_arn)) {
            throw "HTTPS listener must use port 443 with a certificate ARN."
        }
    }
    foreach ($address in @("aws_instance.control_load_generator", "aws_instance.external_load_generator", "aws_iam_role_policy.load_generator_artifact")) {
        [void](Require-PlannedAddress $resources $address)
    }
    Assert-PlannedTtl -Resources $resources -ExpectedExpiresAt $ExpectedExpiresAt
    Assert-PlannedRegions -Plan $Plan
    Assert-PlannedBudgets -Resources $resources
    $ingressRules = @(Get-NormalizedIngressRules $resources)
    foreach ($rule in $ingressRules) {
        $protocol = [string](Get-PlanProperty $rule.Values "protocol")
        $fromPort = Get-PlanProperty $rule.Values "from_port"
        $toPort = Get-PlanProperty $rule.Values "to_port"
        if ([string]::IsNullOrWhiteSpace($protocol) -or $protocol.ToLowerInvariant() -in @("-1", "all")) {
            throw "Reviewed Terraform plan contains all-protocol ingress in '$($rule.Source)'."
        }
        if ($null -eq $fromPort -or $null -eq $toPort) { throw "Ingress rule '$($rule.Source)' is missing ports." }
        if ([int]$fromPort -le 22 -and [int]$toPort -ge 22 -or [int]$fromPort -le 3000 -and [int]$toPort -ge 3000 -or [int]$fromPort -le 9090 -and [int]$toPort -ge 9090) {
            throw "Reviewed Terraform plan exposes prohibited ingress port(s) in '$($rule.Source)'."
        }
        $cidrs = @(Get-PlanProperty $rule.Values "cidr_blocks") + @(Get-PlanProperty $rule.Values "cidr_ipv4") + @(Get-PlanProperty $rule.Values "ipv6_cidr_blocks") + @(Get-PlanProperty $rule.Values "cidr_ipv6")
        if (@($cidrs | Where-Object { $_ -in @("0.0.0.0/0", "::/0") }).Count -gt 0 -and $rule.Address -ne "aws_security_group.alb") {
            throw "Only the ALB may have public ingress; found '$($rule.Source)'."
        }
    }

    foreach ($address in @("aws_security_group.monitoring", "aws_security_group.control_load_generator", "aws_security_group.external_load_generator")) {
        if (@($ingressRules | Where-Object { $_.Address -eq $address }).Count -ne 0) {
            throw "Security group '$address' must have no ingress."
        }
    }
    $albIngress = @($ingressRules | Where-Object { $_.Address -eq "aws_security_group.alb" })
    if ($albIngress.Count -ne 1) { throw "ALB security group must have exactly one ingress rule." }
    $albRule = $albIngress[0].Values
    $albCidrs = @((Get-PlanProperty $albRule "cidr_blocks") | Where-Object { $null -ne $_ }) + @((Get-PlanProperty $albRule "cidr_ipv4") | Where-Object { $null -ne $_ })
    if ([string](Get-PlanProperty $albRule "protocol") -cne "tcp" -or (Get-PlanProperty $albRule "from_port") -ne 443 -or (Get-PlanProperty $albRule "to_port") -ne 443 -or
        @($albCidrs | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -ne 0 -or $albCidrs.Count -eq 0 -or
        @((Get-PlanProperty $albRule "ipv6_cidr_blocks") | Where-Object { $null -ne $_ }).Count -ne 0 -or @((Get-PlanProperty $albRule "cidr_ipv6") | Where-Object { $null -ne $_ }).Count -ne 0 -or @((Get-PlanProperty $albRule "prefix_list_ids") | Where-Object { $null -ne $_ }).Count -ne 0 -or
        @((Get-PlanProperty $albRule "security_groups") | Where-Object { $null -ne $_ }).Count -ne 0 -or @((Get-PlanProperty $albRule "referenced_security_group_id") | Where-Object { $null -ne $_ }).Count -ne 0 -or @((Get-PlanProperty $albRule "self") | Where-Object { $null -ne $_ }).Count -ne 0) {
        throw "ALB security group must expose exactly the intended public TCP/443 CIDR ingress rule."
    }

    $policy = @(Require-PlannedAddress $resources "aws_iam_role_policy.load_generator_artifact")
    if ($policy.Count -ne 1 -or [string]::IsNullOrWhiteSpace($policy[0].values.policy)) { throw "Load-generator artifact IAM policy must be a single non-empty policy document." }
    try { $policyDocument = $policy[0].values.policy | ConvertFrom-Json } catch { throw "Load-generator artifact IAM policy is not valid JSON in the reviewed plan." }
    if ($policyDocument.Version -cne "2012-10-17") { throw "Load-generator artifact IAM policy must use IAM policy version 2012-10-17." }
    $statements = @($policyDocument.Statement)
    if ($statements.Count -ne 3) { throw "Load-generator artifact IAM policy must contain exactly three S3 Allow statements." }
    $artifactResource = "$BucketArn/$($ArtifactPrefix.Trim('/'))/*"
    $evidenceResource = "$BucketArn/$($EvidencePrefix.Trim('/'))/*"
    $seen = @{}
    foreach ($statement in $statements) {
        if ($null -ne (Get-PlanProperty $statement "NotAction") -or $null -ne (Get-PlanProperty $statement "NotResource")) {
            throw "Load-generator artifact IAM policy must not use NotAction or NotResource."
        }
        if ((Get-PlanProperty $statement "Effect") -cne "Allow") { throw "Load-generator artifact IAM policy statements must explicitly use Effect Allow." }
        $actions = Get-RequiredStringArray $statement "Action" "Load-generator artifact IAM policy statement"
        $statementResources = Get-RequiredStringArray $statement "Resource" "Load-generator artifact IAM policy statement"
        if (Test-ExactStringSet -Actual $actions -Expected @("s3:GetObject", "s3:GetObjectVersion")) {
            if (-not (Test-ExactStringSet -Actual $statementResources -Expected @($artifactResource)) -or $null -ne (Get-PlanProperty $statement "Condition")) { throw "Artifact read permissions must name only the exact artifact prefix resource without conditions." }
            $seen["artifact"] = $true
        } elseif (Test-ExactStringSet -Actual $actions -Expected @("s3:PutObject")) {
            if (-not (Test-ExactStringSet -Actual $statementResources -Expected @($evidenceResource)) -or $null -ne (Get-PlanProperty $statement "Condition")) { throw "Evidence write permissions must name only the exact evidence prefix resource without conditions." }
            $seen["evidence"] = $true
        } elseif (Test-ExactStringSet -Actual $actions -Expected @("s3:ListBucket")) {
            if (-not (Test-ExactStringSet -Actual $statementResources -Expected @($BucketArn))) { throw "ListBucket permissions must name only the exact artifact bucket." }
            $condition = Get-PlanProperty $statement "Condition"
            $stringLike = if ($null -eq $condition) { $null } else { Get-PlanProperty $condition "StringLike" }
            $prefixes = if ($null -eq $stringLike) { @() } else { Get-RequiredStringArray $stringLike "s3:prefix" "ListBucket condition" }
            if (-not (Test-ExactPropertyNames $condition @("StringLike")) -or -not (Test-ExactPropertyNames $stringLike @("s3:prefix")) -or -not (Test-ExactStringSet -Actual $prefixes -Expected @("$($ArtifactPrefix.Trim('/'))/*"))) { throw "ListBucket permissions must have the exact artifact prefix condition." }
            $seen["list"] = $true
        } else {
            throw "Load-generator artifact IAM policy contains unsupported S3 actions."
        }
    }
    if ($seen.Count -ne 3 -or -not $seen.ContainsKey("artifact") -or -not $seen.ContainsKey("evidence") -or -not $seen.ContainsKey("list")) {
        throw "Load-generator artifact IAM policy is missing a required exact S3 permission statement."
    }
}

Require-Command aws
Require-Command terraform
if ($Region -cne "ap-northeast-2") { throw "The approved target stack region is ap-northeast-2; pass -Region ap-northeast-2." }
if (-not (Test-Path $TerraformDirectory -PathType Container)) { throw "Terraform directory was not found: $TerraformDirectory" }
if (-not (Test-Path $TerraformPlan -PathType Leaf)) { throw "A caller-supplied saved Terraform plan file is required: -TerraformPlan <path>." }
if ($EstimatedHourlyUsd -le 0) { throw "A positive -EstimatedHourlyUsd from AWS Pricing Calculator is required." }
if ($ExpiresAt.Kind -eq [DateTimeKind]::Unspecified) { $ExpiresAt = [DateTime]::SpecifyKind($ExpiresAt, [DateTimeKind]::Utc) }
$expiresUtc = $ExpiresAt.ToUniversalTime()
if ($expiresUtc -le $now -or ($expiresUtc - $now) -gt $maximumLifetime) { throw "-ExpiresAt must be after now and no more than 12 hours from now (UTC)." }
$estimatedRunUsd = $EstimatedHourlyUsd * [decimal](($expiresUtc - $now).TotalHours)
$estimatedTwelveHourUsd = $EstimatedHourlyUsd * [decimal]12
if ($estimatedTwelveHourUsd -ge $calculatorTwelveHourLimit) { throw "Calculator 12-hour total must remain below `$$calculatorTwelveHourLimit." }

foreach ($name in $requiredTerraformVariables) {
    if ([string]::IsNullOrWhiteSpace((Get-RequiredTerraformVariable $name))) { throw "Required deployment variable TF_VAR_$name is not set." }
}
$artifactBucketArn = Get-RequiredTerraformVariable "artifact_bucket_arn"
if ($artifactBucketArn -notmatch '^arn:aws:s3:::(?<bucket>[a-z0-9][a-z0-9.-]{1,61}[a-z0-9])$') { throw "TF_VAR_artifact_bucket_arn must be a valid S3 bucket ARN." }
$artifactBucket = $Matches.bucket
$artifactPrefix = Get-RequiredTerraformVariable "artifact_key_prefix"
$evidencePrefix = Get-RequiredTerraformVariable "generator_evidence_key_prefix"
Test-ChildPrefix -ArtifactPrefix $artifactPrefix -EvidencePrefix $evidencePrefix
$planJson = & terraform -chdir=$TerraformDirectory show -json $TerraformPlan
if ($LASTEXITCODE -ne 0) { throw "terraform show -json failed for saved plan '$TerraformPlan'." }
Test-ReviewedPlan -Plan ($planJson | ConvertFrom-Json) -BucketArn $artifactBucketArn -ArtifactPrefix $artifactPrefix -EvidencePrefix $evidencePrefix -ExpectedExpiresAt ([DateTimeOffset]$expiresUtc)

Write-Host "Read-only tool, reviewed-plan, identity, quota, and artifact-bucket checks"
$identity = & aws sts get-caller-identity --no-cli-pager --output json
if ($LASTEXITCODE -ne 0) { throw "AWS caller identity check failed." }
$identity | Write-Host
& aws ec2 describe-availability-zones --region $Region --no-cli-pager --output json | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Availability-zone visibility check failed." }
& aws service-quotas list-service-quotas --service-code ec2 --region $Region --no-cli-pager --output json | Out-Null
if ($LASTEXITCODE -ne 0) { throw "EC2 quota visibility check failed." }
$publicAccess = & aws s3api get-public-access-block --bucket $artifactBucket --no-cli-pager --output json
if ($LASTEXITCODE -ne 0) { throw "Artifact bucket public-access-block check failed." }
$publicAccessConfig = ($publicAccess | ConvertFrom-Json).PublicAccessBlockConfiguration
if (-not ($publicAccessConfig.BlockPublicAcls -and $publicAccessConfig.IgnorePublicAcls -and $publicAccessConfig.BlockPublicPolicy -and $publicAccessConfig.RestrictPublicBuckets)) { throw "Artifact bucket must enable all four S3 public access block settings." }
$versioning = & aws s3api get-bucket-versioning --bucket $artifactBucket --no-cli-pager --output json
if ($LASTEXITCODE -ne 0 -or ($versioning | ConvertFrom-Json).Status -ne "Enabled") { throw "Artifact bucket versioning must be enabled." }
& aws s3api get-bucket-encryption --bucket $artifactBucket --no-cli-pager --output json | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Artifact bucket default encryption must be enabled." }
Write-Host "EC2 quota visibility and private artifact-bucket checks succeeded for region $Region."
Write-Host ("Calculator input accepted (USD): hourly={0:N2}; selected run={1:N2}h; selected estimate={2:N2}; 12-hour total={3:N2}" -f $EstimatedHourlyUsd, ($expiresUtc - $now).TotalHours, $estimatedRunUsd, $estimatedTwelveHourUsd)
Write-Host "Budget gates: Calculator 12-hour < `$$calculatorTwelveHourLimit; reviewed plan limits exactly `$100, `$120, and `$200."
Write-Host "ExpiresAt (UTC): $($expiresUtc.ToString('o'))"
if ($Execute) {
    Write-Warning "Acknowledgement accepted. Preflight remains read-only; Terraform apply must be invoked separately and explicitly."
} else {
    Write-Host "Read-only preflight complete. No AWS resources were created or changed."
}
