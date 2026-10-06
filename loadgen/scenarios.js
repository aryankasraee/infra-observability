// Synthetic traffic for a multi-tenant school SaaS demo, run with k6.
//
// Why: a monitoring stack with no traffic shows flat lines. This script plays
// the role of real users all night so the dashboards, logs and alerts have
// something to show: school-website visitors, people trying to log in,
// admins opening the console, bots hitting paths that don't exist.
//
// It talks to nginx directly on the docker bridge (BASE_URL) and sets the
// Host header per site, so traffic does not go out to the CDN and back.
//
// Load is deliberately small (peak ~12 requests/second in total). The shape
// follows a day: quiet, busier, a short spike, quiet again.
//
// Hostnames and the tenant come from the environment (set by Terraform from
// var.loadgen in terraform.tfvars), so the script holds no real domains.
//
// Run locally:
//   k6 run -e BASE_URL=http://localhost -e SITE_HOST=school.example.com \
//          -e ADMIN_HOST=console.example.com -e GIT_HOST=git.example.com \
//          -e TENANT=demo-tenant loadgen/scenarios.js

import http from 'k6/http';
import { check, group, sleep } from 'k6';

const BASE = __ENV.BASE_URL || 'http://172.17.0.1';
const HOURS = Number(__ENV.HOURS || 9);
const TENANT = __ENV.TENANT || 'demo-tenant';
const SITE_HOST = __ENV.SITE_HOST || 'school.example.com';
const ADMIN_HOST = __ENV.ADMIN_HOST || 'console.example.com';
const GIT_HOST = __ENV.GIT_HOST || 'git.example.com';
const UA = 'infra-observability-loadgen/k6 (synthetic monitoring traffic)';

const PAGES = ['about', 'contact'];
const POSTS = ['new-year-start', 'science-olympiad', 'science-camp'];

// One "hour" of the shape below is stretched to fit HOURS in total.
function dayShape(peakRate) {
  const unit = Math.max(1, Math.round((HOURS * 60) / 12)); // minutes per step
  const m = (n) => `${n * unit}m`;
  return [
    { target: Math.ceil(peakRate * 0.2), duration: m(1) },
    { target: Math.ceil(peakRate * 0.5), duration: m(2) },
    { target: peakRate, duration: m(2) },
    { target: Math.ceil(peakRate * 0.6), duration: m(2) },
    { target: peakRate, duration: m(1) },
    { target: Math.ceil(peakRate * 0.3), duration: m(2) },
    { target: Math.ceil(peakRate * 0.1), duration: m(2) },
  ];
}

export const options = {
  discardResponseBodies: false,
  userAgent: UA,
  scenarios: {
    // Parents and students browsing the public school site.
    website_visitors: {
      executor: 'ramping-arrival-rate',
      exec: 'websiteVisitor',
      startRate: 1,
      timeUnit: '1m',
      preAllocatedVUs: 10,
      maxVUs: 40,
      stages: dayShape(120), // visits per minute (each visit = ~4 requests)
    },
    // People opening the admin panel and trying to sign in. Most attempts
    // use wrong passwords on purpose: failed logins are normal traffic and
    // should show up as 4xx, never as 5xx.
    admin_logins: {
      executor: 'ramping-arrival-rate',
      exec: 'adminLogin',
      startRate: 1,
      timeUnit: '1m',
      preAllocatedVUs: 5,
      maxVUs: 20,
      stages: dayShape(30),
    },
    // Platform console (single-page app shell).
    console_users: {
      executor: 'constant-arrival-rate',
      exec: 'consoleUser',
      rate: 6,
      timeUnit: '1m',
      duration: `${HOURS}h`,
      preAllocatedVUs: 2,
      maxVUs: 10,
    },
    // Crawlers and broken links: paths that should answer 404 or 401.
    bots: {
      executor: 'constant-arrival-rate',
      exec: 'bot',
      rate: 10,
      timeUnit: '1m',
      duration: `${HOURS}h`,
      preAllocatedVUs: 2,
      maxVUs: 10,
    },
    // Developers using the git server's read-only pages.
    git_readers: {
      executor: 'constant-arrival-rate',
      exec: 'gitReader',
      rate: 4,
      timeUnit: '1m',
      duration: `${HOURS}h`,
      preAllocatedVUs: 2,
      maxVUs: 10,
    },
    // A 10-minute burst in the middle of the night: "a class of 30 students
    // opens the school site at once". Shows up clearly on the dashboards.
    spike: {
      executor: 'ramping-arrival-rate',
      exec: 'websiteVisitor',
      startTime: `${Math.round(HOURS * 30)}m`,
      startRate: 0,
      timeUnit: '1s',
      preAllocatedVUs: 20,
      maxVUs: 60,
      stages: [
        { target: 5, duration: '2m' },
        { target: 5, duration: '6m' },
        { target: 0, duration: '2m' },
      ],
    },
  },
  thresholds: {
    'http_req_failed{scenario:website_visitors}': ['rate<0.02'],
    'http_req_duration{scenario:website_visitors}': ['p(95)<1500'],
    checks: ['rate>0.95'],
  },
};

