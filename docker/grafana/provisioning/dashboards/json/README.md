# Grafana 대시보드 JSON

UI에서 만든 대시보드는 반드시 JSON으로 export하여 이 폴더에 커밋한다 (재현성 규칙, CLAUDE.md 참조).

- JVM 전반: Grafana.com 대시보드 ID **4701** (JVM Micrometer)을 import해 사용 후 export하여 여기에 저장
- Phase 1 커스텀 대시보드(RPS, p95/p99, hikaricp.connections.pending, tomcat.threads.busy)는 2주차 측정 작업에서 작성
