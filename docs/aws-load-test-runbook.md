# AWS 부하 테스트 실행 런북

> 이 문서는 **실행 절차**일 뿐 AWS 배포, 상태, 부하 결과, 비용이 이미 검증되었음을 뜻하지 않는다. `MUTATING / COST-INCURRING` 또는 장애 주입 단계는 사용자만 유효한 자격 증명과 명시적 확인으로 실행한다. 서울 대상 리전은 `ap-northeast-2`, 외부 발생기는 도쿄 `ap-northeast-1`이다.

## 계약, 토폴로지, 출력

공개 ALB는 HTTPS/443만 제공한다. 입력 `acm_certificate_arn`과 `benchmark_hostname`은 필수이며, Terraform은 DNS 영역을 바꾸지 않는다. 적용 후 사용자가 `benchmark_hostname`을 출력 `alb_dns_name`에 매핑하고 ACM 인증서가 그 이름에 유효함을 확인한 뒤에만 smoke 또는 부하를 보낸다. `alb_url`은 `https://<benchmark_hostname>`이므로 ALB DNS 이름으로 우회하지 않는다.

공개 `/actuator` 및 `/actuator/*`는 403이어야 한다. 대상 그룹의 내부 health check와 SSM 내부 점검을 사용한다. `/loadgen-calibration`의 정상 응답은 204이다. 모니터링 인스턴스에는 ingress가 없으며 Grafana/Prometheus 접근은 출력 `monitoring_ssm_port_forwarding`의 SSM 포트 포워딩 명령만 사용한다.

저장할 필수 Terraform 출력은 다음과 같다.

- `alb_url`, `alb_dns_name`, `dns_mapping_required`, `api_target_group_arn`
- `api_instance_ids`, `worker_instance_ids`, `mock_notify_instance_id`, `mock_notify_private_url`, `monitoring_instance_id`, `monitoring_ssm_port_forwarding`
- `rds_endpoint`, `redis_endpoint`, `rds_master_user_secret_arn`
- `artifact_contract`, `generator_evidence_s3_uri`
- `control_load_generator_instance_ids`, `control_load_generator_public_ips`, `external_load_generator_instance_ids`, `external_load_generator_public_ips`
- `resolved_ami_ids`, `rds_engine_version_actual`, `k6_pin`, `monitoring_image_digests`
- `expires_at`, `ttl_cleanup_limitations`

인스턴스 ID, EIP, 대상 그룹, AMI/런타임 pin은 콘솔 추측이 아니라 이 출력에서 취한다. `monitoring_ssm_port_forwarding`의 Grafana와 Prometheus SSM 명령도 그대로 evidence에 저장한다. artifact bucket은 버전 관리·기본 암호화·모든 public-access block이 활성화된 사설 bucket이어야 하며, `generator_evidence_key_prefix`는 비어 있지 않은 `artifact_key_prefix`의 하위 prefix여야 한다.

## 비용 및 배포 게이트

Calculator에서 ALB/LCU, EC2/EBS, RDS/백업, ElastiCache, S3, SSM, 전송, CloudWatch를 산정한다. Calculator 12시간 총액은 **$60 미만**이어야 하며 estimate와 만료 시각을 기록한다. 실제/예상 지출이 **$100**이면 새 부하를 중단하고, **$120**이면 teardown을 시작하며, **$200 초과는 절대 승인하지 않는다**. Budget은 지연 알림일 뿐 강제 차단 장치가 아니다. 5분 TTL은 일부 중지 backstop일 뿐이며 destroy와 잔존/청구 확인을 대체하지 않는다.

1. 필요한 `TF_VAR_*`를 설정한다: `owner`, `owner_cidr`, `db_master_username`, `artifact_bucket_arn`, `artifact_key_prefix`, `generator_evidence_key_prefix`, `budget_notification_emails`, `acm_certificate_arn`, `benchmark_hostname`, `expires_at` (UTC ISO-8601, 현재부터 최대 12시간). 예외 CIDR만 별도 검토 후 `additional_load_generator_cidrs`로 설정한다. `db_master_password`나 DB/Redis 자격 증명을 shell history, tfvars, k6 환경, SSM 파라미터에 넣지 않는다.