const demo = { headers: { Host: SITE_HOST } };
const demoApi = { headers: { Host: SITE_HOST, 'X-Tenant-Slug': TENANT, Accept: 'application/json' } };
const pick = (a) => a[Math.floor(Math.random() * a.length)];

// 4xx are expected answers for some calls; only 5xx and timeouts are failures.
http.setResponseCallback(http.expectedStatuses({ min: 200, max: 499 }));

export function websiteVisitor() {
  group('website', () => {
    const home = http.get(`${BASE}/`, { ...demo, tags: { name: 'website /' } });
    check(home, { 'website home 200': (r) => r.status === 200 });

    const site = http.get(`${BASE}/api/lms/cms/public/site`, { ...demoApi, tags: { name: 'cms site' } });
    check(site, {
      'cms site 200': (r) => r.status === 200,
      'cms site is the right tenant': (r) => r.status === 200 && r.body.includes(`"slug":"${TENANT}"`),
    });
    sleep(Math.random() * 2);

    if (Math.random() < 0.6) {
      const slug = pick(POSTS);
      http.get(`${BASE}/blog/${slug}`, { ...demo, tags: { name: 'website /blog/:slug' } });
      const post = http.get(`${BASE}/api/lms/cms/public/posts/${slug}`, { ...demoApi, tags: { name: 'cms post' } });
      check(post, { 'cms post 200': (r) => r.status === 200 });
    } else {
      const slug = pick(PAGES);
      http.get(`${BASE}/page/${slug}`, { ...demo, tags: { name: 'website /page/:slug' } });
      const page = http.get(`${BASE}/api/lms/cms/public/pages/${slug}`, { ...demoApi, tags: { name: 'cms page' } });
      check(page, { 'cms page 200': (r) => r.status === 200 });
    }

    const layout = http.get(`${BASE}/api/lms/cms/public/layouts/home`, { ...demoApi, tags: { name: 'cms layout' } });
    check(layout, { 'cms layout 200': (r) => r.status === 200 });
  });
}

export function adminLogin() {
  group('admin', () => {
    const shell = http.get(`${BASE}/login`, { ...demo, tags: { name: 'shell /login' } });
    check(shell, { 'shell login page 200': (r) => r.status === 200 });
    http.get(`${BASE}/env.js`, { ...demo, tags: { name: 'shell env.js' } });

    // Not signed in yet: the app asks "who am I?" and must get 401, not 500.
    const me = http.get(`${BASE}/api/core/auth/me`, { ...demoApi, tags: { name: 'auth me (anon)' } });
    check(me, { 'auth/me without token is 401': (r) => r.status === 401 });

    // A wrong password: must be 401 (or 400/429), never 5xx.
    const body = JSON.stringify({ username: `user${Math.floor(Math.random() * 1000)}`, password: 'wrong-password' });
    const login = http.post(`${BASE}/api/core/auth/login`, body, {
      headers: { ...demoApi.headers, 'Content-Type': 'application/json' },
      tags: { name: 'auth login (bad password)' },
    });
    check(login, { 'bad login rejected with 4xx': (r) => r.status >= 400 && r.status < 500 });

    // An empty form: validation error, 400.
    const empty = http.post(`${BASE}/api/core/auth/login`, '{}', {
      headers: { ...demoApi.headers, 'Content-Type': 'application/json' },
      tags: { name: 'auth login (empty)' },
    });
    check(empty, { 'empty login is 400': (r) => r.status === 400 });
  });
}

export function consoleUser() {
  const opts = { headers: { Host: ADMIN_HOST } };
  const r = http.get(`${BASE}/`, { ...opts, tags: { name: 'console /' } });
  check(r, { 'console 200': (x) => x.status === 200 });
  const me = http.get(`${BASE}/api/core/auth/me`, { ...opts, tags: { name: 'console auth me (anon)' } });
  check(me, { 'console auth/me anon is 401': (x) => x.status === 401 });
}

export function bot() {
  const paths = ['/wp-login.php', '/.env', '/.git/config', '/api/lms/does-not-exist', '/api/core/nope', '/robots.txt', '/sitemap.xml'];
  const p = pick(paths);
  http.get(`${BASE}${p}`, { ...demoApi, tags: { name: 'bot probe' } });
}

export function gitReader() {
  const opts = { headers: { Host: GIT_HOST } };
  const r = http.get(`${BASE}/api/healthz`, { ...opts, tags: { name: 'gitea healthz' } });
  check(r, { 'gitea healthy': (x) => x.status === 200 });
  if (Math.random() < 0.5) {
    http.get(`${BASE}/explore/repos`, { ...opts, tags: { name: 'gitea explore' } });
  }
}
