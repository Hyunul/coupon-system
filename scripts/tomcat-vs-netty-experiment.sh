#!/usr/bin/env bash
# Phase 3c: Tomcat(MVC) vs Netty(WebFlux) — 동일 커밋·동일 스파이크·동일 lua+stream 모드 비교
# 사용법: bash scripts/tomcat-vs-netty-experiment.sh servlet   (또는 reactive)
set -u
MODE="${1:?servlet | reactive}"
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

if [ "$MODE" = "servlet" ]; then
  API_ARGS="--coupon.issue.strategy=lua --coupon.record.mode=stream"
else
  API_ARGS="--spring.profiles.active=reactive"
fi

./gradlew bootRun --args="$API_ARGS" > "k6-results/bootrun-$MODE-api.log" 2>&1 &
# 워커: 알림 비활성(핫패스 비교에 집중), Stream 소비로 DB 드레인만 담당
./gradlew bootRun --args="--spring.profiles.active=worker" > "k6-results/bootrun-$MODE-worker.log" 2>&1 &

for PORT in 8080 8081; do
  for i in $(seq 1 90); do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://localhost:$PORT/actuator/health" 2>/dev/null)
    [ "$code" = "200" ] && { echo "port $PORT UP"; break; }
    sleep 2
  done
  [ "$code" != "200" ] && { echo "PORT $PORT FAILED"; tail -25 "k6-results/bootrun-$MODE-api.log"; exit 1; }
done

docker exec -i -e MYSQL_PWD=coupon coupon-mysql mysql -ucoupon coupon < scripts/seed-event.sql
curl -s -X PATCH http://localhost:8080/api/v1/events/1/status \
  -H "Content-Type: application/json" -d '{"status":"OPEN"}' > /dev/null

k6 run --summary-export "k6-results/spike-$MODE-3c.json" \
  k6/scenarios/issue-spike.js 2>"k6-results/spike-$MODE-3c.stderr.log" | tail -18

REDIS_ISSUED=$(docker exec coupon-redis redis-cli SCARD issued:1)
for i in $(seq 1 60); do
  DB_COUNT=$(docker exec -e MYSQL_PWD=coupon coupon-mysql mysql -ucoupon coupon -N -B \
    -e "SELECT COUNT(*) FROM coupon_issue WHERE event_id=1")
  [ "$DB_COUNT" = "$REDIS_ISSUED" ] && break
  sleep 2
done

{
  echo "mode=$MODE"
  echo "drain: db_count=$DB_COUNT redis_issued=$REDIS_ISSUED"
  echo "dup=$(docker exec -e MYSQL_PWD=coupon coupon-mysql mysql -ucoupon coupon -N -B \
    -e 'SELECT COUNT(*) FROM (SELECT user_id FROM coupon_issue WHERE event_id=1 GROUP BY user_id HAVING COUNT(*)>1) d')"
  echo "jvm_threads_max=$(promq 'max_over_time(jvm_threads_live_threads{application=\"coupon-api\"}[300s])')"
  echo "jvm_threads_max_nolabel=$(promq 'max_over_time(jvm_threads_live_threads[300s])')"
  echo "refused=$(grep -c 'connectex' "k6-results/spike-$MODE-3c.stderr.log" || true)"
  echo "timeouts=$(grep -c 'request timeout' "k6-results/spike-$MODE-3c.stderr.log" || true)"
} | tee "k6-results/spike-$MODE-3c.metrics.txt"

kill_port 8080; kill_port 8081
echo "===== $MODE done ====="
