# 로컬 HA 스택 원커맨드 기동: 인프라(docker) + 앱 2대 + 워커 + 시드까지
# 사용법: .\scripts\start-local-ha.ps1        (종료: .\scripts\stop-local-ha.ps1)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Host "[1/4] 인프라 기동 (docker compose --profile lb)" -ForegroundColor Cyan
docker compose -f docker/docker-compose.yml --profile lb up -d
foreach ($i in 1..30) {
    $h = docker inspect --format "{{.State.Health.Status}}" coupon-mysql 2>$null
    if ($h -eq "healthy") { break }
    Start-Sleep 2
}

Write-Host "[2/4] 앱 2대(8082/8083) + 워커(8081) 기동" -ForegroundColor Cyan
if (-not (Test-Path "k6-results")) { New-Item -ItemType Directory "k6-results" | Out-Null }

# PS 5.1 Start-Process는 공백 포함 인자를 자동 인용하지 않는다 — 전체 커맨드라인을 단일 문자열로 구성
function Start-BootRun([string]$bootArgs, [string]$logName) {
    Start-Process -FilePath ".\gradlew.bat" -ArgumentList "bootRun `"--args=$bootArgs`"" `
        -WindowStyle Hidden `
        -RedirectStandardOutput "k6-results\$logName.log" -RedirectStandardError "k6-results\$logName.err.log"
}
Start-BootRun "--server.port=8082" "local-ha-8082"
Start-BootRun "--server.port=8083" "local-ha-8083"
Start-BootRun "--spring.profiles.active=worker --coupon.notify.enabled=true" "local-ha-worker"

$logNames = @{ 8082 = "local-ha-8082"; 8083 = "local-ha-8083"; 8081 = "local-ha-worker" }
foreach ($port in 8082, 8083, 8081) {
    $up = $false
    foreach ($i in 1..90) {
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:$port/actuator/health" -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -eq 200) { $up = $true; Write-Host "  port $port UP"; break }
        } catch {}
        Start-Sleep 2
    }
    if (-not $up) { Write-Host ("port $port 기동 실패 — k6-results\{0}.err.log 확인" -f $logNames[$port]) -ForegroundColor Red; exit 1 }
}

Write-Host "[3/4] 이벤트 시드 + OPEN (Redis 재고 초기화)" -ForegroundColor Cyan
Get-Content "scripts\seed-event.sql" -Raw | docker exec -i -e MYSQL_PWD=coupon coupon-mysql mysql -ucoupon coupon
Invoke-RestMethod -Method Patch -Uri "http://localhost:8080/api/v1/events/1/status" `
    -ContentType "application/json" -Body '{"status":"OPEN"}' | Out-Null

Write-Host "[4/4] 완료" -ForegroundColor Green
Write-Host @"
  API (Nginx LB) : http://localhost:8080   (앱 직결: 8082 / 8083, 워커: 8081)
  Grafana        : http://localhost:3000   Prometheus: 9090  Alertmanager: 9093
  발급 예시      : curl -X POST http://localhost:8080/api/v1/events/1/issues -H "X-USER-ID: 1"
  부하테스트     : .\scripts\run-loadtest.ps1 -Scenario issue-baseline -K6Args "-e","RATE=300"
"@
