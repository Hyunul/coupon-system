# Offline contract checks; stdlib PowerShell only. Never calls real AWS, Terraform, k6, or Python.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$awsScripts = @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts/aws') -Filter '*.ps1' -File | Sort-Object Name)
if ($awsScripts.Count -eq 0) { throw 'No AWS PowerShell scripts found.' }
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Match([string]$Text, [string]$Pattern, [string]$Message) { Assert-True ($Text -match $Pattern) $Message }

# Every script must parse under Windows PowerShell 5.1 syntax before executable contract checks.
foreach ($script in $awsScripts) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "PowerShell parser rejected $($script.Name): $($errors | Out-String)"
}

# Every command boundary below is mocked; no test can invoke AWS, Terraform, k6, or Python.

# Hermetic reviewed-plan fixtures: malformed ingress and IAM policy must reject before
# any AWS command boundary. The Terraform function supplies only fixture JSON.
function New-PreflightFixture([datetime]$ExpiresAt) {
    $policy = [ordered]@{
        Version = '2012-10-17'
        Statement = @(
            [ordered]@{ Effect = 'Allow'; Action = @('s3:GetObject', 's3:GetObjectVersion'); Resource = @('arn:aws:s3:::artifact-bucket/releases/*') },
            [ordered]@{ Effect = 'Allow'; Action = @('s3:PutObject'); Resource = @('arn:aws:s3:::artifact-bucket/releases/evidence/*') },
            [ordered]@{ Effect = 'Allow'; Action = @('s3:ListBucket'); Resource = @('arn:aws:s3:::artifact-bucket'); Condition = [ordered]@{ StringLike = [ordered]@{ 's3:prefix' = @('releases/*') } } }
        )
    } | ConvertTo-Json -Depth 8 -Compress
    return @{
        planned_values = @{
            root_module = @{
                resources = @(
                    @{ address = 'aws_lb_listener.https'; type = 'aws_lb_listener'; values = @{ protocol = 'HTTPS'; port = 443; certificate_arn = 'arn:aws:acm:ap-northeast-2:123456789012:certificate/test' } },
                    @{ address = 'aws_instance.control_load_generator[0]'; type = 'aws_instance'; values = @{} },
                    @{ address = 'aws_instance.external_load_generator[0]'; type = 'aws_instance'; values = @{} },
                    @{ address = 'aws_iam_role_policy.load_generator_artifact'; type = 'aws_iam_role_policy'; values = @{ policy = $policy } },
                    @{ address = 'aws_lambda_function.ttl_cleanup'; type = 'aws_lambda_function'; values = @{ environment = @{ variables = @{ EXPIRES_AT = $ExpiresAt.ToUniversalTime().ToString('o') } } } },
                    @{ address = 'aws_lambda_function.ttl_cleanup_tokyo'; type = 'aws_lambda_function'; values = @{ environment = @{ variables = @{ EXPIRES_AT = $ExpiresAt.ToUniversalTime().ToString('o') } } } },
                    @{ address = 'aws_cloudwatch_event_rule.ttl_cleanup'; type = 'aws_cloudwatch_event_rule'; values = @{ schedule_expression = 'rate(5 minutes)' } },
                    @{ address = 'aws_cloudwatch_event_rule.ttl_cleanup_tokyo'; type = 'aws_cloudwatch_event_rule'; values = @{ schedule_expression = 'rate(5 minutes)' } },
                    @{ address = 'aws_budgets_budget.delayed_alert[0]'; type = 'aws_budgets_budget'; values = @{ budget_type = 'COST'; limit_unit = 'USD'; time_unit = 'MONTHLY'; limit_amount = '100' } },
                    @{ address = 'aws_budgets_budget.delayed_alert[1]'; type = 'aws_budgets_budget'; values = @{ budget_type = 'COST'; limit_unit = 'USD'; time_unit = 'MONTHLY'; limit_amount = '120' } },
                    @{ address = 'aws_budgets_budget.delayed_alert[2]'; type = 'aws_budgets_budget'; values = @{ budget_type = 'COST'; limit_unit = 'USD'; time_unit = 'MONTHLY'; limit_amount = '200' } },
                    @{ address = 'aws_security_group.alb'; type = 'aws_security_group'; values = @{ id = 'sg-alb'; ingress = @() } },
                    @{ address = 'aws_security_group_rule.alb_https'; type = 'aws_security_group_rule'; values = @{ type = 'ingress'; security_group_id = 'sg-alb'; protocol = 'tcp'; from_port = 443; to_port = 443; cidr_blocks = @('0.0.0.0/0') } },
                    @{ address = 'aws_security_group.monitoring'; type = 'aws_security_group'; values = @{ id = 'sg-monitoring'; ingress = @() } },
                    @{ address = 'aws_security_group.control_load_generator'; type = 'aws_security_group'; values = @{ id = 'sg-control'; ingress = @() } },
                    @{ address = 'aws_security_group.external_load_generator'; type = 'aws_security_group'; values = @{ id = 'sg-external'; ingress = @() } }
                )
            }
        }
        output_changes = @{
            primary_region = @{ after = 'ap-northeast-2' }
            external_region = @{ after = 'ap-northeast-1' }
        }
    }
}
function Get-PreflightResource($Fixture, [string]$Address) {
    return @($Fixture.planned_values.root_module.resources | Where-Object { $_.address -eq $Address })[0]
}
$preflightRoot = Join-Path ([IO.Path]::GetTempPath()) ('aws-preflight-contract-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $preflightRoot -ErrorAction Stop | Out-Null
$preflightPlan = Join-Path $preflightRoot 'reviewed.tfplan'
[IO.File]::WriteAllText($preflightPlan, '')
$preflightVariables = @{
    TF_VAR_owner = 'owner@example.test'; TF_VAR_owner_cidr = '203.0.113.0/24'
    TF_VAR_db_master_username = 'couponadmin'; TF_VAR_artifact_bucket_arn = 'arn:aws:s3:::artifact-bucket'
    TF_VAR_artifact_key_prefix = 'releases'; TF_VAR_generator_evidence_key_prefix = 'releases/evidence'
    TF_VAR_budget_notification_emails = 'owner@example.test'; TF_VAR_acm_certificate_arn = 'arn:aws:acm:ap-northeast-2:123456789012:certificate/test'
    TF_VAR_benchmark_hostname = 'benchmark.example.test'
}
$previousPreflightVariables = @{}
try {
    foreach ($name in $preflightVariables.Keys) {
        $previousPreflightVariables[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $preflightVariables[$name])
    }
    $preflightExpiresAt = [DateTime]::UtcNow.AddHours(1)
    foreach ($case in @(
        @{ Name = 'inline ingress'; Pattern = 'prohibited ingress|exactly the intended public TCP/443|exactly one ingress rule'; Mutate = { param($fixture) (Get-PreflightResource $fixture 'aws_security_group.alb').values.ingress = @(@{ protocol = 'tcp'; from_port = 22; to_port = 22; cidr_blocks = @('0.0.0.0/0') }) } },
        @{ Name = 'standalone ingress'; Pattern = 'prohibited ingress|exactly one ingress rule'; Mutate = { param($fixture) $fixture.planned_values.root_module.resources += @{ address = 'aws_security_group_rule.bad'; type = 'aws_security_group_rule'; values = @{ type = 'ingress'; security_group_id = 'sg-alb'; protocol = 'tcp'; from_port = 22; to_port = 22; cidr_blocks = @('0.0.0.0/0') } } } },
        @{ Name = 'all-protocol ingress'; Pattern = 'all-protocol ingress'; Mutate = { param($fixture) (Get-PreflightResource $fixture 'aws_security_group.alb').values.ingress = @(@{ protocol = '-1'; from_port = 0; to_port = 0; cidr_blocks = @('0.0.0.0/0') }) } },
        @{ Name = 'absent IAM policy'; Pattern = 'single non-empty policy'; Mutate = { param($fixture) (Get-PreflightResource $fixture 'aws_iam_role_policy.load_generator_artifact').values.policy = $null } },
        @{ Name = 'malformed IAM policy'; Pattern = 'not valid JSON'; Mutate = { param($fixture) (Get-PreflightResource $fixture 'aws_iam_role_policy.load_generator_artifact').values.policy = '{bad' } },
        @{ Name = 'wrong primary region output'; Pattern = 'primary_region.*ap-northeast-2'; Mutate = { param($fixture) $fixture.output_changes.primary_region.after = 'ap-northeast-1' } },
        @{ Name = 'wrong external region output'; Pattern = 'external_region.*ap-northeast-1'; Mutate = { param($fixture) $fixture.output_changes.external_region.after = 'ap-northeast-2' } }
    )) {
        $fixture = New-PreflightFixture $preflightExpiresAt
        & $case.Mutate $fixture
        $global:preflightPlanJson = $fixture | ConvertTo-Json -Depth 12 -Compress
        $global:preflightAwsCalls = 0
        $preflightChild = {
            param($Source, $Arguments)
            try { & $Source @Arguments; return $null } catch { return $_.Exception.Message }
        }
        function terraform { $global:LASTEXITCODE = 0; return $global:preflightPlanJson }
        function aws { $global:preflightAwsCalls++; throw 'Mocked AWS must not be reached by an invalid reviewed plan.' }
        $message = & $preflightChild (Join-Path $root 'scripts/aws/preflight.ps1') @{ Region = 'ap-northeast-2'; TerraformPlan = $preflightPlan; EstimatedHourlyUsd = 1; ExpiresAt = $preflightExpiresAt }
        Assert-Match $message $case.Pattern "Preflight accepted malformed $($case.Name) fixture. Observed: $message"
        Assert-True ($global:preflightAwsCalls -eq 0) "Preflight reached mocked AWS for malformed $($case.Name) fixture."
        Remove-Item function:terraform -ErrorAction SilentlyContinue
        Remove-Item function:aws -ErrorAction SilentlyContinue
    }
    $validPreflightFixture = New-PreflightFixture $preflightExpiresAt
    $global:preflightPlanJson = $validPreflightFixture | ConvertTo-Json -Depth 12 -Compress
    $global:preflightTerraformCalls = 0
    $global:preflightAwsCalls = 0
    function terraform { $global:preflightTerraformCalls++; return $global:preflightPlanJson }
    function aws { $global:preflightAwsCalls++; throw 'Mocked AWS must not be reached before the exact acknowledgement gate.' }
    $message = & $preflightChild (Join-Path $root 'scripts/aws/preflight.ps1') @{ Region = 'ap-northeast-2'; TerraformPlan = $preflightPlan; EstimatedHourlyUsd = 1; ExpiresAt = $preflightExpiresAt; Execute = $true; Acknowledge = 'wrong' }
    Assert-Match $message 'requires -Acknowledge I_ACKNOWLEDGE_AWS_COST' 'Preflight did not reject an incorrect exact acknowledgement.'
    Assert-True ($global:preflightTerraformCalls -eq 0 -and $global:preflightAwsCalls -eq 0) 'Preflight reached Terraform or AWS before rejecting an incorrect acknowledgement.'
} finally {
    foreach ($name in $previousPreflightVariables.Keys) { [Environment]::SetEnvironmentVariable($name, $previousPreflightVariables[$name]) }
    Remove-Item function:terraform -ErrorAction SilentlyContinue
    Remove-Item function:aws -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $preflightRoot -Recurse -Force -ErrorAction SilentlyContinue
}
# Remote-shell command content is exercised through captured SSM payloads below.
function New-ContractDirectory {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('aws-contract-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null
    return $path
}
function Invoke-Collector([hashtable]$Arguments) {
    try { & (Join-Path $root 'scripts/aws/collect-evidence.ps1') @Arguments; return $null } catch { return $_.Exception.Message }
}
$global:deployCommands = @()
$deployOutputs = '{"primary_region":{"value":"ap-northeast-2"},"external_region":{"value":"ap-northeast-1"},"alb_url":{"value":"https://alb.example"},"api_target_group_arn":{"value":"arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:targetgroup/api/0123456789abcdef0123456789abcdef"},"api_instance_ids":{"value":["i-012345678"]},"worker_instance_ids":{"value":["i-abcdef012"]},"mock_notify_instance_id":{"value":"i-notify"},"monitoring_instance_id":{"value":"i-monitor"},"rds_endpoint":{"value":"db.example"},"redis_endpoint":{"value":"redis.example"},"expires_at":{"value":"2026-08-01T12:00:00Z"},"ttl_cleanup_limitations":{"value":"best effort"},"artifact_contract":{"value":"s3://artifact-bucket/releases/*"}}'
$global:deploySendCount = 0
function terraform { $global:LASTEXITCODE = 0; return $deployOutputs }
function aws {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CommandArguments)
    if ($CommandArguments[1] -eq 'send-command') {
        $global:deployCommands += $CommandArguments[($CommandArguments.IndexOf('--parameters') + 1)]
        $global:deploySendCount++
        '{"Command":{"CommandId":"deploy-' + $global:deploySendCount + '"}}'
    } elseif ($CommandArguments[1] -eq 'list-command-invocations') {
        if ($CommandArguments[($CommandArguments.IndexOf('--command-id') + 1)] -match 'deploy-2|deploy-4') { '{"CommandInvocations":[{"InstanceId":"i-abcdef012","Status":"Success"}]}' } else { '{"CommandInvocations":[{"InstanceId":"i-012345678","Status":"Success"}]}' }
    } elseif ($CommandArguments[1] -eq 'describe-target-health') {
        '{"TargetHealthDescriptions":[{"Target":{"Id":"i-012345678"},"TargetHealth":{"State":"healthy"}}]}'
    } else { throw "Unexpected mocked AWS command: $($CommandArguments -join ' ')" }
    $global:LASTEXITCODE = 0
}
$validDeployOutputs = $deployOutputs
try {
    $hash = 'a' * 64
    & (Join-Path $root 'scripts/aws/deploy.ps1') -Region ap-northeast-2 -ArtifactUri ("s3://artifact-bucket/releases/coupon-$hash.jar") -ExpectedSha256 $hash -Execute -Acknowledge I_ACKNOWLEDGE_AWS_COST
    Assert-True ($global:deployCommands.Count -eq 4) 'Deployment did not submit one-at-a-time API, worker, and global health SSM commands.'
    $applicationPayload = $global:deployCommands[0]
    $expectedHashPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($hash))
    $hashBinding = $applicationPayload.IndexOf($expectedHashPayload)
    $hashVerification = $applicationPayload.IndexOf('sha256sum --check --status')
    $activation = $applicationPayload.IndexOf('systemctl restart')
    Assert-True ($hashBinding -ge 0) 'Deployment payload did not bind the expected artifact hash.'
    Assert-True ($hashVerification -ge 0 -and $activation -ge 0) 'Deployment payload omitted hash verification or activation/restart.'
    Assert-True ($hashVerification -lt $activation) 'Deployment payload activated the service before verifying its staged artifact hash.'
    Assert-True ($applicationPayload.IndexOf('coupon-${previous_sha}.jar') -ge 0 -and $applicationPayload.IndexOf('coupon-${previous_sha}.jar') -lt $activation) 'Deployment payload did not retain a versioned rollback JAR before activation.'
    Assert-True ($applicationPayload.IndexOf('coupon-${expected_sha256}.jar.stage.$$') -ge 0 -and $applicationPayload.IndexOf('coupon-${expected_sha256}.jar.stage.$$') -lt $activation) 'Deployment payload did not stage the release before atomic activation.'
    Assert-Match $applicationPayload 'Activation failed; restoring.*systemctl restart.*Rollback succeeded' 'Deployment payload has no rollback-and-restart failure trap.'

    $badTargets = $validDeployOutputs | ConvertFrom-Json
    $badTargets.api_instance_ids.value = @('not-an-ec2-id')
    $deployOutputs = $badTargets | ConvertTo-Json -Compress
    $global:deployCommands = @()
    $message = $null
    try { & (Join-Path $root 'scripts/aws/deploy.ps1') -Region ap-northeast-2 -ArtifactUri ("s3://artifact-bucket/releases/coupon-$hash.jar") -ExpectedSha256 $hash -Execute -Acknowledge I_ACKNOWLEDGE_AWS_COST } catch { $message = $_.Exception.Message }
    Assert-Match $message 'api_instance_ids.*EC2 instance IDs' 'Malformed deployment targets were not rejected.'
    Assert-True ($global:deployCommands.Count -eq 0) 'Malformed deployment targets dispatched an SSM command.'

    $wrongRegion = $validDeployOutputs | ConvertFrom-Json
    $wrongRegion.primary_region.value = 'ap-northeast-1'
    $deployOutputs = $wrongRegion | ConvertTo-Json -Compress
    $message = $null
    try { & (Join-Path $root 'scripts/aws/deploy.ps1') -Region ap-northeast-2 -ArtifactUri ("s3://artifact-bucket/releases/coupon-$hash.jar") -ExpectedSha256 $hash -Execute -Acknowledge I_ACKNOWLEDGE_AWS_COST } catch { $message = $_.Exception.Message }
    Assert-Match $message 'primary_region ap-northeast-2.*external_region ap-northeast-1' 'Deployment did not reject mismatched Terraform regions.'
} finally {
    Remove-Item function:terraform -ErrorAction SilentlyContinue
    Remove-Item function:aws -ErrorAction SilentlyContinue
}
function New-PublicationManifest([string[]]$Names, [scriptblock]$Mutate = $null) {
    $objects = @($Names | ForEach-Object {
        [ordered]@{ name = $_; bucket = 'evidence-bucket'; key = "runs/test/$_"; sha256 = ('a' * 64); version_id = 'version-1' }
    })
    if ($null -ne $Mutate) { & $Mutate $objects }
    return [ordered]@{
        schema_version = 1
        objects = $objects
    } | ConvertTo-Json -Depth 5
}

