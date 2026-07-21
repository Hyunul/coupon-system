#!/usr/bin/env bash
# HikariCP 풀 크기 실험: 동일 부하(RATE, DURATION)로 pool size별 처리량/지연/대기 비교
# 사용법: bash scripts/hikari-experiment.sh "5 20 100" 1000 2m
set -u
POOLS="${1:-5 20 100}"
RATE="${2:-1000}"
DURATION="${3:-2m}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p k6-results

kill_app() {
  local pid
  pid=$(netstat -ano | grep ":8080" | grep LISTEN | awk '{print $5}' | head -1)
  if [ -n "${pid:-}" ]; then taskkill //F //PID "$pid" >/dev/null 2>&1 || true; sleep 3; fi
}

promq() {
  curl -sG "http://localhost:9090/api/v1/query" --data-urlencode "query=$1" |
    python -c "import json,sys; r=json.load(sys.stdin).get('data',{}).get('result',[]); print(r[0]['value'][1] if r else 'no-data')"
}

for POOL in $POOLS; do
  echo "===== pool=$POOL rate=$RATE duration=$DURATION ====="
  kill_app
  ./gradlew bootRun --args="--spring.datasource.hikari.maximum-pool-size=$POOL" \
    > "k6-results/bootrun-pool$POOL.log" 2>&1 &
  # 앱 기동 대기 (최대 120s)
  for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 http://localhost:8080/actuator/health 2>/dev/null)
    [ "$code" = "200" ] && { echo "app UP (pool=$POOL)"; break; }
    sleep 2
  done
  [ "$code" != "200" ] && { echo "APP FAILED TO START (pool=$POOL)"; tail -20 "k6-results/bootrun-pool$POOL.log"; continue; }

  # 시드 + 부하 + 지표 수집
  docker exec -i -e MYSQL_PWD=coupon coupon-mysql mysql -ucoupon coupon < scripts/seed-event.sql
  k6 run --summary-export "k6-results/hikari-pool$POOL.json" \
    -e RATE="$RATE" -e DURATION="$DURATION" \
    k6/scenarios/issue-baseline.js 2>"k6-results/hikari-pool$POOL.stderr.log" | tail -22

  {
    echo "pool=$POOL rate=$RATE duration=$DURATION"
    echo "hikari_pending_max=$(promq 'max_over_time(hikaricp_connections_pending[140s])')"
    echo "hikari_active_max=$(promq 'max_over_time(hikaricp_connections_active[140s])')"
    echo "hikari_timeouts=$(promq 'increase(hikaricp_connections_timeout_total[140s])')"
    echo "tomcat_busy_max=$(promq 'max_over_time(tomcat_threads_busy_threads[140s])')"
    echo "server_p99_s=$(promq 'histogram_quantile(0.99, sum by (le) (increase(http_server_requests_seconds_bucket[140s])))')"
    echo "consistency=$(docker exec -i -e MYSQL_PWD=coupon coupon-mysql mysql -ucoupon coupon -N -B < scripts/verify-consistency.sql | tr '\t' '/')"
    echo "refused=$(grep -c 'connectex' "k6-results/hikari-pool$POOL.stderr.log" || true)"
  } | tee "k6-results/hikari-pool$POOL.metrics.txt"
done

kill_app
echo "===== experiment done ====="
