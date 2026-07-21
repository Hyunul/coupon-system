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
$mysqlExec = { param($sqlFile)
    Get-Content (Join-Path $root "scripts\$sqlFile") -Raw |
        docker exec -i coupon-mysql mysql -ucoupon -pcoupon coupon
}

# 1) 리셋 + 시드
if (-not $NoReset) {
    Write-Host "[1/3] reset + seed" -ForegroundColor Cyan
    & $mysqlExec "seed-event.sql"
} else {
    Write-Host "[1/3] reset 건너뜀 (-NoReset)" -ForegroundColor Yellow
}

# 2) k6 실행 (결과는 k6-results/에 보존 — 리포트 작성 시 사용)
$resultDir = Join-Path $root "k6-results"
if (-not (Test-Path $resultDir)) { New-Item -ItemType Directory $resultDir | Out-Null }
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$summaryPath = Join-Path $resultDir "$Scenario-$stamp.json"

Write-Host "[2/3] k6 run $Scenario" -ForegroundColor Cyan
k6 run --summary-export "$summaryPath" @K6Args (Join-Path $root "k6\scenarios\$Scenario.js")
$k6Exit = $LASTEXITCODE
Write-Host "k6 summary: $summaryPath (exit=$k6Exit; threshold 실패는 baseline에서 정상)"

# 3) 정합성 검증 — over_issued / duplicated / qty_mismatch 모두 0 이어야 함
Write-Host "[3/3] 정합성 검증" -ForegroundColor Cyan
$verify = Get-Content (Join-Path $root "scripts\verify-consistency.sql") -Raw |
    docker exec -i coupon-mysql mysql -ucoupon -pcoupon coupon -N -B
$values = ($verify -split "\s+") | Where-Object { $_ -ne "" }
$over = [int]$values[0]; $dup = [int]$values[1]; $mismatch = [int]$values[2]
Write-Host ("over_issued={0} duplicated={1} qty_mismatch={2}" -f $over, $dup, $mismatch)

if ($over -eq 0 -and $dup -eq 0 -and $mismatch -eq 0) {
    Write-Host "정합성 OK: 초과/중복/대사 모두 0" -ForegroundColor Green
    exit 0
} else {
    Write-Host "정합성 위반 발견! 결과를 확인하세요." -ForegroundColor Red
    exit 1
}
