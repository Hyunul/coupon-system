#!/usr/bin/env bash
# Phase 4: GC 설정 비교 — 동일 부하(lua+stream, 1000rps 2m)에서 pause 분포와 p99 관측
# 사용법: bash scripts/gc-experiment.sh "default g1tuned zgc"
set -u
CONFIGS="${1:-default g1tuned zgc}"
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

# 주의: 프로젝트 경로에 공백이 있어 절대 경로를 쓰면 -Xlog와 jvmArgs 분리가 깨진다.
# bootRun의 작업 디렉터리 = 프로젝트 루트이므로 상대 경로 사용.
jvm_args_for() {
  case "$1" in
    default) echo "-Xlog:gc*:file=k6-results/gc-default.log" ;;
    g1tuned) echo "-Xms2g -Xmx2g -XX:MaxGCPauseMillis=50 -Xlog:gc*:file=k6-results/gc-g1tuned.log" ;;
    zgc)     echo "-Xms2g -Xmx2g -XX:+UseZGC -XX:+ZGenerational -Xlog:gc*:file=k6-results/gc-zgc.log" ;;
  esac
}

for CFG in $CONFIGS; do
  echo "===== gc config: $CFG ====="
  kill_app
  rm -f "k6-results/gc-$CFG.log"
  ./gradlew bootRun -PbootJvmArgs="$(jvm_args_for $CFG)" \
    --args="--coupon.issue.strategy=lua --coupon.record.mode=stream" \
    > "k6-results/bootrun-gc-$CFG.log" 2>&1 &
  for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 http://localhost:8080/actuator/health 2>/dev/null)
    [ "$code" = "200" ] && { echo "app UP ($CFG)"; break; }
    sleep 2
  done
  [ "$code" != "200" ] && { echo "APP FAILED ($CFG)"; tail -20 "k6-results/bootrun-gc-$CFG.log"; continue; }

  docker exec coupon-redis redis-cli DEL stream:issue > /dev/null
  docker exec -i -e MYSQL_PWD=coupon coupon-mysql mysql -ucoupon coupon < scripts/seed-event.sql
  docker exec -e MYSQL_PWD=coupon coupon-mysql mysql -ucoupon coupon \
    -e "UPDATE coupon_event SET total_qty=1000000 WHERE id=1"
  curl -s -X PATCH http://localhost:8080/api/v1/events/1/status \
    -H "Content-Type: application/json" -d '{"status":"OPEN"}' > /dev/null

  k6 run --summary-export "k6-results/gc-$CFG.json" \
    -e RATE="$RATE" -e DURATION="$DURATION" \
    k6/scenarios/issue-baseline.js 2>"k6-results/gc-$CFG.stderr.log" | tail -6

  kill_app   # 앱 종료로 gc 로그 flush 보장

  python - "$CFG" <<'EOF'
import re, sys, json
cfg = sys.argv[1]
pauses = []
with open(f"k6-results/gc-{cfg}.log", encoding="utf-8", errors="ignore") as f:
    for line in f:
        if "Pause" in line:
            m = re.search(r"\)\s+(\d+\.\d+)ms\s*$", line.strip())
            if m:
                pauses.append(float(m.group(1)))
d = json.load(open(f"k6-results/gc-{cfg}.json"))["metrics"]
dur = d["http_req_duration"]
out = {
    "config": cfg,
    "pause_count": len(pauses),
    "pause_max_ms": round(max(pauses), 2) if pauses else 0,
    "pause_sum_ms": round(sum(pauses), 1),
    "pause_avg_ms": round(sum(pauses)/len(pauses), 2) if pauses else 0,
    "k6_med_ms": round(dur["med"], 1),
    "k6_p95_ms": round(dur["p(95)"], 1),
    "k6_reqs": int(d["http_reqs"]["count"]),
    "dropped": int(d.get("dropped_iterations", {}).get("count", 0)),
}
print(out)
open(f"k6-results/gc-{cfg}.metrics.txt", "w").write(str(out) + "\n")
EOF
done
echo "===== gc experiment done ====="