# These are executable hermetic collector contracts. Their terraform/aws functions are
# process-boundary mocks; invalid manifests must fail before any mocked S3 read.
$collectorRoot = New-ContractDirectory
$input = Join-Path $collectorRoot 'input.txt'
[IO.File]::WriteAllText($input, "2026-07-28T00:00:00Z Authorization: Bearer top-secret`n`"authorization`": `"another-secret`"`nX-Amz-Security-Token: session-secret`nclient_secret=client-secret-value`nrefresh-token: refresh-token-value`n`"private key`": `"private-key-value`"`naccess token = access-token-value`nclient_secretary=benign-client-field`naccess_token_count: 2`nAKIA1234567890ABCDEF`n123456789012`n192.0.2.1`n2026-07-28T00:00:01Z 2001:db8::1`n", [Text.Encoding]::UTF8)
try {
    $localEvidence = Join-Path $collectorRoot 'local-evidence'
    $global:localTerraformCalls = 0
    $global:localAwsCalls = 0
    $global:localPythonCalls = 0
    function terraform { $global:localTerraformCalls++; throw 'Local collector inputs must not invoke Terraform.' }
    function aws { $global:localAwsCalls++; throw 'Local collector inputs must not invoke AWS.' }
    function python { $global:localPythonCalls++; throw 'Local collector inputs must not invoke Python.' }
    $message = Invoke-Collector @{ CloudWatchExportPath = $input; EvidenceDirectory = $localEvidence; DryRun = $false }
    Assert-True ([string]::IsNullOrWhiteSpace($message)) "Local evidence collection unexpectedly failed: $message"
    $redacted = [IO.File]::ReadAllText((Join-Path $localEvidence 'redacted/cloudwatch-export.txt'))
    foreach ($secret in @('top-secret', 'another-secret', 'session-secret', 'client-secret-value', 'refresh-token-value', 'private-key-value', 'access-token-value', 'AKIA1234567890ABCDEF', '123456789012', '192.0.2.1', '2001:db8::1')) {
        Assert-True (-not $redacted.Contains($secret)) "Redacted evidence retained secret or identifier '$secret'."
    }
    Assert-Match $redacted '\[REDACTED\]' 'Authorization values were not completely redacted.'
    Assert-Match $redacted '2026-07-28T00:00:01Z \[REDACTED_IPV6\]' 'IPv6 redaction did not preserve its timestamp context.'
    Assert-True ($redacted.Contains('client_secretary=benign-client-field')) 'Redaction erased a benign compound-key prefix field.'
    Assert-True ($redacted.Contains('access_token_count: 2')) 'Redaction erased a benign compound-key suffix field.'
    Assert-True ($global:localTerraformCalls -eq 0 -and $global:localAwsCalls -eq 0 -and $global:localPythonCalls -eq 0) 'Local collector inputs crossed a mocked process boundary.'

    $oversized = Join-Path $collectorRoot 'oversized.txt'
    [IO.File]::WriteAllText($oversized, 'too large', [Text.Encoding]::UTF8)
    $partial = Join-Path $collectorRoot 'partial'
    $message = Invoke-Collector @{ CloudWatchExportPath = $oversized; EvidenceDirectory = $partial; MaximumInputBytes = 1; DryRun = $false }
    Assert-Match $message 'exceeds MaximumInputBytes' 'Oversized local input was accepted.'
    Assert-True (-not (Test-Path -LiteralPath $partial)) 'Collector left a partial evidence directory after rejecting oversized input.'
    Assert-True ($global:localTerraformCalls -eq 0 -and $global:localAwsCalls -eq 0 -and $global:localPythonCalls -eq 0) 'Oversized local collector input crossed a mocked process boundary.'

    foreach ($case in @(
        @{ Name = 'missing'; Names = @('plan-manifest.json', 'runtime-manifest.json', 'execution-result.json', 'package-manifest.json', 'k6-summary.json') },
        @{ Name = 'extra'; Names = @('plan-manifest.json', 'runtime-manifest.json', 'execution-result.json', 'package-manifest.json', 'k6-summary.json', 'k6-console.txt', 'other.json') },
        @{ Name = 'duplicate'; Names = @('plan-manifest.json', 'runtime-manifest.json', 'execution-result.json', 'package-manifest.json', 'k6-summary.json', 'k6-summary.json') },
        @{ Name = 'alias'; Names = @('plan_manifest.json', 'runtime-manifest.json', 'execution-result.json', 'package-manifest.json', 'k6-summary.json', 'k6-console.txt') },
        @{ Name = 'mixed-bucket'; Names = @('plan-manifest.json', 'runtime-manifest.json', 'execution-result.json', 'package-manifest.json', 'k6-summary.json', 'k6-console.txt'); Mutate = { param($objects) $objects[1].bucket = 'other-bucket' } },
        @{ Name = 'mixed-directory'; Names = @('plan-manifest.json', 'runtime-manifest.json', 'execution-result.json', 'package-manifest.json', 'k6-summary.json', 'k6-console.txt'); Mutate = { param($objects) $objects[2].key = 'runs/other/execution-result.json' } },
        @{ Name = 'basename-mismatch'; Names = @('plan-manifest.json', 'runtime-manifest.json', 'execution-result.json', 'package-manifest.json', 'k6-summary.json', 'k6-console.txt'); Mutate = { param($objects) $objects[0].key = 'runs/test/not-plan-manifest.json' } }
    )) {
        $manifest = Join-Path $collectorRoot ($case.Name + '.json')
        [IO.File]::WriteAllText($manifest, (New-PublicationManifest $case.Names $case.Mutate), [Text.Encoding]::UTF8)
        $partial = Join-Path $collectorRoot ($case.Name + '-partial')
        $global:mockAwsCalls = 0
        function terraform { '{"generator_evidence_s3_uri":{"value":"s3://evidence-bucket/runs/*"}}'; $global:LASTEXITCODE = 0 }
        function aws { $global:mockAwsCalls++; throw 'Mocked AWS must not be reached for an invalid manifest.' }
        $message = Invoke-Collector @{ LocalPublicationManifestPath = $manifest; EvidenceDirectory = $partial; DryRun = $false; Acknowledge = 'I_ACKNOWLEDGE_AWS_COST' }
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$message)) "Publication manifest $($case.Name) was accepted."
        Assert-True ($global:mockAwsCalls -eq 0) "Publication manifest $($case.Name) reached mocked AWS."
        Assert-True (-not (Test-Path -LiteralPath $partial)) "Collector left partial output for invalid $($case.Name) manifest."
        Remove-Item function:terraform -ErrorAction SilentlyContinue
        Remove-Item function:aws -ErrorAction SilentlyContinue
    }
    $remoteManifestJson = New-PublicationManifest @('plan-manifest.json', 'runtime-manifest.json', 'execution-result.json', 'package-manifest.json', 'k6-summary.json', 'k6-console.txt')
    $partial = Join-Path $collectorRoot 'remote-directory-partial'
    $global:mockAwsCalls = 0
    function terraform { '{"generator_evidence_s3_uri":{"value":"s3://evidence-bucket/runs/*"}}'; $global:LASTEXITCODE = 0 }
    function aws {
        param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CommandArguments)
        $global:mockAwsCalls++
        if ($CommandArguments[1] -eq 'head-object') { '{"ContentLength":' + [Text.Encoding]::UTF8.GetByteCount($remoteManifestJson) + '}' }
        elseif ($CommandArguments[1] -eq 'get-object') {
            [IO.File]::WriteAllText($CommandArguments[$CommandArguments.Length - 2], $remoteManifestJson, [Text.UTF8Encoding]::new($false))
            '{}'
        } else { throw "Unexpected mocked AWS command: $($CommandArguments -join ' ')" }
        $global:LASTEXITCODE = 0
    }
    $message = Invoke-Collector @{ S3PublicationManifestUri = 's3://evidence-bucket/runs/other/evidence-publication-manifest.json'; S3PublicationManifestVersionId = 'version-1'; EvidenceDirectory = $partial; DryRun = $false; Acknowledge = 'I_ACKNOWLEDGE_AWS_COST' }
    Assert-Match $message 'Remote publication manifest URI must be in the publication run directory' "Collector accepted a remote publication manifest outside its object run directory. Observed: $message"
    Assert-True ($global:mockAwsCalls -eq 2) 'Collector downloaded publication objects after rejecting a remote manifest directory mismatch.'
    Assert-True (-not (Test-Path -LiteralPath $partial)) 'Collector left partial output for a remote manifest directory mismatch.'
    Remove-Item function:terraform -ErrorAction SilentlyContinue
    Remove-Item function:aws -ErrorAction SilentlyContinue
} finally {
    Remove-Item function:python -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $collectorRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# Discrete offered starts must round the rate-duration product up, and the 99.9%
# floor must use that integer denominator rather than a fractional expectation.
function Get-DiscreteOfferedIterations([long]$Rate, [long]$DurationMilliseconds) {
    $numerator = $Rate * $DurationMilliseconds
    return [long]([Math]::Floor($numerator / 1000) + $(if (($numerator % 1000) -eq 0) { 0 } else { 1 }))
}
function Get-DiscreteMinimumIterations([long]$OfferedIterations) {
    return $OfferedIterations - [long][Math]::Floor($OfferedIterations / 1000)
}
$fractionalOfferedIterations = Get-DiscreteOfferedIterations 1001 1
Assert-True ($fractionalOfferedIterations -eq 2) 'RATE=1001 and DURATION=1ms must offer two discrete starts.'
Assert-True ((Get-DiscreteMinimumIterations $fractionalOfferedIterations) -eq 2) 'A 99.9% claim cannot certify fewer than two offered starts.'
$integralOfferedIterations = Get-DiscreteOfferedIterations 1000 1000
Assert-True ($integralOfferedIterations -eq 1000) 'An integral rate-duration product must preserve its offered-start count.'
Assert-True ((Get-DiscreteMinimumIterations $integralOfferedIterations) -eq 999) 'An integral 1,000-start offer must require 999 completed starts.'

$claimSource = [IO.File]::ReadAllText((Join-Path $root 'k6/lib/aws-claim.js'))
Assert-Match $claimSource 'Math\.floor\(expectedNumerator / 1000\) \+ \(expectedNumerator % 1000 === 0 \? 0 : 1\)' 'Claim configuration does not derive a discrete ceiling offered-start denominator.'
Assert-Match $claimSource 'minimumIterations = expectedIterations - Math\.floor\(expectedIterations / 1000\)' 'Claim configuration does not derive the exact discrete 99.9% minimum.'
Assert-Match $claimSource 'iterations: \[`count>=\$\{config\.minimumIterations\}`\]' 'Iteration threshold does not use the discrete 99.9% minimum.'
foreach ($scenarioPolicy in @(
    @{ Path = 'aws-capacity.js'; Invocation = 'readClaimConfig(true)' },
    @{ Path = 'aws-worker-recovery.js'; Invocation = 'readClaimConfig(false)' },
    @{ Path = 'aws-generator-calibration.js'; Invocation = 'readClaimConfig(false, true)' }
)) {
    $scenarioSource = [IO.File]::ReadAllText((Join-Path $root ('k6/scenarios/' + $scenarioPolicy.Path)))
    Assert-True ($scenarioSource.Contains($scenarioPolicy.Invocation)) "$($scenarioPolicy.Path) changed its claim-policy contract."
}
# Executable invocation guards: a reviewed base URL, null payload, and normalized
# duration must all reject before the mocked aws command boundary is reachable.
$global:packageManifestFixture = [Text.Encoding]::UTF8.GetBytes("package-manifest fixture`n")
function New-InvocationPlan([string]$BaseUrl, [string]$Payload, [decimal]$DurationSeconds) {
    $scenarioHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root 'k6/scenarios/aws-capacity.js')).Hash.ToLowerInvariant()
    $manifestHash = ([BitConverter]::ToString(([Security.Cryptography.SHA256]::Create().ComputeHash($global:packageManifestFixture))).Replace('-', '')).ToLowerInvariant()
    Assert-True ($scenarioHash -cne $manifestHash) 'Scenario and package-manifest fixtures must use distinct bytes and digests.'
    return [ordered]@{ run_id = 'contract-run'; run_type = 'control'; record_mode = 'stream'; regions = @('ap-northeast-2'); event_id = 1; users = 2; stock = 1; rate = 1; duration = '1s'; duration_seconds = $DurationSeconds; base_url = $BaseUrl; user_offset = 0; payload_descriptor = $Payload; request_payload_bytes = 0; claim_mode = $true; result_policy = 'normal'; scenario = 'aws-capacity.js'; scenario_sha256 = $scenarioHash; package_manifest_sha256 = $manifestHash; expected_attempts = 1; dry_run = $true; preallocated_vus = 100; max_vus = 1000 }
}
$invokeRoot = New-ContractDirectory
try {
    foreach ($invalid in @(
        @{ Name = 'base URL'; Plan = (New-InvocationPlan 'https://wrong.example' 'null-body' 1) },
        @{ Name = 'payload'; Plan = (New-InvocationPlan 'https://alb.example' 'json-body' 1) },
        @{ Name = 'duration'; Plan = (New-InvocationPlan 'https://alb.example' 'null-body' 2) }
    )) {
        $planPath = Join-Path $invokeRoot ($invalid.Name.Replace(' ', '-') + '.json')
        $invalid.Plan | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $planPath -Encoding UTF8
        $global:mockAwsCalls = 0
        function python { $output = $args[([array]::IndexOf($args, '--output') + 1)]; [IO.File]::WriteAllBytes($output, $global:packageManifestFixture); $global:LASTEXITCODE = 0 }
        function terraform { '{"alb_url":{"value":"https://alb.example"},"generator_evidence_s3_uri":{"value":"s3://evidence-bucket/runs/*"},"control_load_generator_instance_ids":{"value":["i-12345678"]}}'; $global:LASTEXITCODE = 0 }
        function aws { $global:mockAwsCalls++; throw 'Mocked AWS dispatch must not be reached by a reviewed-plan mismatch.' }
        $message = $null
        try { & (Join-Path $root 'scripts/aws/invoke-loadgen.ps1') -PlanManifestPath $planPath -RunId contract-run -EventId 1 -Rate 1 -Duration 1s -Stock 1 -ResultPolicy normal -ClaimMode } catch { $message = $_.Exception.Message }
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$message)) "Reviewed $($invalid.Name) mismatch was accepted."
        Assert-True ($global:mockAwsCalls -eq 0) "Reviewed $($invalid.Name) mismatch reached mocked AWS."
        Remove-Item function:python -ErrorAction SilentlyContinue
        Remove-Item function:terraform -ErrorAction SilentlyContinue
        Remove-Item function:aws -ErrorAction SilentlyContinue
    }
    $wrongRegionPlan = New-InvocationPlan 'https://alb.example' 'null-body' 1
    $wrongRegionPlan.regions = @('ap-northeast-1')
    $wrongRegionPath = Join-Path $invokeRoot 'wrong-region.json'
    $wrongRegionPlan | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $wrongRegionPath -Encoding UTF8
    $global:mockAwsCalls = 0
    function python { $output = $args[([array]::IndexOf($args, '--output') + 1)]; [IO.File]::WriteAllBytes($output, $global:packageManifestFixture); $global:LASTEXITCODE = 0 }
    function terraform { '{"alb_url":{"value":"https://alb.example"},"generator_evidence_s3_uri":{"value":"s3://evidence-bucket/runs/*"},"control_load_generator_instance_ids":{"value":["i-12345678"]}}'; $global:LASTEXITCODE = 0 }
    function aws { $global:mockAwsCalls++; throw 'Wrong-region plans must not dispatch.' }
    $message = $null
    try { & (Join-Path $root 'scripts/aws/invoke-loadgen.ps1') -PlanManifestPath $wrongRegionPath -RunId contract-run -EventId 1 -Rate 1 -Duration 1s -Stock 1 -ResultPolicy normal -ClaimMode -Execute -Acknowledge I_ACKNOWLEDGE_AWS_COST } catch { $message = $_.Exception.Message }
    Assert-Match $message 'regions do not authorize' "Invocation accepted a plan for the wrong dispatch region. Diagnostic: $message"
    Assert-True ($global:mockAwsCalls -eq 0) 'Wrong-region plan dispatched an AWS command.'
    Remove-Item function:python -ErrorAction SilentlyContinue
    Remove-Item function:terraform -ErrorAction SilentlyContinue
    Remove-Item function:aws -ErrorAction SilentlyContinue
} finally {
    Remove-Item -LiteralPath $invokeRoot -Recurse -Force -ErrorAction SilentlyContinue
}
$dispatchPlan = Join-Path ([IO.Path]::GetTempPath()) ('aws-dispatch-' + [Guid]::NewGuid().ToString('N') + '.json')
try {
    (New-InvocationPlan 'https://alb.example' 'null-body' 1) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $dispatchPlan -Encoding UTF8
    $global:sendInstances = @()
    $global:sendPayloads = @()
    $global:receiptWaitCalls = 0
    $global:receiptGetCalls = 0
    function python { $output = $args[([array]::IndexOf($args, '--output') + 1)]; [IO.File]::WriteAllBytes($output, $global:packageManifestFixture); $global:LASTEXITCODE = 0 }
    function terraform { '{"alb_url":{"value":"https://alb.example"},"generator_evidence_s3_uri":{"value":"s3://evidence-bucket/runs/*"},"control_load_generator_instance_ids":{"value":["i-12345678","i-87654321"]}}'; $global:LASTEXITCODE = 0 }
    function aws {
        param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CommandArguments)
        if ($CommandArguments[1] -eq 'send-command') {
            $instance = $CommandArguments[($CommandArguments.IndexOf('--instance-ids') + 1)]
            $global:sendInstances += $instance
            $global:sendPayloads += $CommandArguments[($CommandArguments.IndexOf('--parameters') + 1)]
            '{"Command":{"CommandId":"command-' + $instance + '"}}'
        } elseif ($CommandArguments[1] -eq 'list-command-invocations') {
            $global:receiptWaitCalls++
            '{"CommandInvocations":[{"Status":"Success"}]}'
        } elseif ($CommandArguments[1] -eq 'get-command-invocation') {
            $global:receiptGetCalls++
            $instance = $CommandArguments[($CommandArguments.IndexOf('--instance-id') + 1)]
            '{"StandardOutputContent":"EVIDENCE_PUBLICATION_URI=s3://evidence-bucket/runs/contract-run/ap-northeast-2/' + $instance + '/evidence-publication-manifest.json VERSION_ID=version-' + $instance + '"}'
        } else { throw "Unexpected mocked AWS command: $($CommandArguments -join ' ')" }
        $global:LASTEXITCODE = 0
    }
    & (Join-Path $root 'scripts/aws/invoke-loadgen.ps1') -PlanManifestPath $dispatchPlan -RunId contract-run -EventId 1 -Rate 1 -Duration 1s -Stock 1 -ResultPolicy normal -ClaimMode -Execute -Acknowledge I_ACKNOWLEDGE_AWS_COST
    Assert-True (($global:sendInstances -join ',') -ceq 'i-12345678,i-87654321') 'Concurrent dispatch did not submit generator IDs in Terraform order.'
    for ($i = 0; $i -lt $global:sendPayloads.Count; $i++) {
        $instanceBinding = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($global:sendInstances[$i]))
        Assert-Match $global:sendPayloads[$i] ("INSTANCE=.*" + [regex]::Escape($instanceBinding)) "Generator payload $i does not bind its dispatched instance identity."
        $offsetBinding = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(([long]$i * 2).ToString()))
        Assert-Match $global:sendPayloads[$i] ("OFFSET=.*" + [regex]::Escape($offsetBinding)) "Generator payload $i does not bind its disjoint effective user range."
    }
    $payload = $global:sendPayloads -join "`n"
    Assert-Match $payload 'for item in plan-manifest\.json runtime-manifest\.json execution-result\.json package-manifest\.json k6-summary\.json k6-console\.txt; do' 'Generated remote command does not publish the exact six-object schema.'
    Assert-Match $payload '--if-none-match \\"?\*\\"?' 'Generated remote command does not use immutable S3 publication writes.'
    Assert-Match $payload 'k6 summary missing' 'Generated remote command does not preserve the missing-summary publication contract.'
    Assert-True ($global:receiptWaitCalls -eq 2 -and $global:receiptGetCalls -eq 2) 'Successful dispatch did not wait for and retrieve exactly one receipt per generator.'
} finally {
    Remove-Item -LiteralPath $dispatchPlan -Force -ErrorAction SilentlyContinue
    Remove-Item function:python -ErrorAction SilentlyContinue
    Remove-Item function:terraform -ErrorAction SilentlyContinue
    Remove-Item function:aws -ErrorAction SilentlyContinue
}

