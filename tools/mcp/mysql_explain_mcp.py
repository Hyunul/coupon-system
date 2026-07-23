#!/usr/bin/env python3
"""mysql-explain MCP 서버 (roadmap Phase 6).

SELECT 쿼리를 받아 로컬 MySQL(coupon-mysql 컨테이너)에서 EXPLAIN / EXPLAIN ANALYZE를
실행해 돌려준다 — AI가 실행계획을 직접 읽고 인덱스를 판단하게 하는 도구.

의존성 0: Python 3.8 표준 라이브러리만으로 MCP stdio(JSON-RPC 2.0, newline-delimited)를
직접 구현했다 (공식 SDK는 Python 3.10+ 요구).

검증: python tools/mcp/mysql_explain_mcp.py --selftest
등록: 프로젝트 루트 .mcp.json
"""
import json
import subprocess
import sys

PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "mysql-explain", "version": "1.0.0"}

TOOLS = [
    {
        "name": "explain",
        "description": (
            "SELECT 쿼리의 실행계획을 반환한다 (EXPLAIN + EXPLAIN ANALYZE). "
            "type=ALL(풀스캔), filesort, actual time을 확인해 인덱스 필요 여부를 판단할 것. "
            "SELECT만 허용된다 (읽기 전용 가드)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "실행계획을 볼 SELECT 문"}
            },
            "required": ["query"],
        },
    },
    {
        "name": "table_info",
        "description": "테이블의 인덱스 목록과 행 수를 반환한다 (SHOW INDEX + COUNT 추정).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "table": {"type": "string", "description": "테이블명 (coupon_event | coupon_issue)"}
            },
            "required": ["table"],
        },
    },
]


def run_mysql(sql):
    cmd = [
        "docker", "exec", "-e", "MYSQL_PWD=coupon", "coupon-mysql",
        "mysql", "-ucoupon", "coupon", "-e", sql,
    ]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or "mysql 실행 실패")
    return r.stdout


def tool_explain(args):
    query = (args.get("query") or "").strip().rstrip(";")
    if not query.lower().startswith("select"):
        raise ValueError("SELECT만 허용됩니다 (읽기 전용 가드)")
    plan = run_mysql("EXPLAIN {}".format(query))
    analyze = run_mysql("EXPLAIN ANALYZE {}\\G".format(query))
    return "== EXPLAIN ==\n{}\n== EXPLAIN ANALYZE ==\n{}".format(plan, analyze)


def tool_table_info(args):
    table = (args.get("table") or "").strip()
    if table not in ("coupon_event", "coupon_issue", "flyway_schema_history"):
        raise ValueError("허용 테이블: coupon_event, coupon_issue, flyway_schema_history")
    idx = run_mysql("SHOW INDEX FROM {}".format(table))
    rows = run_mysql(
        "SELECT table_rows FROM information_schema.tables "
        "WHERE table_schema='coupon' AND table_name='{}'".format(table))
    return "== SHOW INDEX ==\n{}\n== 추정 행 수 ==\n{}".format(idx, rows)


HANDLERS = {"explain": tool_explain, "table_info": tool_table_info}


def handle(msg):
    """요청 1건 처리 → 응답 dict 또는 None(notification)."""
    method = msg.get("method")
    msg_id = msg.get("id")
    if method == "initialize":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": SERVER_INFO,
        }}
    if method == "notifications/initialized":
        return None
    if method == "ping":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {"tools": TOOLS}}
    if method == "tools/call":
        params = msg.get("params") or {}
        name = params.get("name")
        handler = HANDLERS.get(name)
        if handler is None:
            return {"jsonrpc": "2.0", "id": msg_id,
                    "error": {"code": -32602, "message": "unknown tool: {}".format(name)}}
        try:
            text = handler(params.get("arguments") or {})
            return {"jsonrpc": "2.0", "id": msg_id, "result": {
                "content": [{"type": "text", "text": text}], "isError": False}}
        except Exception as e:  # 도구 실패는 isError 결과로 (프로토콜 에러 아님)
            return {"jsonrpc": "2.0", "id": msg_id, "result": {
                "content": [{"type": "text", "text": "오류: {}".format(e)}], "isError": True}}
    if msg_id is not None:
        return {"jsonrpc": "2.0", "id": msg_id,
                "error": {"code": -32601, "message": "method not found: {}".format(method)}}
    return None


def serve():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        resp = handle(msg)
        if resp is not None:
            sys.stdout.write(json.dumps(resp, ensure_ascii=False) + "\n")
            sys.stdout.flush()


def selftest():
    r1 = handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    assert r1["result"]["serverInfo"]["name"] == "mysql-explain"
    r2 = handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
    assert len(r2["result"]["tools"]) == 2
    r3 = handle({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
        "name": "explain",
        "arguments": {"query": "SELECT id FROM coupon_issue WHERE user_id=12345 ORDER BY issued_at DESC LIMIT 5"},
    }})
    text = r3["result"]["content"][0]["text"]
    assert not r3["result"]["isError"], text
    assert "EXPLAIN" in text
    r4 = handle({"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {
        "name": "explain", "arguments": {"query": "DELETE FROM coupon_issue"}}})
    assert r4["result"]["isError"], "쓰기 쿼리는 거부되어야 함"
    r5 = handle({"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {
        "name": "table_info", "arguments": {"table": "coupon_issue"}}})
    assert "idx_issue_user_issued_at" in r5["result"]["content"][0]["text"]
    print("selftest: ALL PASS")
    print(text[:400])


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    else:
        serve()
