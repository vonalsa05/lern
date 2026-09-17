import http from 'k6/http';
import { check, fail } from 'k6';
import exec from 'k6/execution';
import { Rate, Trend } from 'k6/metrics';

const API = __ENV.API_URL || 'http://localhost:8080';
const RPS = Number(__ENV.RPS || 50);
const WRITE_RPS = Number(__ENV.WRITE_RPS || 5);
const DURATION = __ENV.DURATION || '2m';
const WARMUP = __ENV.WARMUP || '30s';
const SEED_LINKS = Number(__ENV.SEED_LINKS || 200);
const P95_MS = Number(__ENV.P95_MS || 300);
const HIT_RATIO = Number(__ENV.HIT_RATIO || 0.8);

const HOT_SHARE = 0.2;
const HOT_TRAFFIC = 0.8;

const cacheHits = new Rate('cache_hits');
const hitLatency = new Trend('read_latency_hit', true);
const missLatency = new Trend('read_latency_miss', true);

export const options = {
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  scenarios: {
    warmup: {
      executor: 'ramping-arrival-rate',
      exec: 'read',
      startRate: 1,
      timeUnit: '1s',
      preAllocatedVUs: 20,
      maxVUs: 300,
      stages: [{ target: RPS, duration: WARMUP }],
    },
    reads: {
      executor: 'constant-arrival-rate',
      exec: 'read',
      rate: RPS,
      timeUnit: '1s',
      duration: DURATION,
      startTime: WARMUP,
      preAllocatedVUs: 50,
      maxVUs: 300,
    },
    writes: {
      executor: 'constant-arrival-rate',
      exec: 'write',
      rate: WRITE_RPS,
      timeUnit: '1s',
      duration: DURATION,
      startTime: WARMUP,
      preAllocatedVUs: 5,
      maxVUs: 50,
    },
  },
  thresholds: {
    'http_reqs{endpoint:read}': ['count>0'],
    'http_reqs{endpoint:write}': ['count>0'],
    'http_req_failed{endpoint:read}': ['rate<0.01'],
    'http_req_failed{endpoint:write}': ['rate<0.01'],
    'http_req_duration{endpoint:read}': [`p(95)<${P95_MS}`, `p(99)<${P95_MS * 3}`],
    'http_req_duration{endpoint:write}': [`p(95)<${P95_MS * 2}`],
    cache_hits: [`rate>${HIT_RATIO}`],
    checks: ['rate>0.99'],
    dropped_iterations: ['count<10'],
  },
};

function cacheSource(res) {
  const header = res.headers['X-Cache'] || res.headers['x-cache'];
  if (header) {
    return header.toUpperCase();
  }
  let source = '';
  try {
    source = String(res.json('source') || '');
  } catch (err) {
    return 'UNKNOWN';
  }
  if (/cache|redis|hit/i.test(source)) {
    return 'HIT';
  }
  if (/db|postgres|generated|miss/i.test(source)) {
    return 'MISS';
  }
  return 'UNKNOWN';
}

function pickCode(codes) {
  const hot = Math.max(1, Math.floor(codes.length * HOT_SHARE));
  const pool = Math.random() < HOT_TRAFFIC ? hot : codes.length;
  return codes[Math.floor(Math.random() * pool)];
}

export function setup() {
  const ready = http.get(`${API}/readyz`, { tags: { endpoint: 'setup' } });
  if (ready.status !== 200) {
    fail(`стенд не готов: /readyz вернул ${ready.status}. Подними стек и повтори`);
  }

  const codes = [];
  for (let i = 0; i < SEED_LINKS; i++) {
    const res = http.post(
      `${API}/links`,
      JSON.stringify({ url: `https://example.org/seed/${i}` }),
      { headers: { 'Content-Type': 'application/json' }, tags: { endpoint: 'setup' } }
    );
    if (res.status !== 201) {
      fail(`посев не удался на ссылке ${i}: POST /links вернул ${res.status}`);
    }
    codes.push(res.json('code'));
  }
  console.log(`посеяно ссылок: ${codes.length}, из них горячих: ${Math.max(1, Math.floor(codes.length * HOT_SHARE))}`);
  return { codes };
}

