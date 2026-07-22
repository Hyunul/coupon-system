#!/usr/bin/env bash
# 재고 차감 3전략 비교 (roadmap 4.4): 동일 issue-spike 시나리오로 pessimistic/redisson/lua 순차 측정
# 사용법: bash scripts/strategy-compare.sh "pessimistic redisson lua"
set -u
STRATEGIES="${1:-pessimistic redisson lua}"
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

for S in $STRATEGIES; do
  echo "===== strategy=$S ====="
  kill_app
  ./gradlew bootRun --args="--coupon.issue.strategy=$S" > "k6-results/bootrun-$S.log" 2>&1 &
  for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 http://localhost:8080/actuator/health 2>/dev/null)
    [ "$code" = "200" ] && { echo "app UP ($S)"; break; }
    sleep 2
  done
  [ "$code" != "200" ] && { echo "APP FAILED ($S)"; tail -25 "k6-results/bootrun-$S.log"; continue; }

  # 시드: SQL로 이벤트 재생성 후 PATCH OPEN으로 Redis 재고/캐시 초기화 경로를 태운다
  docker exec -i -e MYSQL_PWD=coupon coupon-mysql mysql -ucoupon coupon < scripts/seed-event.sql
  curl -s -X PATCH http://localhost:8080/api/v1/events/1/status \
    -H "Content-Type: application/json" -d '{"status":"OPEN"}' > /dev/null

  k6 run --summary-export "k6-results/spike-$S.json" \
    k6/scenarios/issue-spike.js 2>"k6-results/spike-$S.stderr.log" | tail -20

  DB_COUNT=$(docker exec -e MYSQL_PWD=coupon coupon-mysql mysql -ucoupon coupon -N -B \
    -e "SELECT COUNT(*) FROM coupon_issue WHERE event_id=1")
  DUP=$(docker exec -e MYSQL_PWD=coupon coupon-mysql mysql -ucoupon coupon -N -B \
    -e "SELECT COUNT(*) FROM (SELECT user_id FROM coupon_issue WHERE event_id=1 GROUP BY user_id HAVING COUNT(*)>1) d")
  REDIS_STOCK=$(docker exec coupon-redis redis-cli GET stock:1)
  REDIS_ISSUED=$(docker exec coupon-redis redis-cli SCARD issued:1)

  {
    echo "strategy=$S"
    echo "db_count=$DB_COUNT dup=$DUP redis_stock=$REDIS_STOCK redis_issued=$REDIS_ISSUED"
    echo "server_p99_s=$(promq 'histogram_quantile(0.99, sum by (le) (increase(http_server_requests_seconds_bucket[300s])))')"
    echo "server_reqs=$(promq 'sum(increase(http_server_requests_seconds_count[300s]))')"
    echo "tomcat_busy_max=$(promq 'max_over_time(tomcat_threads_busy_threads[300s])')"
    echo "hikari_pending_max=$(promq 'max_over_time(hikaricp_connections_pending[300s])')"
    echo "refused=$(grep -c 'connectex' "k6-results/spike-$S.stderr.log" || true)"
    echo "timeouts=$(grep -c 'request timeout' "k6-results/spike-$S.stderr.log" || true)"
  } | tee "k6-results/spike-$S.metrics.txt"
done

kill_app
echo "===== compare done ====="
