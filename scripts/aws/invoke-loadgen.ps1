# Opt-in remote k6 launcher. It never provisions or mutates infrastructure.
[CmdletBinding()]
param(
    [string]$TerraformDirectory = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'infra/aws'),
    [ValidateSet('control', 'external')][string]$Target = 'control',
    [ValidateSet('capacity', 'worker-recovery', 'generator-calibration')][string]$Experiment = 'capacity',
    [Parameter(Mandatory = $true)][string]$PlanManifestPath,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][long]$EventId,
    [Parameter(Mandatory = $true)][int]$Rate,
    [Parameter(Mandatory = $true)][string]$Duration,
    [Parameter(Mandatory = $true)][long]$Stock,
    [Parameter(Mandatory = $true)][ValidateSet('normal', 'sold-out', 'calibration')][string]$ResultPolicy,
    [int]$PreAllocatedVus = 100,
    [int]$MaxVus = 1000,
    [long]$UserOffset = 0,
    [switch]$ClaimMode,
    [switch]$Execute,
    [string]$Acknowledge
)
$ErrorActionPreference = 'Stop'
function Require-Command([string]$Name) { if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "Required tool '$Name' was not found." } }
function Seconds([string]$Value) { if ($Value -notmatch '^(?<amount>[1-9][0-9]*)(?<unit>ms|s|m|h)$') { throw 'Duration must be a positive integer followed by ms, s, m, or h.' }; $amount=[decimal]$Matches.amount; $n=switch($Matches.unit){'ms'{$amount/1000}'s'{$amount}'m'{$amount*60}'h'{$amount*3600}}; if($n -le 0 -or $n -gt 3600){throw 'Duration must be greater than zero and no more than 60 minutes.'}; return $n }
function Get-Outputs { if (-not (Test-Path $TerraformDirectory -PathType Container)) { throw "Terraform directory was not found: $TerraformDirectory" }; $raw=& terraform "-chdir=$TerraformDirectory" output -json; if($LASTEXITCODE -ne 0){throw 'terraform output failed.'}; return $raw|ConvertFrom-Json }
function Output($o,[string]$n) { $p=$o.PSObject.Properties[$n]; if($null -eq $p -or $null -eq $p.Value.value){throw "Required Terraform output '$n' is missing."}; return $p.Value.value }
function Encode([string]$v) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($v)) }
function Normalize-HttpsBaseUrl([string]$Value) {
    try { $uri = [Uri]$Value } catch { throw 'base_url must be an absolute HTTPS ALB URL.' }
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Port -ne 443 -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') { throw 'base_url must be an absolute HTTPS ALB URL without a port, path, query, fragment, or credentials.' }
    $normalizedHost = $uri.DnsSafeHost.ToLowerInvariant()
    if ($normalizedHost -notmatch '^[A-Za-z0-9.-]+$') { throw 'base_url must be an absolute HTTPS ALB URL.' }
    return "https://$normalizedHost"
}
function Cancel-Outstanding([array]$Commands,[DateTime]$Deadline) {
    $failures = @()
    foreach ($command in $Commands) {
        & aws ssm cancel-command --region $command.Region --command-id $command.Id --no-cli-pager | Out-Null
        if ($LASTEXITCODE -ne 0) { $failures += "Could not cancel SSM command $($command.Id) in $($command.Region)." }
        else { Write-Host "Requested cancellation of SSM command $($command.Id) in $($command.Region)." }
    }
    $terminal = @{}
    while ($terminal.Count -lt $Commands.Count -and [DateTime]::UtcNow -lt $Deadline) {
        foreach ($command in $Commands) {
            if ($terminal.ContainsKey($command.Id)) { continue }
            $raw = & aws ssm list-command-invocations --region $command.Region --command-id $command.Id --details --no-cli-pager --output json
            if ($LASTEXITCODE -ne 0) { $failures += "Could not poll cancelled SSM command $($command.Id)."; continue }
            try { $items = @(($raw | ConvertFrom-Json).CommandInvocations) } catch { $failures += "Could not parse cancelled SSM command $($command.Id) status."; continue }
            if ($items.Count -ne $command.Ids.Count) { continue }
            $statuses = @($items | ForEach-Object { [string]$_.Status })
            if (@($statuses | Where-Object { $_ -notin @('Success','Cancelled','TimedOut','Failed') }).Count -eq 0) {
                $terminal[$command.Id] = $true
            }
        }
        if ($terminal.Count -lt $Commands.Count -and [DateTime]::UtcNow -lt $Deadline) { Start-Sleep -Seconds 5 }
    }
    foreach ($command in $Commands) {
        if (-not $terminal.ContainsKey($command.Id)) { $failures += "SSM command $($command.Id) did not reach a terminal state before the cleanup deadline." }
    }
    return $failures
}
function Wait-All([array]$Commands,[DateTime]$Deadline) { while($true){$pending=$false; foreach($command in $Commands){$raw=& aws ssm list-command-invocations --region $command.Region --command-id $command.Id --details --no-cli-pager --output json;if($LASTEXITCODE -ne 0){throw "Could not poll SSM command $($command.Id)."};$items=@(($raw|ConvertFrom-Json).CommandInvocations);$bad=@($items|Where-Object {$_.Status -in @('Cancelled','TimedOut','Failed','Cancelling')});if($bad.Count){throw "SSM invocation failed for command $($command.Id): $($bad|Select-Object InstanceId,Status,StatusDetails|ConvertTo-Json -Compress)"};if($items.Count -ne $command.Ids.Count -or @($items|Where-Object Status -ne 'Success').Count){$pending=$true}};if(-not $pending){return};if([DateTime]::UtcNow -ge $Deadline){throw 'Remote load deadline elapsed.'};Start-Sleep -Seconds 5} }
function Show-PublicationReceipts([array]$Commands) {
    $seen = @{}
    foreach ($command in $Commands) {
        $raw = & aws ssm get-command-invocation --region $command.Region --command-id $command.Id --instance-id $command.Ids[0] --no-cli-pager --output json
        if ($LASTEXITCODE -ne 0) { throw "Could not retrieve publication receipt for SSM command $($command.Id)." }
        $output = [string](($raw | ConvertFrom-Json).StandardOutputContent)
        $receipt = @($output -split "`r?`n" | Where-Object { $_ -match '^EVIDENCE_PUBLICATION_URI=s3://[^ ]+ VERSION_ID=[^ ]+$' })
        if ($receipt.Count -ne 1) { throw "SSM command $($command.Id) did not emit one exact publication manifest receipt." }
        $expected = "EVIDENCE_PUBLICATION_URI=$($command.Prefix)evidence-publication-manifest.json "
        if (-not $receipt[0].StartsWith($expected, [StringComparison]::Ordinal)) { throw "SSM command $($command.Id) publication receipt does not bind the requested run, region, and instance." }
        if ($seen.ContainsKey($receipt[0])) { throw "SSM commands emitted a duplicate publication receipt: $($receipt[0])" }
        $seen[$receipt[0]] = $true
        Write-Host "SSM command $($command.Id): $($receipt[0])"
    }
}
function Get-PlanField([object]$Plan, [string]$Name) {
    $property = $Plan.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "Plan manifest is missing required field: $Name" }
    return $property.Value
}
function Assert-PlanString([object]$Value, [string]$Name) {
    if ($Value -isnot [string]) { throw "Plan manifest field '$Name' must be a JSON string." }
    return $Value
}
function Assert-PlanInteger([object]$Value, [string]$Name) {
    if ($Value -isnot [Int32] -and $Value -isnot [Int64]) { throw "Plan manifest field '$Name' must be a JSON integer." }
    return [Int64]$Value
}
function Assert-PlanDecimal([object]$Value, [string]$Name) {
    if (($Value -isnot [Int32] -and $Value -isnot [Int64] -and $Value -isnot [double] -and $Value -isnot [decimal]) -or [double]::IsNaN([double]$Value) -or [double]::IsInfinity([double]$Value)) { throw "Plan manifest field '$Name' must be a finite JSON number." }
    return [decimal]$Value
}
function Assert-PlanBoolean([object]$Value, [string]$Name) {
    if ($Value -isnot [bool]) { throw "Plan manifest field '$Name' must be a JSON boolean." }
    return $Value
}
Require-Command terraform
Require-Command python
$durationSeconds=Seconds $Duration
if($RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'){throw 'RunId must be 1-64 safe characters.'}
if($EventId -lt 1 -or $Rate -lt 1 -or $Rate -gt 10000 -or $Stock -lt 1 -or $PreAllocatedVus -lt 1 -or $PreAllocatedVus -gt 20000 -or $MaxVus -lt $PreAllocatedVus -or $MaxVus -gt 20000 -or $UserOffset -lt 0){throw 'Invalid bounded event, rate, stock, VU, or user offset value.'}
if (-not $ClaimMode) { throw 'ClaimMode is required for AWS evidence-producing scenarios.' }
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if(-not(Test-Path -LiteralPath $PlanManifestPath -PathType Leaf)){throw "PlanManifestPath does not exist: $PlanManifestPath"}
try{$plan=Get-Content -LiteralPath $PlanManifestPath -Raw|ConvertFrom-Json}catch{throw "PlanManifestPath must contain valid JSON: $($_.Exception.Message)"}
$scenario=switch($Experiment){'worker-recovery'{'aws-worker-recovery.js'}'generator-calibration'{'aws-generator-calibration.js'}default{'aws-capacity.js'}}
$runType=if($Experiment -eq 'capacity'){$Target}else{$Experiment}
$allowed=switch($Experiment){'generator-calibration'{@('calibration')}'worker-recovery'{@('normal')}default{@('normal','sold-out')}};if($ResultPolicy -notin $allowed){throw "ResultPolicy '$ResultPolicy' is incompatible with $Experiment."}
$required=@('run_id','run_type','record_mode','regions','event_id','users','stock','rate','duration','duration_seconds','base_url','user_offset','payload_descriptor','request_payload_bytes','claim_mode','result_policy','scenario','scenario_sha256','package_manifest_sha256','expected_attempts','dry_run','preallocated_vus','max_vus')
foreach($name in $required){[void](Get-PlanField $plan $name)}
$planRunId=Assert-PlanString (Get-PlanField $plan 'run_id') 'run_id';$planRunType=Assert-PlanString (Get-PlanField $plan 'run_type') 'run_type';$planRecordMode=Assert-PlanString (Get-PlanField $plan 'record_mode') 'record_mode';$planEventId=Assert-PlanInteger (Get-PlanField $plan 'event_id') 'event_id';$planUsers=Assert-PlanInteger (Get-PlanField $plan 'users') 'users';$planStock=Assert-PlanInteger (Get-PlanField $plan 'stock') 'stock';$planRate=Assert-PlanInteger (Get-PlanField $plan 'rate') 'rate';$planDuration=Assert-PlanString (Get-PlanField $plan 'duration') 'duration';$planDurationSeconds=Assert-PlanDecimal (Get-PlanField $plan 'duration_seconds') 'duration_seconds';$planBaseUrl=Assert-PlanString (Get-PlanField $plan 'base_url') 'base_url';$planUserOffset=Assert-PlanInteger (Get-PlanField $plan 'user_offset') 'user_offset';$planPayload=Assert-PlanString (Get-PlanField $plan 'payload_descriptor') 'payload_descriptor';$planPayloadBytes=Assert-PlanInteger (Get-PlanField $plan 'request_payload_bytes') 'request_payload_bytes';$planClaimMode=Assert-PlanBoolean (Get-PlanField $plan 'claim_mode') 'claim_mode';$planResultPolicy=Assert-PlanString (Get-PlanField $plan 'result_policy') 'result_policy';$planScenario=Assert-PlanString (Get-PlanField $plan 'scenario') 'scenario';$planScenarioSha=Assert-PlanString (Get-PlanField $plan 'scenario_sha256') 'scenario_sha256';$planPackageSha=Assert-PlanString (Get-PlanField $plan 'package_manifest_sha256') 'package_manifest_sha256';$planExpectedAttempts=Assert-PlanDecimal (Get-PlanField $plan 'expected_attempts') 'expected_attempts';$planDryRun=Assert-PlanBoolean (Get-PlanField $plan 'dry_run') 'dry_run';$planPreAllocatedVus=Assert-PlanInteger (Get-PlanField $plan 'preallocated_vus') 'preallocated_vus';$planMaxVus=Assert-PlanInteger (Get-PlanField $plan 'max_vus') 'max_vus'
$planRegions = @((Get-PlanField $plan 'regions')); if (-not $planRegions.Count -or @($planRegions | Where-Object { $_ -isnot [string] -or $_ -notmatch '^[a-z]{2}-[a-z]+-[1-9][0-9]*$' }).Count -or @($planRegions | Select-Object -Unique).Count -ne $planRegions.Count -or ((ConvertTo-Json -InputObject @($planRegions) -Compress) -cne (ConvertTo-Json -InputObject @($planRegions | Sort-Object) -Compress))) { throw 'Plan manifest regions must be a canonical JSON region list.' }
if($planRunId -cne $RunId -or $planRunType -cne $runType -or $planEventId -ne $EventId -or $planRate -ne $Rate -or $planDuration -cne $Duration -or $planDurationSeconds -ne $durationSeconds -or $planStock -ne $Stock -or $planPayload -cne 'null-body' -or $planPayloadBytes -ne 0 -or $planResultPolicy -cne $ResultPolicy -or $planUserOffset -ne $UserOffset -or $planClaimMode -ne $ClaimMode.IsPresent -or $planRecordMode -cne 'stream' -or -not $planDryRun -or $planScenario -cne $scenario -or $planPreAllocatedVus -ne $PreAllocatedVus -or $planMaxVus -ne $MaxVus){throw 'Invocation parameters must exactly match the reviewed dry-run plan.'}
$scenarioPath=Join-Path $root "k6/scenarios/$scenario";if(-not(Test-Path $scenarioPath)){throw "Scenario not found: $scenarioPath"};if($planScenarioSha -cne (Get-FileHash $scenarioPath -Algorithm SHA256).Hash.ToLowerInvariant()){throw 'Plan scenario SHA-256 does not match current source.'}
$manifestProbe=[IO.Path]::GetTempFileName()
try{
    & python (Join-Path $root 'scripts/aws/package_loadgen.py') --root $root --output $manifestProbe --manifest-only
    if($LASTEXITCODE -ne 0){throw 'Could not build the current package source manifest.'}
    if($planPackageSha -cne (Get-FileHash -LiteralPath $manifestProbe -Algorithm SHA256).Hash.ToLowerInvariant()){throw 'Plan package-manifest SHA-256 does not match the current source closure.'}
}finally{Remove-Item -LiteralPath $manifestProbe -Force -ErrorAction SilentlyContinue}
$expected=[decimal]::Ceiling([decimal]$Rate*$durationSeconds);if($planExpectedAttempts -ne [decimal]$Rate*$durationSeconds -or $expected -gt $planUsers){throw 'Plan expected iterations must match rate/duration and fit each generator user range.'}
$planJson=$plan|ConvertTo-Json -Depth 10 -Compress
$planHasher=[Security.Cryptography.SHA256]::Create()
try{$planSha=([BitConverter]::ToString($planHasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($planJson+"`n")))).Replace('-','').ToLowerInvariant()}finally{$planHasher.Dispose()}
if([Text.Encoding]::UTF8.GetByteCount($planJson)-gt 12000){throw 'Plan manifest exceeds bounded SSM payload size.'}
$outputs=Get-Outputs;$alb=Normalize-HttpsBaseUrl ([string](Output $outputs 'alb_url'));$normalizedPlanBaseUrl=Normalize-HttpsBaseUrl $planBaseUrl;if($normalizedPlanBaseUrl -cne $alb){throw 'Plan base_url must exactly match the normalized Terraform alb_url before dispatch.'};$evidence=[string](Output $outputs 'generator_evidence_s3_uri');if($evidence -notmatch '^s3://[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]/[A-Za-z0-9._/-]+/\*$'){throw 'generator_evidence_s3_uri must be a safe wildcard prefix.'}
$region=if($Target -eq 'control'){'ap-northeast-2'}else{'ap-northeast-1'};if($region -notin $planRegions){throw 'Plan manifest regions do not authorize the requested dispatch region.'};$ids=@([string[]](Output $outputs "${Target}_load_generator_instance_ids"));if(!$ids.Count -or @($ids|Where-Object{$_ -notmatch '^i-[a-f0-9]{8,17}$'}).Count){throw 'Terraform returned invalid load-generator instance IDs.'}
$offsets=@();for($i=0;$i -lt $ids.Count;$i++){if($UserOffset -gt [long]::MaxValue-([long]$i*[long]$planUsers)-([long]$planUsers-1)){throw 'User ranges overflow.'};$offsets+=($UserOffset+([long]$i*[long]$planUsers))};if(@($offsets|Select-Object -Unique).Count -ne $offsets.Count){throw 'Generator user ranges overlap.'}
$base=$evidence.Substring(0,$evidence.Length-1);$commandsSent=@();$deadline=[DateTime]::UtcNow.AddSeconds([double]$durationSeconds+900)
if(-not $Execute){Write-Host "DRY RUN: validated plan and concurrent launch set; no SSM command was sent.";exit 0};if($Acknowledge -cne 'I_ACKNOWLEDGE_AWS_COST'){throw 'Execution requires -Acknowledge I_ACKNOWLEDGE_AWS_COST.'};Require-Command aws
try {
    for ($i = 0; $i -lt $ids.Count; $i++) {
        $id = $ids[$i]
        $prefix = "$base$RunId/$region/$id/"
        $values = @{ ALB=$alb; RUN=$RunId; EVENT=$EventId; RATE=$Rate; DURATION=$Duration; PRE=$PreAllocatedVus; MAX=$MaxVus; OFFSET=$offsets[$i]; USERS=$planUsers; STOCK=$Stock; POLICY=$ResultPolicy; CLAIM=$ClaimMode.IsPresent.ToString().ToLowerInvariant(); PREFIX=$prefix; SCENARIO=$scenario; REGION=$region; INSTANCE=$id; PLAN=$planJson; PLAN_SHA=$planSha; SCENARIO_SHA=$planScenarioSha; PACKAGE_SHA=$planPackageSha }
        $lines = @('set -euo pipefail')
        foreach ($key in $values.Keys) { $lines += "$key=`$(printf %s '$((Encode ([string]$values[$key])))' | base64 --decode)" }
        $lines += @'
bucket_key=${PREFIX#s3://}; bucket=${bucket_key%%/*}; key_prefix=${bucket_key#*/}; work=$(mktemp -d); trap "rm -rf \"$work\"" EXIT
put(){ out=$(aws s3api put-object --bucket "$bucket" --key "$key_prefix$1" --body "$2" --if-none-match "*" --region "$REGION" --output json); version=$(printf "%s" "$out" | python3 -c "import json,sys; print(json.load(sys.stdin).get(\"VersionId\",\"\"))"); test -n "$version"; printf "%s" "$version"; }
printf "%s\n" "$PLAN" > "$work/plan-manifest.json"
imds_token=$(curl --fail --silent --show-error --connect-timeout 5 --max-time 10 -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.254/latest/api/token)
ami_id=$(curl --fail --silent --show-error --connect-timeout 5 --max-time 10 -H "X-aws-ec2-metadata-token: $imds_token" http://169.254.169.254/latest/meta-data/ami-id)
kernel=$(uname -r)
k6_version=$(/usr/local/bin/k6 version)
python_version=$(python3 --version 2>&1)
aws_version=$(aws --version 2>&1)
package_versions=$(rpm -q coreutils curl tar | paste -sd, -)
printf "%s\n" "$PLAN" > "$work/plan-manifest.json"
plan_manifest_sha=$(sha256sum "$work/plan-manifest.json" | cut -d " " -f1)
imds_token=$(curl --fail --silent --show-error --connect-timeout 5 --max-time 10 -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.254/latest/api/token)
ami_id=$(curl --fail --silent --show-error --connect-timeout 5 --max-time 10 -H "X-aws-ec2-metadata-token: $imds_token" http://169.254.169.254/latest/meta-data/ami-id)
kernel=$(uname -r)
k6_version=$(/usr/local/bin/k6 version)
python_version=$(python3 --version 2>&1)
aws_version=$(aws --version 2>&1)
package_versions=$(rpm -q coreutils curl tar | paste -sd, -)
python3 - "$work/runtime-manifest.json" "$RUN" "$plan_manifest_sha" "$PACKAGE_SHA" "$REGION" "$INSTANCE" "$OFFSET" "$USERS" "$(date -u +%FT%TZ)" "$ami_id" "$kernel" "$k6_version" "$python_version" "$aws_version" "$package_versions" <<'PY_RUNTIME'
import json,sys
out,run,plan_sha,package_sha,region,instance,offset,users,started,ami,kernel,k6_version,python_version,aws_version,packages=sys.argv[1:]
with open(out,"w",encoding="utf-8") as stream:
    json.dump({"schema_version":1,"run_id":run,"plan_sha256":plan_sha,"package_manifest_sha256":package_sha,"region":region,"instance_id":instance,"user_offset":int(offset),"users":int(users),"started_at_utc":started,"ami_id":ami,"kernel":kernel,"k6_version":k6_version,"python_version":python_version,"aws_cli_version":aws_version,"package_nevra":packages.split(",")},stream,sort_keys=True)
    stream.write("\n")
PY_RUNTIME
test -f "/opt/coupon-loadtest/scenarios/$SCENARIO"; test -f /opt/coupon-loadtest/package-manifest.json
test "$(sha256sum "/opt/coupon-loadtest/scenarios/$SCENARIO" | cut -d " " -f1)" = "$SCENARIO_SHA"; test "$(sha256sum /opt/coupon-loadtest/package-manifest.json | cut -d " " -f1)" = "$PACKAGE_SHA"
printf "%s\n" "{\"run_id\":\"$RUN\",\"instance_id\":\"$INSTANCE\"}" > "$work/reservation.json"; put reservation.json "$work/reservation.json" >/dev/null; v_plan=$(put plan-manifest.json "$work/plan-manifest.json")
summary="$work/k6-summary.json"; console="$work/k6-console.txt"; result="$work/execution-result.json"
set +e
BASE_URL="$ALB" EVENT_ID="$EVENT" RUN_ID="$RUN" RATE="$RATE" DURATION="$DURATION" PRE_ALLOCATED_VUS="$PRE" MAX_VUS="$MAX" USER_OFFSET="$OFFSET" STOCK="$STOCK" RESULT_POLICY="$POLICY" CLAIM_MODE="$CLAIM" SUMMARY_PATH="$summary" /usr/local/bin/k6 run "/opt/coupon-loadtest/scenarios/$SCENARIO" 2>&1 | tee "$console"; k6_status=${PIPESTATUS[0]}
set -e
summary_missing=0; final_status=$k6_status; execution_status=completed
if [ ! -f "$summary" ]; then summary_missing=1; final_status=1; execution_status=failed; printf "{\"run_id\":\"%s\",\"error\":\"k6 summary missing\",\"k6_exit_code\":%s}\n" "$RUN" "$k6_status" > "$work/k6-summary-missing.json"; fi
if [ "$summary_missing" -eq 1 ]; then put k6-summary-missing.json "$work/k6-summary-missing.json" >/dev/null || printf "%s\n" "Could not publish k6 summary diagnostic." >&2; fi
if [ "$k6_status" -ne 0 ]; then execution_status=failed; fi
printf "{\"run_id\":\"%s\",\"k6_exit_code\":%s,\"status\":\"%s\",\"summary_present\":%s}\n" "$RUN" "$k6_status" "$execution_status" "$([ "$summary_missing" -eq 0 ] && printf true || printf false)" > "$result"
publication_status=0
for item in plan-manifest.json runtime-manifest.json execution-result.json package-manifest.json k6-summary.json k6-console.txt; do case "$item" in package-manifest.json) cp /opt/coupon-loadtest/package-manifest.json "$work/$item";; esac; file="$work/$item"; test -f "$file" || publication_status=1; done
if [ "$publication_status" -eq 0 ]; then
  v_runtime=$(put runtime-manifest.json "$work/runtime-manifest.json") || publication_status=1
  v_result=$(put execution-result.json "$result") || publication_status=1
  v_package=$(put package-manifest.json "$work/package-manifest.json") || publication_status=1
  v_summary=$(put k6-summary.json "$summary") || publication_status=1
  v_console=$(put k6-console.txt "$console") || publication_status=1
fi
if [ "$publication_status" -eq 0 ] && [ -n "$v_plan" ] && [ -n "$v_runtime" ] && [ -n "$v_result" ] && [ -n "$v_package" ] && [ -n "$v_summary" ] && [ -n "$v_console" ]; then
  python3 - "$work/evidence-publication-manifest.json" "$bucket" "$key_prefix" "$v_plan" "$v_runtime" "$v_result" "$v_package" "$v_summary" "$v_console" "$work/plan-manifest.json" "$work/runtime-manifest.json" "$result" "$work/package-manifest.json" "$summary" "$console" <<"PY"
import hashlib,json,sys
out,bucket,key_prefix,*rest=sys.argv[1:]; versions=rest[:6]; files=rest[6:]; names=["plan-manifest.json","runtime-manifest.json","execution-result.json","package-manifest.json","k6-summary.json","k6-console.txt"]
json.dump({"schema_version":1,"objects":[{"name":n,"bucket":bucket,"key":key_prefix+n,"sha256":hashlib.sha256(open(f,"rb").read()).hexdigest(),"version_id":v} for n,v,f in zip(names,versions,files)]},open(out,"w"),sort_keys=True);open(out,"a").write("\n")
PY
  v_evidence=$(put evidence-publication-manifest.json "$work/evidence-publication-manifest.json") || publication_status=1
fi
if [ "$publication_status" -ne 0 ]; then printf "%s\n" "Required performance evidence publication is incomplete." >&2; exit 1; fi
printf "EVIDENCE_PUBLICATION_URI=s3://%s/%sevidence-publication-manifest.json VERSION_ID=%s\n" "$bucket" "$key_prefix" "$v_evidence"
exit "$final_status"
'@
        $response = & aws ssm send-command --region $region --document-name AWS-RunShellScript --instance-ids $id --timeout-seconds ([int][math]::Ceiling([double]$durationSeconds+900)) --parameters ("commands="+($lines | ConvertTo-Json -Compress)) --comment "coupon load test $RunId" --no-cli-pager --output json
        if ($LASTEXITCODE -ne 0) { throw "SSM invocation was rejected for $id." }
        $commandId = ($response | ConvertFrom-Json).Command.CommandId
        if ([string]::IsNullOrWhiteSpace($commandId)) { throw 'SSM response omitted command ID.' }
        $commandsSent += @{ Region=$region; Id=$commandId; Ids=@($id); Prefix=$prefix }
        Write-Host "Submitted SSM load command $commandId for $id in $region."
    }
    Wait-All $commandsSent $deadline
    Show-PublicationReceipts $commandsSent
} catch {
    $primaryFailure = $_
    $cleanupFailures = @()
    if ($commandsSent.Count) {
        try { Show-PublicationReceipts $commandsSent } catch { Write-Warning "Publication receipt retrieval failed: $($_.Exception.Message)" }
        $cleanupFailures = @(Cancel-Outstanding $commandsSent ([DateTime]::UtcNow.AddMinutes(2)))
    }
    if ($cleanupFailures.Count) { throw "$($primaryFailure.Exception.Message) Cleanup failures: $($cleanupFailures -join ' ')" }
    throw $primaryFailure
}
Write-Host "Concurrent SSM launch completed. Versioned evidence prefix: $base$RunId/"