2. Terraform 디렉터리에서 초기화와 정적 검증을 수행하고, 검토용 저장 plan을 만든다. 이 단계의 AWS 조회는 읽기 전용이다.

   ```powershell
   terraform -chdir=infra/aws init
   terraform -chdir=infra/aws validate
   $reviewedPlan = Join-Path $PWD "reviewed-aws-loadtest.tfplan"
   terraform -chdir=infra/aws plan -out=$reviewedPlan
   ```

3. 새 Calculator estimate와 UTC 만료 시각(현재부터 최대 12시간)을 정한 뒤, **그 정확한 저장 plan**으로 preflight를 실행한다.

   ```powershell
   .\scripts\aws\preflight.ps1 `
     -TerraformPlan $reviewedPlan `
     -Region ap-northeast-2 `
     -EstimatedHourlyUsd <calculator-hourly-usd> `
     -ExpiresAt <UTC-ISO-8601>
   ```

   preflight는 plan의 HTTPS listener, monitoring ingress 부재, 필수 입력, artifact 권한/보호, caller identity, quota, 리전, Calculator/expiry를 읽기 전용으로 검증한다. `-Execute -Acknowledge I_ACKNOWLEDGE_AWS_COST`는 acknowledgement만 기록하며 여전히 읽기 전용이다.

4. plan과 preflight 결과, Calculator 링크/입력/유효시각을 검토한다. **MUTATING / COST-INCURRING — 사용자 전용:** 승인한 바로 그 plan만 명시적으로 적용한다.

   ```powershell
   terraform -chdir=infra/aws apply $reviewedPlan
   ```

   `deploy.ps1`은 Terraform apply를 하지 않는다. 적용 후 `terraform -chdir=infra/aws output -json`을 evidence에 저장하고 `dns_mapping_required`를 이행한다.

5. 서비스는 content-addressed JAR 배포 전 시작하지 않는다. 승인된 사설 release 경로로 JAR을 업로드하고 SHA-256을 계산한다. `deploy.ps1 -Package`는 명시적으로 요청한 local `bootJar`일 뿐 업로드/배포가 아니다. 먼저 출력만 읽는 dry run을 수행하고, 실제 배포에는 URI와 동일 JAR의 digest를 모두 제공한다.

   ```powershell
   .\scripts\aws\deploy.ps1 -Region ap-northeast-2

   # MUTATING / COST-INCURRING — 사용자 전용
   .\scripts\aws\deploy.ps1 -Region ap-northeast-2 `
     -ArtifactUri s3://<private-bucket>/<artifact-prefix>/<sha256>.jar `
     -ExpectedSha256 <64-hex-sha256> `
     -Execute -Acknowledge I_ACKNOWLEDGE_AWS_COST
   ```

   URI는 `artifact_contract` 내부의 hash-named JAR이어야 한다. script는 digest를 검증한 뒤 API와 worker를 SSM으로 배포하고 target health 및 내부 health를 확인한다. public actuator 경로는 health check가 아니다.

## 계획 생성과 발생기 패키지

`run-experiment.ps1`에는 `RecordMode` 매개변수가 없다. 항상 stream 기록 계약을 manifest에 기록한다. 매 실행마다 새 evidence 디렉터리, plan manifest, package-manifest hash가 생성되며 기본값은 **LOCAL-ONLY dry run**이다. `BaseUrl`은 반드시 HTTPS benchmark hostname이고 `Users`, `Stock`, `ResultPolicy`, `Payload`는 필수다. `Payload`는 정확히 `null-body`여야 하며 duration은 양의 `ms|s|m|h`, 최대 60분이다. 검토된 dry-run manifest는 정규화된 `base_url`, `payload_descriptor=null-body`, `request_payload_bytes=0`, `duration`과 `duration_seconds`를 묶고, 원격 invocation은 이 값과 호출 인자가 정확히 같지 않으면 SSM dispatch 전에 거부한다.

다음은 모두 **로컬 dry run** 예시이며 AWS 부하를 보내지 않는다. 각 예시는 새 `RunId`, 이벤트, 사용자 범위와 실제 측정 pin을 사용한다.

