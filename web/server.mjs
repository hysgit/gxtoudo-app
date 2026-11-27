import { createServer } from 'node:http';
import { createHash, randomBytes } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { pathToFileURL } from 'node:url';

const publicFiles = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/app.css', ['app.css', 'text/css; charset=utf-8']],
  ...['app', 'api', 'domain', 'store', 'view', 'qrcodegen', 'icons'].map(name =>
    ['/' + name + '.mjs', [name + '.mjs', 'text/javascript; charset=utf-8']]),
]);
const routes = new Map([
  ['/api/teams', ['/team/list', 'GET']],
  ['/api/sync', ['/sync/do', 'POST']],
  ['/api/ai/list', ['/ai/chat', 'GET']],
  ['/api/ai/send', ['/ai/chat', 'POST']],
  ['/api/ai/image', ['/ai/image', 'GET']],
  ['/api/files/read', ['/media/read', 'POST']],
]);
const oneDay = 24 * 60 * 60 * 1000;
const jsonLimit = 16 * 1024 * 1024;
const fileLimit = 100 * 1024 * 1024;
const secret = count => randomBytes(count).toString('hex');

class RequestError extends Error {
  constructor(status, message, code) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

async function bytes(req, limit) {
  if (Number(req.headers['content-length']) > limit) throw new RequestError(413, '内容超出大小限制');
  const chunks = [];
  let size = 0;
  for await (const chunk of req.iterator({ destroyOnReturn: false })) {
    size += chunk.length;
    if (size > limit) throw new RequestError(413, '内容超出大小限制');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, size);
}

async function jsonBody(req) {
  if (!/^application\/json(?:\s*;|$)/i.test(req.headers['content-type'] ?? '')) {
    throw new RequestError(415, '请求格式无效');
  }
  try {
    const data = JSON.parse(await bytes(req, jsonLimit));
    if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error();
    return data;
  } catch (error) {
    if (error instanceof RequestError) throw error;
    throw new RequestError(400, '请求格式无效');
  }
}

function publicAccount(session) {
  return { id: session.user_id, name: session.name, personal: session.personal, spaces: session.spaces, server: session.server };
}

export function createWebServer({ upstream = 'https://tudosrv.woslx.com', origin, qrOrigin } = {}) {
  const base = new URL(upstream);
  const local = ['localhost', '127.0.0.1', '[::1]'].includes(base.hostname);
  if ((!local && base.protocol !== 'https:') || !['https:', 'http:'].includes(base.protocol) ||
      base.href !== base.origin + '/') throw new Error('GXTODO_UPSTREAM 必须是服务端来源地址');
  const mobileOrigin = qrOrigin ? new URL(qrOrigin) : base;
  if (mobileOrigin.href !== mobileOrigin.origin + '/' || (mobileOrigin.protocol !== 'https:' && !local)) {
    throw new Error('GXTODO_QR_ORIGIN 无效');
  }
  const publicOrigin = origin ? new URL(origin) : null;
  if (publicOrigin && (publicOrigin.href !== publicOrigin.origin + '/' || !['http:', 'https:'].includes(publicOrigin.protocol))) {
    throw new Error('GXTODO_WEB_ORIGIN 必须是网页来源地址');
  }

  const sessions = new Map();
  const grants = new Map();
  const cookie = (key, id, age) =>
    `${key}=${id}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${age}${publicOrigin?.protocol === 'https:' ? '; Secure' : ''}`;

  function lookup(req, key, map) {
    const id = (req.headers.cookie ?? '').match(new RegExp(`(?:^|;\\s*)${key}=([0-9a-f]{64})(?:;|$)`))?.[1];
    const entry = map.get(id);
    if (entry && entry.expires > Date.now()) return [id, entry];
    if (entry) map.delete(id);
    return [id, null];
  }

  async function api(path, body, binary = false) {
    let reply;
    try {
      reply = await fetch(new URL('/api/v7' + path, base), {
        method: 'POST', redirect: 'error', signal: AbortSignal.timeout(90_000),
        ...(body instanceof FormData ? { body } : {
          headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
        }),
      });
    } catch {
      throw new RequestError(502, '暂时无法连接 Todo 服务，请稍后重试');
    }
    if (!reply.ok) {
      await reply.body?.cancel();
      throw new RequestError(502, 'Todo 服务暂时无法处理请求');
    }
    if (binary && !reply.headers.get('content-type')?.includes('application/json')) return reply;
    const data = await reply.json().catch(() => null);
    if (!data) throw new RequestError(502, 'Todo 服务响应无效');
    if (String(data.status) !== '0') {
      const expired = String(data.status) === '5';
      throw new RequestError(expired ? 401 : 422, data.message || 'Todo 服务请求失败', String(data.status));
    }
    return data;
  }

  async function handle(req, res) {
    const path = new URL(req.url, 'http://localhost').pathname;
    const json = (data, status = 200) => {
      res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify(data));
    };
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Cross-Origin-Resource-Policy', 'same-origin');
    res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob:; media-src 'self' blob:; connect-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'");
    if (req.method === 'GET' && publicFiles.has(path)) {
      const [file, contentType] = publicFiles.get(path);
      const body = await readFile(new URL('./public/' + file, import.meta.url));
      res.writeHead(200, { 'Content-Type': contentType, 'Cache-Control': 'no-cache' });
      res.end(body);
      return;
    }
    if (req.method === 'GET' && path === '/health') { json({ status: 'ok' }); return; }
    if (req.headers['sec-fetch-site'] === 'cross-site') throw new RequestError(403, '请求来源无效');
    if (req.method === 'GET' && path === '/api/session') {
      const [, session] = lookup(req, 'gx_session', sessions);
      json({ account: session ? publicAccount(session) : null, offlineCache: !session });
      return;
    }
    if (req.method !== 'POST') throw new RequestError(404, '页面不存在');
    const expected = publicOrigin?.origin || `http://${req.headers.host}`;
    if (req.headers.origin !== expected) throw new RequestError(403, '请求来源无效');

    if (path === '/api/login') {
      await jsonBody(req);
      const [old] = lookup(req, 'gx_login', grants);
      grants.delete(old);
      if (grants.size >= 1500) throw new RequestError(429, '当前扫码请求较多，请稍后重试');
      const id = secret(32);
      const verifier = randomBytes(32).toString('base64url');
      const challenge = createHash('sha256').update(verifier).digest('hex');
      const data = await api('/desktop-login/start', { challenge, dev_id: 'desktop-' + secret(16), label: '高效 Todo 网页版' });
      const duration = Math.max(0, Math.min(120, Number(data.valid_seconds) || 0));
      if (!data.request || !duration) throw new RequestError(502, '无法生成二维码');
      grants.set(id, { request: data.request, verifier, expires: Date.now() + duration * 1000 });
      res.setHeader('Set-Cookie', cookie('gx_login', id, duration));
      const qr = 'gxtodo://desktop-login?' + new URLSearchParams({ server: mobileOrigin.origin, request: data.request });
      json({ qr, code: data.code, duration });
      return;
    }
    if (path === '/api/login/poll') {
      await jsonBody(req);
      const [id, grant] = lookup(req, 'gx_login', grants);
      if (!grant) throw new RequestError(422, '二维码已过期，请刷新', '410');
      if (grant.busy) { json({ account: null }); return; }
      grant.busy = true;
      try {
        const data = await api('/desktop-login/poll', { request: grant.request, verifier: grant.verifier });
        if (data.state !== 'complete') { json({ account: null }); return; }
        const spaces = Array.isArray(data.teamData) ? data.teamData : [];
        const session = {
          user_id: Number(data.user_id), login_id: Number(data.login_id), token: data.token,
          personal: Number(spaces.find(space => Number(space.type) === 1)?.id),
          name: String(data.data?.nickname || data.data?.email || '我的账户'),
          spaces, server: base.origin, expires: Date.now() + 7 * oneDay,
        };
        if (!session.user_id || !session.login_id || !session.token || !session.personal) {
          throw new RequestError(502, '登录响应不完整');
        }
        grants.delete(id);
        const [oldSession] = lookup(req, 'gx_session', sessions);
        sessions.delete(oldSession);
        const sid = secret(32);
        sessions.set(sid, session);
        res.setHeader('Set-Cookie', [cookie('gx_session', sid, 7 * 86400), cookie('gx_login', '', 0)]);
        json({ account: publicAccount(session) });
      } finally {
        grant.busy = false;
      }
      return;
    }
    const [sid, session] = lookup(req, 'gx_session', sessions);
    if (path === '/api/logout') {
      await jsonBody(req);
      sessions.delete(sid);
      res.setHeader('Set-Cookie', [cookie('gx_session', '', 0), cookie('gx_login', '', 0)]);
      if (session) await api('/user/session', {
        _method: 'DELETE', user_id: session.user_id, login_id: session.login_id, token: session.token,
      }).catch(() => {});
      json({});
      return;
    }
    if (!session) throw new RequestError(401, '请用手机重新扫码登录');
    const auth = { user_id: session.user_id, login_id: session.login_id, token: session.token };
    if (path === '/api/files/upload') {
      const type = req.headers['content-type'] ?? '';
      if (!type.startsWith('multipart/form-data;')) throw new RequestError(415, '附件格式无效');
      const content = await bytes(req, fileLimit + 32768);
      const form = await new Response(content, { headers: { 'Content-Type': type } }).formData()
        .catch(() => { throw new RequestError(400, '附件格式无效'); });
      const file = form.get('file');
      if (!(file instanceof Blob) || !file.size || file.size > fileLimit) throw new RequestError(413, '附件上限 100 MB');
      const payload = new FormData();
      for (const key of ['team_id', 'note_id', 'kind', 'parent_table', 'client_id', 'sha256']) {
        const value = form.get(key);
        if (typeof value !== 'string' || value.length > 150) throw new RequestError(400, '附件信息无效');
        payload.set(key, value);
      }
      payload.set('file', file, file.name);
      for (const [key, value] of Object.entries(auth)) payload.set(key, value);
      json(await api('/media/upload', payload));
      return;
    }
    const route = routes.get(path);
    if (!route) throw new RequestError(404, '请求不存在');
    const [target, method] = route;
    const params = await jsonBody(req);
    try {
      const data = await api(target, { ...params, ...auth, _method: method }, path === '/api/files/read');
      if (data instanceof Response) {
        res.writeHead(200, {
          'Content-Type': 'application/octet-stream', 'X-File-Type': data.headers.get('content-type') || 'application/octet-stream',
          'Cache-Control': 'private, no-store', 'Content-Disposition': 'attachment',
        });
        if (data.body) await pipeline(Readable.fromWeb(data.body), res);
        else res.end();
      } else json(data);
    } catch (error) {
      if (error.status === 401) {
        sessions.delete(sid);
        res.setHeader('Set-Cookie', cookie('gx_session', '', 0));
      }
      throw error;
    }
  }

  const server = createServer((req, res) => {
    handle(req, res).catch(error => {
      if (res.headersSent) { res.destroy(); return; }
      if (!req.complete) {
        res.setHeader('Connection', 'close');
        req.resume();
      }
      res.writeHead(error.status || 500, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify({ message: error.status ? error.message : '网页服务暂时无法处理请求', code: error.code }));
    });
  });
  const cleanup = setInterval(() => {
    for (const map of [grants, sessions]) for (const [id, entry] of map) if (entry.expires <= Date.now()) map.delete(id);
  }, 60_000);
  cleanup.unref();
  server.on('close', () => clearInterval(cleanup));
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const host = process.env.GXTODO_WEB_HOST || '127.0.0.1';
  const port = Number(process.env.GXTODO_WEB_PORT || 18120);
  createWebServer({
    upstream: process.env.GXTODO_UPSTREAM,
    origin: process.env.GXTODO_WEB_ORIGIN,
    qrOrigin: process.env.GXTODO_QR_ORIGIN,
  }).listen(port, host, () => console.log(`高效 Todo 网页版正在 http://${host}:${port} 运行`));
}
