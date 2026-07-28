# 로컬 HA 스택 종료: 앱/워커 프로세스 정리 (+ -Infra 스위치로 컨테이너까지 정지)
param([switch]$Infra)
$ErrorActionPreference = "Continue"

foreach ($port in 8082, 8083, 8081) {
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) {
        # graceful: actuator shutdown 시도 후 종료 확인, 실패 시 강제 종료
        try {
            Invoke-RestMethod -Method Post -Uri "http://localhost:$port/actuator/shutdown" -TimeoutSec 3 | Out-Null
            Start-Sleep 3
        } catch {}
        $still = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($still) { Stop-Process -Id $still.OwningProcess -Force -ErrorAction SilentlyContinue }
        Write-Host "port $port stopped"
    }
}

if ($Infra) {
    $root = Split-Path -Parent $PSScriptRoot
    docker compose -f (Join-Path $root "docker/docker-compose.yml") --profile lb stop
    Write-Host "infra stopped"
}
