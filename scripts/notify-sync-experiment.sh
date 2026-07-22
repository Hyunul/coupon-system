#!/usr/bin/env bash
# Phase 3a: 동기 알림 호출의 장애 전파 재현
# healthy(지연 0) vs delayed(mock-notify delay=3000) — 동일 100rps 부하로 발급 API 붕괴를 관찰
set -u
RATE="${1:-100}"
DURATION="${2:-2m}"
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

for MODE in healthy delayed; do
  if [ "$MODE" = "healthy" ]; then URL="http://localhost:8090/notify"; else URL="http://localhost:8090/notify?delay=3000"; fi
  echo "===== notify-sync $MODE (url=$URL) ====="
  kill_app
  ./gradlew bootRun --args="--coupon.issue.strategy=lua --coupon.notify.enabled=true --coupon.notify.url=$URL" \
    > "k6-results/bootrun-notify-$MODE.log" 2>&1 &
  for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 http://localhost:8080/actuator/health 2>/dev/null)
    [ "$code" = "200" ] && { echo "app UP ($MODE)"; break; }
    sleep 2
  done
  [ "$code" != "200" ] && { echo "APP FAILED ($MODE)"; tail -25 "k6-results/bootrun-notify-$MODE.log"; continue; }

  # 시드 + 재고 확대(실험 내내 매진 없이 매 요청이 알림 경로를 타도록) + Redis 초기화
  docker exec -i -e MYSQL_PWD=coupon coupon-mysql mysql -ucoupon coupon < scripts/seed-event.sql
  docker exec -e MYSQL_PWD=coupon coupon-mysql mysql -ucoupon coupon \
    -e "UPDATE coupon_event SET total_qty=1000000 WHERE id=1"
  curl -s -X PATCH http://localhost:8080/api/v1/events/1/status \
    -H "Content-Type: application/json" -d '{"status":"OPEN"}' > /dev/null

  k6 run --summary-export "k6-results/notify-$MODE.json" \
    -e RATE="$RATE" -e DURATION="$DURATION" \
    k6/scenarios/issue-baseline.js 2>"k6-results/notify-$MODE.stderr.log" | tail -18

  {
    echo "mode=$MODE rate=$RATE"
    echo "tomcat_busy_max=$(promq 'max_over_time(tomcat_threads_busy_threads[140s])')"
    echo "server_p99_s=$(promq 'histogram_quantile(0.99, sum by (le) (increase(http_server_requests_seconds_bucket{uri=\"/api/v1/events/{eventId}/issues\"}[140s])))')"
    echo "db_count=$(docker exec -e MYSQL_PWD=coupon coupon-mysql mysql -ucoupon coupon -N -B -e 'SELECT COUNT(*) FROM coupon_issue WHERE event_id=1')"
    echo "notify_received=$(curl -s http://localhost:8090/health)"
  } | tee "k6-results/notify-$MODE.metrics.txt"
done

kill_app
echo "===== notify experiment done ====="
