#!/usr/bin/env python3
"""PreToolUse 권한 가드 (roadmap Phase 6 — "AI에게 권한 가드를 설계했다").

Bash/PowerShell 명령에서 파괴적 패턴을 차단한다:
  - DROP TABLE / DROP DATABASE (스키마 파괴 — 변경은 Flyway로만)
  - rm -rf 류의 루트/홈/프로젝트 전체 삭제
  - git push --force (측정 기록이 곧 자산인 저장소의 이력 파괴 방지)
  - docker volume rm / compose down -v (mysql-data 볼륨 = 누적 실험 데이터)

허용 예외: TRUNCATE는 reset-test.sql의 의도된 동작이므로 차단하지 않는다.
종료 코드 2 = 차단(사유는 stderr), 0 = 허용.
"""
import json
import re
import sys

BLOCK_PATTERNS = [
    (r"(?i)\bDROP\s+(TABLE|DATABASE|SCHEMA)\b", "DROP은 차단됨 — 스키마 변경은 Flyway 마이그레이션으로만"),
    (r"rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)\s+([/~]|[A-Za-z]:[\\/]|\.\s*$|\*)",
     "rm -rf (루트/홈/드라이브/전체) 차단"),
    (r"git\s+push\s+[^\n]*(--force|-f\b)", "git push --force 차단 — 측정 기록 이력 보호"),
    (r"docker\s+volume\s+rm", "docker volume rm 차단 — mysql-data는 누적 실험 데이터"),
    (r"docker\s+compose[^\n]*\bdown\b[^\n]*(-v|--volumes)", "compose down -v 차단 — 볼륨 보존"),
]


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0  # 파싱 실패 시 차단하지 않음 (가드 오작동으로 작업 마비 방지)

    tool = payload.get("tool_name", "")
    if tool not in ("Bash", "PowerShell"):
        return 0
    command = (payload.get("tool_input") or {}).get("command", "") or ""

    for pattern, reason in BLOCK_PATTERNS:
        if re.search(pattern, command):
            print(f"[guard] 차단: {reason}\n대상 명령: {command[:200]}", file=sys.stderr)
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
