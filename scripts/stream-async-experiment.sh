#!/usr/bin/env bash
# Phase 3b: Stream 비동기 분리 후 재측정
# api(8080, record.mode=stream) + worker(8081, notify delay=3000 주입) 동시 기동 →
# 동일 100rps 부하에서 발급 p99가 흔들리지 않음을 보이고, 종료 후 Stream 드레인 → 정합성 대사
set -u
RATE="${1:-100}"
DURATION="${2:-2m}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p k6-results

kill_port() {
  local pid
  pid=$(netstat -ano | grep ":$1" | grep LISTEN | awk '{print $5}' | head -1)
  if [ -n "${pid:-}" ]; then taskkill //F //PID "$pid" >/dev/null 2>&1 || true; sleep 2; fi
}

promq() {
  curl -sG "http://localhost:9090/api/v1/query" --data-urlencode "query=$1" |
    python -c "import json,sys; r=json.load(sys.stdin).get('data',{}).get('result',[]); print(r[0]['value'][1] if r else 'no-data')"
}

kill_port 8080; kill_port 8081
docker exec coupon-redis redis-cli DEL stream:issue > /dev/null

# api: Lua+Stream 모드, 동기 알림 없음
./gradlew bootRun --args="--coupon.issue.strategy=lua --coupon.record.mode=stream" \
  > k6-results/bootrun-stream-api.log 2>&1 &
# worker: Stream 소비 + WebClient 알림(3초 지연 주입) — 지연은 워커에 갇혀야 한다
./gradlew bootRun --args="--spring.profiles.active=worker --coupon.notify.enabled=true --coupon.notify.url=http://localhost:8090/notify?delay=3000" \
  > k6-results/bootrun-stream-worker.log 2>&1 &

for PORT in 8080 8081; do
  for i in $(seq 1 90); do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://localhost:$PORT/actuator/health" 2>/dev/null)
    [ "$code" = "200" ] && { echo "port $PORT UP"; break; }
    sleep 2
  done
  [ "$code" != "200" ] && { echo "PORT $PORT FAILED"; exit 1; }
done

docker exec -i -e MYSQL_PWD=coupon coupon-mysql mysql -ucoupon coupon < scripts/seed-event.sql
docker exec -e MYSQL_PWD=coupon coupon-mysql mysql -ucoupon coupon \
  -e "UPDATE coupon_event SET total_qty=1000000 WHERE id=1"
curl -s -X PATCH http://localhost:8080/api/v1/events/1/status \
  -H "Content-Type: application/json" -d '{"status":"OPEN"}' > /dev/null

k6 run --summary-export k6-results/notify-stream.json \
  -e RATE="$RATE" -e DURATION="$DURATION" \
  k6/scenarios/issue-baseline.js 2>k6-results/notify-stream.stderr.log | tail -18

{
  echo "mode=stream rate=$RATE (worker notify delay=3000)"
  echo "tomcat_busy_max=$(promq 'max_over_time(tomcat_threads_busy_threads[140s])')"
  echo "server_p99_s=$(promq 'histogram_quantile(0.99, sum by (le) (increase(http_server_requests_seconds_bucket{uri=\"/api/v1/events/{eventId}/issues\"}[140s])))')"
} | tee k6-results/notify-stream.metrics.txt

# Stream 드레인 대기(최대 120s): DB 기록은 worker가 소비하며 따라잡는다 (eventual consistency)
REDIS_ISSUED=$(docker exec coupon-redis redis-cli SCARD issued:1)
echo "redis_issued=$REDIS_ISSUED — waiting for worker to drain..."
for i in $(seq 1 60); do
  DB_COUNT=$(docker exec -e MYSQL_PWD=coupon coupon-mysql mysql -ucoupon coupon -N -B \
    -e "SELECT COUNT(*) FROM coupon_issue WHERE event_id=1")
  [ "$DB_COUNT" = "$REDIS_ISSUED" ] && break
  sleep 2
done
XLEN=$(docker exec coupon-redis redis-cli XLEN stream:issue)
{
  echo "drain: db_count=$DB_COUNT redis_issued=$REDIS_ISSUED stream_len=$XLEN"
  echo "notify_stats=$(curl -s http://localhost:8090/health)"
  echo "dup=$(docker exec -e MYSQL_PWD=coupon coupon-mysql mysql -ucoupon coupon -N -B \
    -e 'SELECT COUNT(*) FROM (SELECT user_id FROM coupon_issue WHERE event_id=1 GROUP BY user_id HAVING COUNT(*)>1) d')"
} | tee -a k6-results/notify-stream.metrics.txt

kill_port 8080; kill_port 8081
echo "===== stream experiment done ====="