```powershell
# 정상 capacity 계획
.\scripts\aws\run-experiment.ps1 `
  -RunType control -RunId <run-id> -BaseUrl https://<benchmark-hostname> -EventId <id> `
  -UserOffset 0 -Rate 5000 -Duration 10m -ResultPolicy normal `
  -Regions ap-northeast-2 -InstanceTypes "api=c7i.large×2;k6=c7i.2xlarge" `
  -Jvm "-Xms2g -Xmx2g" -Pool "hikari=20;redis=<measured>" `
  -MockNotify "latency=20ms;error=0" -Users 3000000 -Stock 3600000 `
  -Payload "null-body" -PreAllocatedVUs 1000 -MaxVUs 10000 -ClaimMode $true

# sold-out 계획
.\scripts\aws\run-experiment.ps1 `
  -RunType control -RunId <run-id> -BaseUrl https://<benchmark-hostname> -EventId <id> `
  -UserOffset 3000000 -Rate 5000 -Duration 10m -ResultPolicy sold-out `
  -Regions ap-northeast-2 -InstanceTypes "api=c7i.large×2;k6=c7i.2xlarge" `
  -Jvm "-Xms2g -Xmx2g" -Pool "hikari=20;redis=<measured>" `
  -MockNotify "latency=20ms;error=0" -Users 3000000 -Stock 100000 `
  -Payload "null-body" -PreAllocatedVUs 1000 -MaxVUs 10000 -ClaimMode $true

# worker recovery 계획
.\scripts\aws\run-experiment.ps1 `
  -RunType worker-recovery -RunId <run-id> -BaseUrl https://<benchmark-hostname> -EventId <id> `
  -UserOffset 6000000 -Rate 1000 -Duration 10m -ResultPolicy normal `
  -Regions ap-northeast-2 -InstanceTypes "api=c7i.large×2;k6=c7i.2xlarge" `
  -Jvm "-Xms2g -Xmx2g" -Pool "hikari=20;redis=<measured>" `
  -MockNotify "latency=20ms;error=0" -Users 600000 -Stock 720000 `
  -Payload "null-body" -PreAllocatedVUs 500 -MaxVUs 5000 -ClaimMode $true

# 발생기 calibration 계획; /loadgen-calibration의 204만 허용
.\scripts\aws\run-experiment.ps1 `
  -RunType generator-calibration -RunId <run-id> -BaseUrl https://<benchmark-hostname> -EventId <id> `
  -UserOffset 6600000 -Rate 1000 -Duration 2m -ResultPolicy calibration `
  -Regions ap-northeast-2 -InstanceTypes "k6=c7i.2xlarge" `
  -Jvm "n/a" -Pool "n/a" -MockNotify "n/a" -Users 120000 -Stock 120000 `
  -Payload "null-body" -PreAllocatedVUs 500 -MaxVUs 5000 -ClaimMode $true
```

`deploy-loadgen.ps1`은 `aws-capacity.js`, `aws-worker-recovery.js`, `aws-generator-calibration.js`와 공유 `aws-claim.js`를 deterministic package에 넣는다. 기본 local 출력은 덮어쓸 수 있으나, 명시한 `-PackageOutput`은 의도적으로 교체할 때만 `-OverwritePackageOutput`을 사용한다. 실제 배포는 local SHA-256과 일치하는 hash-addressed S3 URI만 허용한다. 배포 SSM은 archive와 canonical package manifest를 검증하고, 설치된 k6의 버전을 기록한 release별 `<sha256>.bootstrap-ok` marker를 원자적으로 만든 뒤 `/opt/coupon-loadtest`를 교체한다. SSM 성공 및 `BOOTSTRAP_K6_VERSION=...` 출력 전에는 발생기를 준비 완료로 간주하지 않는다.
AWS evidence scenario의 k6 환경 제어값은 `BASE_URL`, `EVENT_ID`, `RUN_ID`, `RATE`, `DURATION`, `PRE_ALLOCATED_VUS`, `MAX_VUS`, `USER_OFFSET`, `STOCK`, `RESULT_POLICY`, `CLAIM_MODE`, `SUMMARY_PATH` 전부를 명시한다. `RUN_ID`는 필수이며 `CLAIM_MODE=true`만 허용한다. `SUMMARY_PATH`는 빈 값, 앞뒤 공백, 줄바꿈/control 문자, backslash, `.`/`..` path segment를 거부하며 basename이 정확히 `k6-summary.json`인 명시적 경로여야 한다. fallback summary 이름은 없으므로 누락 또는 무효 `SUMMARY_PATH`는 VU를 만들기 전에 실행을 중단한다. 원격 contract는 발생기별 `SUMMARY_PATH=/opt/coupon-loadtest/evidence/<run-id>/<generator-id>/k6-summary.json`을 명시하고, wrapper를 우회해 k6를 직접 실행하지 말고 검토된 manifest와 `invoke-loadgen.ps1`가 만든 값을 사용한다.

