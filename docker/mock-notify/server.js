// 의존성 0개 mock 알림 서버.
// POST /notify?delay=3000&errorRate=0.3  — delay(ms) 대기 후 응답, errorRate 확률로 500
// GET  /health                            — 200
// env DEFAULT_DELAY_MS: 쿼리 파라미터 없이도 전역 기본 지연 주입 (장애 훈련용)
const http = require('http');

const PORT = process.env.PORT || 8090;
const DEFAULT_DELAY_MS = parseInt(process.env.DEFAULT_DELAY_MS || '0', 10);

let received = 0;
let failed = 0;

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  if (req.method === 'GET' && url.pathname === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'UP', received, failed }));
    return;
  }

  if (req.method === 'POST' && url.pathname === '/notify') {
    const delay = parseInt(url.searchParams.get('delay') || DEFAULT_DELAY_MS, 10) || 0;
    const errorRate = parseFloat(url.searchParams.get('errorRate') || '0') || 0;
    received++;

    setTimeout(() => {
      if (Math.random() < errorRate) {
        failed++;
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ code: 'NOTIFY_FAILED', message: 'injected failure' }));
      } else {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ code: 'OK', delayedMs: delay }));
      }
    }, delay);
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ code: 'NOT_FOUND' }));
});

server.listen(PORT, () => {
  console.log(`mock-notify listening on :${PORT} (DEFAULT_DELAY_MS=${DEFAULT_DELAY_MS})`);
});
