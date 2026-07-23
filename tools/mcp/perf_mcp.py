#!/usr/bin/env python3
"""perf MCP 서버 (roadmap Phase 6).

k6 결과(k6-results/*.json summary)를 AI가 직접 조회·비교하게 하는 도구 —
"성능이 왜 떨어졌지?"에 데이터를 보게 한다.

의존성 0: Python 3.8 표준 라이브러리로 MCP stdio(JSON-RPC 2.0)를 직접 구현.
검증: python tools/mcp/perf_mcp.py --selftest
"""
import glob
import json
import os
import sys
import time

PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "perf", "version": "1.0.0"}
RESULT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "k6-results")

TOOLS = [
    {
        "name": "list_results",
        "description": "저장된 k6 summary 목록(파일명, 수정 시각)을 최신순으로 반환한다.",
        "inputSchema": {"type": "object", "properties": {
            "pattern": {"type": "string", "description": "파일명 필터 (예: spike, hikari). 생략 시 전체"}}},
    },
    {
        "name": "get_result",
        "description": "k6 summary 1건의 핵심 지표(요청 수, med/p95, 실패율, 체크 통과, dropped)를 반환한다.",
        "inputSchema": {"type": "object", "properties": {
            "name": {"type": "string", "description": "파일명 (확장자 .json 생략 가능)"}},
            "required": ["name"]},
    },
    {
        "name": "compare",
        "description": "두 k6 summary의 핵심 지표를 나란히 비교하고 델타(%)를 계산한다. before/after 판단에 사용.",
        "inputSchema": {"type": "object", "properties": {
            "a": {"type": "string", "description": "기준(before) 파일명"},
            "b": {"type": "string", "description": "대상(after) 파일명"}},
            "required": ["a", "b"]},
    },
]


def summarize(path):
    d = json.load(open(path, encoding="utf-8"))["metrics"]
    dur = d.get("http_req_duration", {})
    exp = d.get("http_req_duration{expected_response:true}", {})
    checks = d.get("checks", {})
    return {
        "reqs": int(d.get("http_reqs", {}).get("count", 0)),
        "med_ms": round(dur.get("med", 0), 1),
        "p95_ms": round(dur.get("p(95)", 0), 1),
        "failed_pct": round(d.get("http_req_failed", {}).get("value", 0) * 100, 2),
        "checks_ok": int(checks.get("passes", 0)),
        "dropped": int(d.get("dropped_iterations", {}).get("count", 0)),
        "expected_med_ms": round(exp.get("med", 0), 1),
        "expected_p95_ms": round(exp.get("p(95)", 0), 1),
    }


def resolve(name):
    if not name.endswith(".json"):
        name += ".json"
    path = os.path.join(RESULT_DIR, os.path.basename(name))
    if not os.path.isfile(path):
        raise ValueError("결과 없음: {} (list_results로 확인)".format(name))
    return path


def tool_list_results(args):
    pattern = (args.get("pattern") or "").lower()
    rows = []
    for p in glob.glob(os.path.join(RESULT_DIR, "*.json")):
        base = os.path.basename(p)
        if pattern and pattern not in base.lower():
            continue
        rows.append((os.path.getmtime(p), base))
    rows.sort(reverse=True)
    if not rows:
        return "저장된 k6 summary가 없습니다 (필터: '{}')".format(pattern)
    return "\n".join("{}  {}".format(time.strftime("%m-%d %H:%M", time.localtime(m)), b) for m, b in rows[:40])


def tool_get_result(args):
    s = summarize(resolve(args["name"]))
    return json.dumps(s, ensure_ascii=False, indent=2)


def tool_compare(args):
    a, b = summarize(resolve(args["a"])), summarize(resolve(args["b"]))
    lines = ["{:<18}{:>12}{:>12}{:>10}".format("지표", "A(before)", "B(after)", "델타")]
    for k in a:
        av, bv = a[k], b[k]
        delta = "-" if av == 0 else "{:+.1f}%".format((bv - av) / av * 100)
        lines.append("{:<18}{:>12}{:>12}{:>10}".format(k, av, bv, delta))
    return "\n".join(lines)


HANDLERS = {"list_results": tool_list_results, "get_result": tool_get_result, "compare": tool_compare}


def handle(msg):
    method = msg.get("method")
    msg_id = msg.get("id")
    if method == "initialize":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {
            "protocolVersion": PROTOCOL_VERSION, "capabilities": {"tools": {}}, "serverInfo": SERVER_INFO}}
    if method == "notifications/initialized":
        return None
    if method == "ping":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {"tools": TOOLS}}
    if method == "tools/call":
        params = msg.get("params") or {}
        handler = HANDLERS.get(params.get("name"))
        if handler is None:
            return {"jsonrpc": "2.0", "id": msg_id,
                    "error": {"code": -32602, "message": "unknown tool"}}
        try:
            text = handler(params.get("arguments") or {})
            return {"jsonrpc": "2.0", "id": msg_id, "result": {
                "content": [{"type": "text", "text": text}], "isError": False}}
        except Exception as e:
            return {"jsonrpc": "2.0", "id": msg_id, "result": {
                "content": [{"type": "text", "text": "오류: {}".format(e)}], "isError": True}}
    if msg_id is not None:
        return {"jsonrpc": "2.0", "id": msg_id,
                "error": {"code": -32601, "message": "method not found"}}
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
    r = handle({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
    assert len(r["result"]["tools"]) == 3
    r = handle({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                "params": {"name": "list_results", "arguments": {"pattern": "gc"}}})
    listing = r["result"]["content"][0]["text"]
    assert "gc-" in listing, listing
    r = handle({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                "params": {"name": "compare", "arguments": {"a": "gc-default", "b": "gc-g1tuned"}}})
    table = r["result"]["content"][0]["text"]
    assert not r["result"]["isError"], table
    assert "p95_ms" in table
    print("selftest: ALL PASS")
    print(table)


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    else:
        serve()