```powershell
.\scripts\aws\deploy-loadgen.ps1 -Target both

# MUTATING / COST-INCURRING — 사용자 전용
.\scripts\aws\deploy-loadgen.ps1 -Target both `
  -ArtifactUri s3://<private-bucket>/<artifact-prefix>/<package-sha256>.tar.gz `
  -Execute -Acknowledge I_ACKNOWLEDGE_AWS_COST
```

## 원격 부하 실행

`invoke-loadgen.ps1`은 검토한 dry-run `PlanManifestPath`와 `RunId`, 이벤트, rate, duration, `Stock`, `ResultPolicy`, `ClaimMode`뿐 아니라 `base_url`, `null-body`, request body 0 byte를 정확히 대조한다. `RUN_ID`와 모든 AWS k6 환경 제어값, 발생기별 basename `k6-summary.json`인 절대 `SUMMARY_PATH`를 명시해 `CLAIM_MODE=true`로만 실행하고, scenario와 현재 package manifest hash도 재검증한다. 조건부 reservation key를 만든다. rate는 **발생기 한 대당**이며 최대 10,000, duration은 최대 60분이다. 선택된 발생기에는 동시 SSM dispatch를 사용한다. 여러 발생기의 aggregate rate와 분리된 user range를 별도로 기록한다.

```powershell
# 정상 capacity invocation dry run
.\scripts\aws\invoke-loadgen.ps1 -Target control -Experiment capacity `
  -PlanManifestPath <evidence-path>\manifest.json -RunId <run-id> -EventId <id> `
  -Rate 5000 -Duration 10m -Stock 3600000 -ResultPolicy normal `
  -PreAllocatedVus 1000 -MaxVus 10000 -UserOffset 0 -ClaimMode

# sold-out invocation dry run
.\scripts\aws\invoke-loadgen.ps1 -Target control -Experiment capacity `
  -PlanManifestPath <evidence-path>\manifest.json -RunId <run-id> -EventId <id> `
  -Rate 5000 -Duration 10m -Stock 100000 -ResultPolicy sold-out `
  -PreAllocatedVus 1000 -MaxVus 10000 -UserOffset 3000000 -ClaimMode

# worker-recovery invocation dry run
.\scripts\aws\invoke-loadgen.ps1 -Target control -Experiment worker-recovery `
  -PlanManifestPath <evidence-path>\manifest.json -RunId <run-id> -EventId <id> `
  -Rate 1000 -Duration 10m -Stock 720000 -ResultPolicy normal `
  -PreAllocatedVus 500 -MaxVus 5000 -UserOffset 6000000 -ClaimMode

# generator-calibration invocation dry run
.\scripts\aws\invoke-loadgen.ps1 -Target control -Experiment generator-calibration `
  -PlanManifestPath <evidence-path>\manifest.json -RunId <run-id> -EventId <id> `
  -Rate 1000 -Duration 2m -Stock 120000 -ResultPolicy calibration `
  -PreAllocatedVus 500 -MaxVus 5000 -UserOffset 6600000 -ClaimMode
