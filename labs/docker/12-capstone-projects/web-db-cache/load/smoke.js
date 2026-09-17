import http from 'k6/http';
import { check, fail } from 'k6';

const API = __ENV.API_URL || 'http://localhost:8080';

export const options = {
  vus: 1,
  iterations: 1,
  thresholds: {
    checks: ['rate==1.0'],
  },
};

export function cacheSource(res) {
  const h = res.headers['X-Cache'] || res.headers['x-cache'];
  if (h) return h.toUpperCase();
  let src = '';
  try {
    src = String(res.json('source') || '');
  } catch (e) {
    return 'UNKNOWN';
  }
  if (/cache|redis|hit/i.test(src)) return 'HIT';
  if (/db|postgres|generated|miss/i.test(src)) return 'MISS';
  return 'UNKNOWN';
}

export default function () {
  const live = http.get(`${API}/healthz`);
  check(live, {
    'GET /healthz -> 200': (r) => r.status === 200,
    '/healthz не ходит в зависимости (< 50 ms)': (r) => r.timings.duration < 50,
  });

  const ready = http.get(`${API}/readyz`);
  check(ready, {
    'GET /readyz -> 200 на живом стенде': (r) => r.status === 200,
    '/readyz перечисляет проверенные зависимости': (r) => /db|postgres|cache|redis/i.test(r.body),
  });

  const metrics = http.get(`${API}/metrics`);
  check(metrics, {
    'GET /metrics -> 200 в формате Prometheus': (r) => r.status === 200 && r.body.includes('# TYPE'),
    '/metrics содержит гистограмму латентности': (r) => /_duration_seconds_bucket/.test(r.body),
  });

  const created = http.post(`${API}/links`, JSON.stringify({ url: 'https://example.org/smoke' }), {
    headers: { 'Content-Type': 'application/json' },
  });
  const ok = check(created, {
    'POST /links -> 201': (r) => r.status === 201,
    'POST /links возвращает code': (r) => !!r.json('code'),
  });
  if (!ok) {
    fail('контракт POST /links не выполнен — остальные проверки бессмысленны');
  }

  const code = created.json('code');

  const first = http.get(`${API}/links/${code}`);
  check(first, {
    'GET /links/{code} -> 200': (r) => r.status === 200,
    'первое чтение — промах кэша (MISS)': () => cacheSource(first) === 'MISS',
  });

  const second = http.get(`${API}/links/${code}`);
  check(second, {
    'второе чтение — попадание в кэш (HIT)': () => cacheSource(second) === 'HIT',
    'кэш отдаёт тот же url, что и БД': () => second.json('url') === first.json('url'),
  });

  const missing = http.get(`${API}/links/zzzzzzzzzz`);
  check(missing, {
    'несуществующий код -> 404': (r) => r.status === 404,
  });
}