# A failed cancellation must remain visible alongside the original dispatch failure.
$cancelPlan = Join-Path ([IO.Path]::GetTempPath()) ('aws-cancel-' + [Guid]::NewGuid().ToString('N') + '.json')
try {
    (New-InvocationPlan 'https://alb.example' 'null-body' 1) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cancelPlan -Encoding UTF8
    $global:sendCount = 0
    function python { $output = $args[([array]::IndexOf($args, '--output') + 1)]; [IO.File]::WriteAllBytes($output, $global:packageManifestFixture); $global:LASTEXITCODE = 0 }
    function terraform { '{"alb_url":{"value":"https://alb.example"},"generator_evidence_s3_uri":{"value":"s3://evidence-bucket/runs/*"},"control_load_generator_instance_ids":{"value":["i-12345678","i-87654321"]}}'; $global:LASTEXITCODE = 0 }
    function aws {
        param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CommandArguments)
        if ($CommandArguments[1] -eq 'send-command') {
            $global:sendCount++
            if ($global:sendCount -eq 1) { '{"Command":{"CommandId":"command-one"}}'; $global:LASTEXITCODE = 0 }
            else { $global:LASTEXITCODE = 1 }
        } elseif ($CommandArguments[1] -eq 'get-command-invocation') {
            $instance = $CommandArguments[($CommandArguments.IndexOf('--instance-id') + 1)]
            '{"StandardOutputContent":"EVIDENCE_PUBLICATION_URI=s3://evidence-bucket/runs/contract-run/ap-northeast-2/' + $instance + '/evidence-publication-manifest.json VERSION_ID=version-' + $instance + '"}'; $global:LASTEXITCODE = 0
        } elseif ($CommandArguments[1] -eq 'cancel-command') {
            $global:LASTEXITCODE = 1
        } elseif ($CommandArguments[1] -eq 'list-command-invocations') {
            '{"CommandInvocations":[{"Status":"Cancelled"}]}'; $global:LASTEXITCODE = 0
        } else { throw "Unexpected mocked AWS command: $($CommandArguments -join ' ')" }
    }
    $message = $null
    try { & (Join-Path $root 'scripts/aws/invoke-loadgen.ps1') -PlanManifestPath $cancelPlan -RunId contract-run -EventId 1 -Rate 1 -Duration 1s -Stock 1 -ResultPolicy normal -ClaimMode -Execute -Acknowledge I_ACKNOWLEDGE_AWS_COST } catch { $message = $_.Exception.Message }
    Assert-Match $message 'SSM invocation was rejected.*Could not cancel SSM command command-one' 'Failed SSM cancellation was not surfaced with the dispatch failure.'
} finally {
    Remove-Item -LiteralPath $cancelPlan -Force -ErrorAction SilentlyContinue
    Remove-Item function:python -ErrorAction SilentlyContinue
    Remove-Item function:terraform -ErrorAction SilentlyContinue
    Remove-Item function:aws -ErrorAction SilentlyContinue
}

Write-Host "AWS offline PowerShell contract checks passed for $($awsScripts.Count) scripts."