```

실제 원격 실행은 아래처럼 `-Execute -Acknowledge I_ACKNOWLEDGE_AWS_COST`를 추가하는 사용자 전용 비용 행위다. 도쿄는 `-Target external`과 분리된 offset을 사용한다.

```powershell
# MUTATING / COST-INCURRING — 사용자 전용
.\scripts\aws\invoke-loadgen.ps1 -Target control -Experiment capacity `
  -PlanManifestPath <evidence-path>\manifest.json -RunId <run-id> -EventId <id> `
  -Rate 5000 -Duration 10m -Stock 3600000 -ResultPolicy normal `
  -PreAllocatedVus 1000 -MaxVus 10000 -UserOffset 0 -ClaimMode `
  -Execute -Acknowledge I_ACKNOWLEDGE_AWS_COST
```

성공한 각 SSM command는 정확히 다음 receipt를 출력해야 하며 둘 다 evidence에 기록한다: `EVIDENCE_PUBLICATION_URI=s3://.../evidence-publication-manifest.json VERSION_ID=...`. receipt의 manifest 자체 VersionId와 manifest 안의 **각 object의** VersionId는 구분해 보관한다. publication manifest는 정확히 여섯 object—`plan-manifest.json`, `runtime-manifest.json`, `execution-result.json`, `package-manifest.json`, `k6-summary.json`, `k6-console.txt`—만 포함하며, 각 항목에 bucket/key/SHA-256/명시적 VersionId가 있어야 한다.

## 장애 주입과 주장 규칙

**MUTATING / USER-ONLY worker recovery protocol:** 한 worker ID를 `worker_instance_ids`에서 하나만 고른다. k6를 동시 dispatch로 시작한 UTC 시각을 기록한다. pending이 존재하는 동안 정확히 그 worker만 SSM으로 중지하며, 중지는 시작 후 5분 또는 승인된 t+ 시각에만 수행한다.

```powershell
aws ssm send-command --region ap-northeast-2 --document-name AWS-RunShellScript `
  --instance-ids <one-worker-id> --parameters 'commands=["sudo systemctl stop coupon-worker-stream"]' `
  --comment "approved worker recovery stop <run-id>"
```

command ID와 UTC submit/terminal 시간을 저장하고 Redis pending 증가를 관찰한다. 승인된 대기 후 동일 ID를 SSM으로 시작한다.

```powershell
aws ssm send-command --region ap-northeast-2 --document-name AWS-RunShellScript `
  --instance-ids <one-worker-id> --parameters 'commands=["sudo systemctl start coupon-worker-stream"]' `
  --comment "approved worker recovery start <run-id>"
```

start command ID/시간, reclaim과 drain 관찰을 저장하고 DB, Redis, API, notification의 reconciliation을 캡처한다. JS scenario는 traffic-only이며 worker를 중지/시작하거나 장애를 주입하지 않는다.
API와 worker는 배포 SSM이 성공한 뒤 각각 ALB target health + 내부 `/actuator/health`, `systemctl is-active --quiet coupon-worker-stream`까지 확인해야 준비 완료다. monitoring과 mock-notify는 cloud-init 전용 구성이라 user-data 변경 시 인스턴스를 **교체**한다. 교체 중에는 기존 관측/알림의 연속성을 주장하지 말고 새 instance ID, image digest 및 SSM monitoring port-forwarding 출력을 evidence에 기록한다.

**MUTATING / USER-ONLY API fault scope:** 정상 multi-target baseline 후 API ID 하나만 선택하고, 승인된 t+ 시각에 SSM으로 해당 `coupon-api-reactive` service만 중지한다. ALB target 전이, 결과 class, 중복/over-issue 부재를 기록한 뒤 같은 ID에서 시작하여 회복을 확인한다. 한 번에 하나의 API만, baseline/회복 없이 반복 장애 금지이며 command ID와 UTC 시간을 모두 보존한다.

