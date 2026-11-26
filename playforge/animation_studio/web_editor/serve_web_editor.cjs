#!/usr/bin/env node
'use strict';
/**
 * Self-contained Godot 4.7.2 Web Editor server for Animation Studio's
 * NaturalMotion Morpheme-style Authoring Replay EditorPlugin addon.
 *
 * Serves COOP/COEP headers required for WebAssembly SharedArrayBuffer threads,
 * mounts the internalized Godot project (hero_motion.res + hero_skin.glb +
 * addons/animation_studio) directly into Emscripten FS without .hkt or Havok SDK.
 */

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const WEB_DIR = __dirname;
const PROJECT_DIR = path.resolve(WEB_DIR, '..');
const WORKTREES_ROOT = path.resolve(PROJECT_DIR, '..', '..', '..');

function parseArgs(argv) {
  const out = { host: '127.0.0.1', port: 4792, vendorDir: '' };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--port' && argv[i + 1]) out.port = Number(argv[++i]);
    else if (a === '--host' && argv[i + 1]) out.host = argv[++i];
    else if (a === '--vendor-dir' && argv[i + 1]) out.vendorDir = argv[++i];
  }
  return out;
}

function resolveVendorDir(cliVendor) {
  const candidates = [
    cliVendor,
    process.env.GODOT_WEB_EDITOR_DIR || '',
    path.join(WEB_DIR, 'vendor'),
    path.join(WORKTREES_ROOT, 'Forge-AgentReplay', 'forge', 'OfficialGodot', 'vendor'),
  ].filter(Boolean);
  for (const dir of candidates) {
    if (fs.existsSync(path.join(dir, 'godot.editor.wasm')) && fs.existsSync(path.join(dir, 'godot.editor.js'))) {
      return path.resolve(dir);
    }
  }
  throw new Error('Godot Web Editor WASM vendor directory not found. Pass --vendor-dir or set GODOT_WEB_EDITOR_DIR.');
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.glb': 'model/gltf-binary',
  '.res': 'application/octet-stream',
  '.gd': 'text/plain; charset=utf-8',
  '.tscn': 'text/plain; charset=utf-8',
  '.cfg': 'text/plain; charset=utf-8',
  '.godot': 'text/plain; charset=utf-8',
};

const SKIP_DIRS = new Set(['.godot', 'generated', 'native', 'web_editor', 'bin', '__pycache__', 'tests']);
const SKIP_FILES = new Set(['animation_studio.gdextension', '.gitignore', '.gdignore']);
const SKIP_EXTS = new Set(['.cpp', '.h', '.cmd', '.py', '.md', '.dll', '.lib', '.exp', '.obj', '.dblite', '.uid']);

function collectProjectFiles(rootDir, relBase = '') {
  const list = [];
  const entries = fs.readdirSync(path.join(rootDir, relBase), { withFileTypes: true });
  for (const ent of entries) {
    const rel = relBase ? `${relBase}/${ent.name}` : ent.name;
    if (ent.isDirectory()) {
      if (SKIP_DIRS.has(ent.name)) continue;
      list.push(...collectProjectFiles(rootDir, rel));
    } else if (ent.isFile()) {
      if (SKIP_FILES.has(ent.name)) continue;
      if (SKIP_EXTS.has(path.extname(ent.name).toLowerCase())) continue;
      const st = fs.statSync(path.join(rootDir, rel));
      list.push({ path: rel, size: st.size });
    }
  }
  return list;
}

function setSecurityHeaders(res) {
  res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
  res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
  res.setHeader('Cross-Origin-Resource-Policy', 'same-origin');
}

function sendFile(res, absPath) {
  if (!fs.existsSync(absPath) || !fs.statSync(absPath).isFile()) {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Not found');
    return;
  }
  const ext = path.extname(absPath).toLowerCase();
  const st = fs.statSync(absPath);
  setSecurityHeaders(res);
  res.writeHead(200, {
    'Content-Type': MIME[ext] || 'application/octet-stream',
    'Content-Length': st.size,
    'Cache-Control': ext === '.wasm' || ext === '.glb' || ext === '.res' ? 'public, max-age=3600' : 'no-cache',
  });
  fs.createReadStream(absPath).pipe(res);
}

const args = parseArgs(process.argv);
const vendorDir = resolveVendorDir(args.vendorDir);

const server = http.createServer((req, res) => {
  const url = new URL(req.url || '/', `http://${req.headers.host || '127.0.0.1'}`);
  const p = decodeURIComponent(url.pathname);
  setSecurityHeaders(res);

  if (p === '/' || p === '/index.html') {
    sendFile(res, path.join(WEB_DIR, 'index.html'));
    return;
  }
  if (p === '/api/health') {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify({ ok: true, project: 'animation_studio', vendorDir: path.basename(vendorDir) }));
    return;
  }
  if (p === '/api/project-manifest') {
    const files = collectProjectFiles(PROJECT_DIR);
    const totalBytes = files.reduce((acc, f) => acc + f.size, 0);
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify({ ok: true, projectName: 'animation_studio', totalBytes, files }));
    return;
  }
  if (p.startsWith('/vendor/')) {
    const rel = path.normalize(p.slice('/vendor/'.length)).replace(/^(\.\.(\/|\\|$))+/, '');
    const abs = path.resolve(vendorDir, rel);
    if (!abs.startsWith(vendorDir)) {
      res.writeHead(403);
      res.end('Forbidden');
      return;
    }
    sendFile(res, abs);
    return;
  }
  if (p.startsWith('/project/')) {
    const rel = path.normalize(p.slice('/project/'.length)).replace(/^(\.\.(\/|\\|$))+/, '');
    const abs = path.resolve(PROJECT_DIR, rel);
    if (!abs.startsWith(PROJECT_DIR)) {
      res.writeHead(403);
      res.end('Forbidden');
      return;
    }
    sendFile(res, abs);
    return;
  }
  res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end('Not found');
});

server.listen(args.port, args.host, () => {
  console.log(`GODOT_WEB_EDITOR_READY http://${args.host}:${args.port}/ (vendor=${vendorDir})`);
});