export function read(data) {
  const warmup = exec.scenario.name === 'warmup';
  const endpoint = warmup ? 'warmup' : 'read';
  const res = http.get(`${API}/links/${pickCode(data.codes)}`, { tags: { endpoint } });

  const ok = check(res, { 'чтение отдало 200': (r) => r.status === 200 }, { endpoint });
  if (!ok || warmup) {
    return;
  }

  const hit = cacheSource(res) === 'HIT';
  cacheHits.add(hit);
  (hit ? hitLatency : missLatency).add(res.timings.duration);
}

export function write() {
  const url = `https://example.org/w/${__VU}-${__ITER}-${Date.now()}`;
  const res = http.post(`${API}/links`, JSON.stringify({ url }), {
    headers: { 'Content-Type': 'application/json' },
    tags: { endpoint: 'write' },
  });
  check(res, { 'запись отдала 201': (r) => r.status === 201 }, { endpoint: 'write' });
}

function fmt(value, digits = 1) {
  return value === undefined || value === null || Number.isNaN(value) ? '—' : Number(value).toFixed(digits);
}

function renderSummary(data) {
  const value = (name, key) => {
    const metric = (data.metrics || {})[name];
    return metric && metric.values ? metric.values[key] : undefined;
  };
  const seconds = ((data.state && data.state.testRunDurationMs) || 0) / 1000;
  const lines = [];
  const push = (text) => lines.push(text);

  push('');
  push('══════════════════ SLO ══════════════════');
  push(`Прогон ${fmt(seconds)} s: разогрев ${WARMUP} (в SLO не входит), затем ${RPS} rps чтений и ${WRITE_RPS} rps записей в течение ${DURATION}`);
  push('');
  push('ЧТЕНИЯ');
  push(`  запросов ${value('http_reqs{endpoint:read}', 'count') || 0}, ошибок ${fmt((value('http_req_failed{endpoint:read}', 'rate') || 0) * 100, 2)}%`);
  push(`  p50 ${fmt(value('http_req_duration{endpoint:read}', 'med'))} ms   p95 ${fmt(value('http_req_duration{endpoint:read}', 'p(95)'))} ms   p99 ${fmt(value('http_req_duration{endpoint:read}', 'p(99)'))} ms`);
  push('ЗАПИСИ');
  push(`  запросов ${value('http_reqs{endpoint:write}', 'count') || 0}, ошибок ${fmt((value('http_req_failed{endpoint:write}', 'rate') || 0) * 100, 2)}%`);
  push(`  p50 ${fmt(value('http_req_duration{endpoint:write}', 'med'))} ms   p95 ${fmt(value('http_req_duration{endpoint:write}', 'p(95)'))} ms`);
  push('КЭШ');
  push(`  hit ratio ${fmt((value('cache_hits', 'rate') || 0) * 100)}%   (попаданий ${value('cache_hits', 'passes') || 0}, промахов ${value('cache_hits', 'fails') || 0})`);
  push(`  p95 при попадании ${fmt(value('read_latency_hit', 'p(95)'))} ms   при промахе ${fmt(value('read_latency_miss', 'p(95)'))} ms`);

  const dropped = value('dropped_iterations', 'count') || 0;
  if (dropped > 0) {
    push('');
    push(`  ВНИМАНИЕ: k6 не выдал заданный RPS, пропущено итераций: ${dropped}.`);
    push('  Подними maxVUs или снизь RPS — иначе цифры выше относятся к меньшей нагрузке.');
  }

  push('');
  push('ПОРОГИ');
  let failed = 0;
  for (const [name, metric] of Object.entries(data.metrics || {})) {
    for (const [expr, result] of Object.entries(metric.thresholds || {})) {
      if (!result.ok) {
        failed++;
      }
      push(`  ${result.ok ? '✓' : '✗'} ${name} ${expr}`);
    }
  }
  push('');
  push(failed === 0 ? 'ВЕРДИКТ: PASS — стенд уложился в SLO' : `ВЕРДИКТ: FAIL — нарушено порогов: ${failed} (код возврата 99)`);
  push('═════════════════════════════════════════');
  push('');

  return lines.join('\n');
}

export function handleSummary(data) {
  return {
    stdout: renderSummary(data),
    '/results/summary.json': JSON.stringify(data, null, 2),
  };
}