claim run의 각 발생기 summary는 process-local health gate다: `dropped_iterations=0`, achieved/offered ≥99.9%, transport+unexpected ≤0.1%, 정책별 threshold를 모두 만족해야 한다. 이는 여러 발생기의 전역 발급량을 증명하지 않는다. concurrent sold-out는 수집한 summary를 아래 aggregate verifier로 합쳐 **전역** `issued==stock`, `sold-out>0`, `duplicate=0`, `dropped=0`을 확인한다. durable DB consistency(초과 발급·중복 등)는 별도 SQL로만 증명하며 k6 aggregate 결과로 대체하지 않는다. 온라인 API latency는 persistence나 notification 성공의 증거가 아니다. 관측한 구성, run 수, offered/achieved rate, 정책, duration, evidence 경로를 함께 쓰고 “이 AWS 실행에서 관측됨”이라고만 주장한다.

## Evidence 수집

`collect-evidence.ps1`의 기본은 network를 하지 않는 **LOCAL-ONLY dry run**이다. 원격 evidence는 receipt의 **정확한** publication manifest URI와 VersionId를 함께 제공하거나, 모든 object의 bucket/key/VersionId/raw SHA-256을 담은 local publication manifest를 제공한다. prefix 최신 객체 복사는 금지된다. collector는 새로 소유한 빈 `EvidenceDirectory`만 만들고, 각 object를 지정 VersionId로 내려받아 hash를 검증한다. 입력과 다운로드는 `-MaximumInputBytes`(기본 10 MiB, 최대 100 MiB)로 제한하며 binary/non-UTF-8과 symlink를 거부한다. raw는 보존하고, text-only redacted 파생본은 access key, authorization, token/secret/cookie/password, AWS account ID, IP를 가린 별도 SHA-256 집합으로 저장한다.

```powershell
# 로컬 collection 계획
.\scripts\aws\collect-evidence.ps1 `
  -S3PublicationManifestUri s3://<bucket>/<prefix>/evidence-publication-manifest.json `
  -S3PublicationManifestVersionId <receipt-version-id>

# Credentialed S3 read — 사용자 전용
.\scripts\aws\collect-evidence.ps1 `
  -S3PublicationManifestUri s3://<bucket>/<prefix>/evidence-publication-manifest.json `
  -S3PublicationManifestVersionId <receipt-version-id> `
  -EvidenceDirectory <new-empty-owned-directory> `
  -DryRun:$false -Acknowledge I_ACKNOWLEDGE_AWS_COST
```

local manifest 사용 시에는 `-LocalPublicationManifestPath <path>`만 사용하며 원격 URI/VersionId와 혼용하지 않는다. raw 출력은 해석 전에 보관하고 k6, ALB, Prometheus, application, Redis, RDS, mock-notify, SQL timestamp를 상관시킨다.
원격 실행마다 `runtime-manifest.json`은 IMDSv2 AMI ID, `uname -r` kernel, `/usr/local/bin/k6 version`, `python3 --version`, `aws --version`, `rpm -q coreutils curl tar`의 package NEVRA를 기록한다. 이 manifest도 여섯 object 중 하나이며, 환경 pin의 증거이지 성능 결과는 아니다.
### Concurrent sold-out 전역 검증

두 개 이상 발생기에서 collection한 서로 다른 logical generator slot의 versioned `k6-summary.json`과, 각 summary에 정확히 대응하는 publication manifest·`plan-manifest.json`·`execution-result.json`을 사용한다. 아래는 **LOCAL-ONLY/offline** 명령이며 aggregate가 통과해도 DB 증명은 포함하지 않는다.

```powershell
python .\scripts\aws\aggregate-k6-evidence.py `
  --publication-manifest "<evidence-a>\raw\s3-005-k6-summary.json=<evidence-a>\raw\publication-manifest.json=<evidence-a>\raw\s3-001-plan-manifest.json=<evidence-a>\raw\s3-003-execution-result.json" `
  --publication-manifest "<evidence-b>\raw\s3-005-k6-summary.json=<evidence-b>\raw\publication-manifest.json=<evidence-b>\raw\s3-001-plan-manifest.json=<evidence-b>\raw\s3-003-execution-result.json" `
  --output <aggregate-output>\sold-out-aggregate.json `
  <evidence-a>\raw\s3-005-k6-summary.json `
  <evidence-b>\raw\s3-005-k6-summary.json
```

