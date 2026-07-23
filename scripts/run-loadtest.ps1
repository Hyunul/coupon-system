# 부하테스트 일괄 실행: reset -> k6 -> 정합성 검증
# 사용법:
#   .\scripts\run-loadtest.ps1 -Scenario issue-spike
#   .\scripts\run-loadtest.ps1 -Scenario issue-baseline -K6Args "-e","RATE=500"
#   .\scripts\run-loadtest.ps1 -Scenario read-history -NoReset   # 데이터 누적 유지
param(
    [string]$Scenario = "issue-baseline",
    [switch]$NoReset,
    [string[]]$K6Args = @()
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
# MYSQL_PWD 사용: 커맨드라인 비밀번호 경고(stderr)가 PS 5.1에서 NativeCommandError로 승격되는 것을 방지
$mysqlExec = { param($sqlFile)
    Get-Content (Join-Path $root "scripts\$sqlFile") -Raw |
        docker exec -i -e MYSQL_PWD=coupon coupon-mysql mysql -ucoupon coupon
}

# 1) 리셋 + 시드
if (-not $NoReset) {
    Write-Host "[1/3] reset + seed" -ForegroundColor Cyan
    & $mysqlExec "seed-event.sql"
    # PATCH OPEN: Redis 재고/캐시 초기화 경로를 태운다 (redisson/lua 전략 필수, pessimistic 무해)
    try {
        Invoke-RestMethod -Method Patch -Uri "http://localhost:8080/api/v1/events/1/status" `
            -ContentType "application/json" -Body '{"status":"OPEN"}' | Out-Null
    } catch {
        Write-Host "PATCH OPEN 실패 — 앱이 8080에서 실행 중인지 확인" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "[1/3] reset 건너뜀 (-NoReset)" -ForegroundColor Yellow
}

# 2) k6 실행 (결과는 k6-results/에 보존 — 리포트 작성 시 사용)
$resultDir = Join-Path $root "k6-results"
if (-not (Test-Path $resultDir)) { New-Item -ItemType Directory $resultDir | Out-Null }
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$summaryPath = Join-Path $resultDir "$Scenario-$stamp.json"

Write-Host "[2/3] k6 run $Scenario" -ForegroundColor Cyan
# k6는 개별 요청 실패를 stderr 경고로 남긴다 — PS 5.1이 이를 에러로 승격해 런을 죽이지 않도록 잠시 완화
$ErrorActionPreference = "Continue"
k6 run --summary-export "$summaryPath" @K6Args (Join-Path $root "k6\scenarios\$Scenario.js")
$k6Exit = $LASTEXITCODE
$ErrorActionPreference = "Stop"
Write-Host "k6 summary: $summaryPath (exit=$k6Exit; threshold 실패는 baseline에서 정상)"

# 3) 정합성 검증 — 초과/중복 0 + Redis-DB 대사 (stream 모드는 워커 드레인을 최대 120s 대기)
Write-Host "[3/3] 정합성 검증" -ForegroundColor Cyan
$verify = Get-Content (Join-Path $root "scripts\verify-consistency.sql") -Raw |
    docker exec -i -e MYSQL_PWD=coupon coupon-mysql mysql -ucoupon coupon -N -B
$values = ($verify -split "\s+") | Where-Object { $_ -ne "" }
$over = [int]$values[0]; $dup = [int]$values[1]

$redisIssued = [int](docker exec coupon-redis redis-cli SCARD issued:1)
$dbCount = 0
foreach ($i in 1..60) {
    $dbCount = [int](docker exec -e MYSQL_PWD=coupon coupon-mysql mysql -ucoupon coupon -N -B `
        -e "SELECT COUNT(*) FROM coupon_issue WHERE event_id=1")
    if ($dbCount -eq $redisIssued) { break }
    if ($i -eq 1) { Write-Host "stream 드레인 대기 중 (워커 8081 필요)..." -ForegroundColor Yellow }
    Start-Sleep 2
}
$mismatch = [math]::Abs($dbCount - $redisIssued)
Write-Host ("over_issued={0} duplicated={1} db={2} redis_issued={3} mismatch={4}" -f $over, $dup, $dbCount, $redisIssued, $mismatch)

if ($over -eq 0 -and $dup -eq 0 -and $mismatch -eq 0) {
    Write-Host "정합성 OK: 초과/중복 0, Redis-DB 대사 일치" -ForegroundColor Green
    exit 0
} else {
    Write-Host "정합성 위반 발견! (stream 모드면 워커 기동 여부 확인)" -ForegroundColor Red
    exit 1
}