동일 path, 동일 bucket/key logical slot(VersionId가 달라도), 또는 불완전한 binding은 거부한다. verifier는 publication manifest의 정확한 object hash로 local summary·plan·result를 확인하고, exact plan/result schema에서 공통 `run_id`·`event_id`·`stock`과 `result_policy=sold-out`, `status=completed`·`k6_exit_code=0`·`summary_present=true`를 fail-closed로 확인한다. stock은 hash-bound plan에서만 도출하며 선택한 `--expected-stock`은 그 값과 정확히 같을 때만 허용한다. 이어서 각 local threshold와 전체 `coupon_issued==stock`, `coupon_sold_out>0`, `coupon_duplicate=0`, `dropped_iterations=0`을 확인한다. 해당 실행의 versioned evidence와 별개로 `scripts/aws/verify-aws-consistency.sql`을 RDS에 읽기 전용으로 실행해 durable DB consistency 결과와 timestamp를 수집한다.
### 분리된 worker recovery / API fault evidence manifest

worker recovery와 API fault는 서로 다른 `schema_version: 1` manifest 계약이다. Redis pending/reclaim/drain은 worker-recovery 주장에만 쓰며 API fault 주장에 사용하지 않는다. 각 builder는 UTF-8 JSON regular file을 한 번씩만 받고, symlink·non-file·duplicate path·누락/extra field를 거부하며 원문 SHA-256과 byte 수를 canonical manifest에 기록한다. 각 주장에는 **자신의** manifest가 반드시 있어야 하며, 다른 계약 manifest로 성공·복구·정합성을 주장하는 것은 금지한다.

#### Worker recovery

`scripts/aws/build-recovery-evidence.py`는 `stop_receipt`, `start_receipt`, `timeline`, `redis`, `mysql`, `api`, `notification`의 일곱 입력을 검증한다. receipt는 `command_id`, `status` (`Success`), `submitted_at`, `completed_at`이고 UTC `Z` 시간 및 timeline과 정확히 일치해야 한다. Redis는 pending 증가, 양수 reclaim, drain 후 0을 증명한다. MySQL은 `over_issued`/`duplicate_issues`가 0, API는 양수 `successful_requests` 및 duplicate/over-issued 0, notification은 완료되고 pending/failed 0이어야 한다.

```powershell
# LOCAL-ONLY/offline: worker-recovery의 일곱 immutable input과 새 output
python .\scripts\aws\build-recovery-evidence.py `
  --stop-receipt <raw>\worker-stop-receipt.json `
  --start-receipt <raw>\worker-start-receipt.json `
  --timeline <raw>\worker-utc-timeline.json `
  --redis <raw>\redis-pending-reclaim-drain.json `
  --mysql <raw>\mysql-consistency-row.json `
  --api <raw>\api-outcomes.json `
  --notification <raw>\notification-completion.json `
  --output <new-empty-owned-directory>\worker-recovery-evidence.json
```

#### API fault

`scripts/aws/build-api-fault-evidence.py`는 Redis/worker 입력을 받지 않으며 `stop_receipt`, `start_receipt`, `timeline`, `alb`, `api`, `mysql`의 여섯 입력만 검증한다. 모든 입력은 정확히 같은 non-empty `run_id`와 boolean이 아닌 양의 정수 `event_id`를 포함해야 한다. `stop_receipt`와 `start_receipt`의 exact schema는 `run_id`, `event_id`, `target_instance_id`, `action`, `command_id`, `status`, `submitted_at`, `completed_at`, `service`이며 각각 exact `stop`/`start` action, 서로 다른 command ID, 같은 target, 같은 승인 API service identity (`coupon-api-reactive`)를 요구한다 (`instance_id`는 허용하지 않는다). `timeline`의 exact schema는 common binding과 여섯 UTC `Z` 시각 `load_started_at`, `stop_submitted_at`, `stop_completed_at`, `start_submitted_at`, `start_completed_at`, `recovery_completed_at`이다. `alb`는 common binding, `status`, `captured_at`, `target_instance_id`, `transitions`; `api`는 common binding, `status`, `captured_at`, `successful_requests`, `transport_failures`, `transport_failure_limit`, `unexpected_responses`, `duplicate_issues`, `over_issued`; `mysql`은 common binding, `status`, `captured_at`, `over_issued`, `duplicate_issues`만 정확히 가진다. Builder는 reconciliation 전에 모든 run/event/receipt target/action/service binding을 검증한다. ALB는 선택 target이 healthy에서 이탈한 뒤 healthy로 회복했음을 보여야 하고, API는 양수 successful request, 0 unexpected/duplicate/over-issued 및 명시적 `transport_failure_limit` 이하의 `transport_failures`, MySQL은 durable over-issued/duplicate 0이어야 한다. Canonical manifest는 `run_id`, `event_id`, `target_instance_id`, `service`, stop/start action과 command ID, timeline 및 input hash/byte를 기록한다.

```powershell
# LOCAL-ONLY/offline: API fault의 여섯 immutable input과 새 output
python .\scripts\aws\build-api-fault-evidence.py `
  --stop-receipt <raw>\api-stop-receipt.json `
  --start-receipt <raw>\api-start-receipt.json `
  --timeline <raw>\api-utc-timeline.json `
  --alb <raw>\alb-target-transitions.json `
  --api <raw>\api-outcomes.json `
  --mysql <raw>\mysql-consistency-row.json `
  --output <new-empty-owned-directory>\api-fault-evidence.json
```

두 output은 key lexicographic, indent 2, trailing newline의 canonical JSON이고, input별 `sha256`/`bytes`를 포함한다. output은 atomic하게 새 경로에만 생성되며 기존 output 또는 input을 덮어쓰지 않는다.

**Credentialed S3 publication/download — 사용자 전용:** worker와 API fault를 각각 독립적으로 publish/collect한다. manifest SHA-256별로 `<artifact-prefix>/worker-recovery-evidence/<manifest-sha256>/...` 및 `<artifact-prefix>/api-fault-evidence/<manifest-sha256>/...`의 content-addressed key를 사용하고, versioning-enabled private bucket에 manifest와 각 계약 input을 immutable put 한다. 각 계약의 publication receipt에는 모든 object의 bucket/key/SHA-256/`VersionId`를 보존한다. prefix listing/latest 선택 및 overwrite는 금지한다.

수집 시 각 계약의 receipt에 적힌 정확한 bucket/key/`VersionId`로 manifest와 해당 input만 `aws s3api get-object --bucket <bucket> --key <key> --version-id <version-id> <new-local-file>` 하여 내려받고 `Get-FileHash <new-local-file> -Algorithm SHA256`으로 receipt 및 local manifest `inputs.*.sha256`/`bytes`를 대조한다. 기존 여섯-object loadgen publication도 위 `collect-evidence.ps1` 방식으로 정확한 URI/VersionId에서 별도로 검증한다. 해당 계약의 receipt, VersionId, hash, manifest 중 하나라도 없거나 다르면 그 계약의 claim을 하지 않는다.


## Teardown 및 잔존 비용

새 부하를 멈추고, evidence를 export하며, worker drain 또는 pending 상태를 기록한다. 먼저 읽기 전용 inventory를 실행한다.

```powershell
.\scripts\aws\destroy.ps1 -ExperimentTagValue <exact-project-tag>
```

**MUTATING / COST-STOPPING — 사용자 전용:** 아래의 exact confirmation이 없으면 destroy하지 않는다.

```powershell
.\scripts\aws\destroy.ps1 `
  -ExperimentTagValue <exact-project-tag> `
  -Execute -Confirm DESTROY_AWS_EXPERIMENT
```

destroy 뒤 script의 Terraform state 및 `Project=<exact-project-tag>` 잔존 검증이 서울과 도쿄 모두에서 clear인지 확인한다. TTL은 5분 regional Lambda가 tag가 맞는 EC2와 Seoul RDS 일부만 중지하는 partial backstop이고, ALB, ElastiCache, EBS/snapshot, networking, logs, budget/IAM 등은 삭제하지 않아 청구를 남길 수 있다. taggable하지 않은 resource는 수동 Cost Explorer와 Billing 콘솔/service별 확인으로 별도 점검한다. destroy 실패 또는 잔존 발견 시 비용이 멈췄다고 주장하지 않는다.