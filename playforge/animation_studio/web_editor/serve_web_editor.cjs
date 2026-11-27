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
const { spawn } = require('node:child_process');

const WEB_DIR = __dirname;
const PROJECT_DIR = path.resolve(WEB_DIR, '..');
const WORKTREES_ROOT = path.resolve(PROJECT_DIR, '..', '..', '..');
const MAIN_REPO_ROOT = path.resolve(WORKTREES_ROOT, '..', 'GoDotProjects');
const DEFAULT_SCENE = 'res://hero/arena/hero_arena_world.tscn';
const NATIVE_DLL_PATH = path.join(PROJECT_DIR, 'addons', 'animation_studio', 'bin', 'animation_studio_pose_sampler.windows.template_debug.x86_64.dll');
const BUILD_CMD_PATH = path.join(PROJECT_DIR, 'build_and_test_local_fork.cmd');

const DEMO_SCENES = {
  ai_hero: 'res://hero/ai/hero_ai_demo.tscn',
  arena: 'res://hero/arena/hero_arena.tscn',
  world: 'res://hero/arena/hero_arena_world.tscn',
  roster: 'res://characters/character_showcase.tscn',
  quadruped: 'res://quadruped/quadruped_locomotor_studio.tscn',
  soldier: 'res://soldier/soldier_demo.tscn',
  lab: 'res://demo/animation_lab.tscn',
};

function getNativeDllStatus() {
  if (!fs.existsSync(NATIVE_DLL_PATH)) return { available: false, path: NATIVE_DLL_PATH };
  const st = fs.statSync(NATIVE_DLL_PATH);
  return { available: true, path: NATIVE_DLL_PATH, size: st.size, mtime: st.mtime.toISOString() };
}

function resolveLocalForkEditor() {
  const candidates = [
    process.env.GODOT_LOCAL_FORK_EDITOR || '',
    path.join(WORKTREES_ROOT, 'Forge-Refactoring-engine', 'bin', 'godot.windows.editor.x86_64.exe'),
    path.join(WORKTREES_ROOT, 'Forge-Refactoring-engine', 'bin', 'godot.windows.editor.x86_64.console.exe'),
    path.join(MAIN_REPO_ROOT, 'Godot_v4.7.2-stable_win64.exe'),
  ].filter(Boolean);
  for (const bin of candidates) {
    if (fs.existsSync(bin)) {
      return {
        path: path.resolve(bin),
        isFork: bin.toLowerCase().includes('forge-refactoring-engine'),
      };
    }
  }
  return null;
}

function isLoopbackDirectRequest(req) {
  const ip = String(req.socket && req.socket.remoteAddress || '');
  const isLocalIp = ip === '127.0.0.1' || ip === '::1' || ip === '::ffff:127.0.0.1';
  const forwarded = Boolean(req.headers['x-forwarded-for'] || req.headers['cf-connecting-ip'] || req.headers['cf-ray']);
  return isLocalIp && !forwarded;
}

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
const SKIP_EXTS = new Set(['.cpp', '.h', '.cmd', '.py', '.md', '.dll', '.lib', '.exp', '.obj', '.dblite', '.uid', '.import']);

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
  if (p === '/editor-frame.html') {
    sendFile(res, path.join(WEB_DIR, 'editor_frame.html'));
    return;
  }
  if (p === '/local-fork' || p === '/local-fork.html') {
    sendFile(res, path.join(WEB_DIR, 'local_fork.html'));
    return;
  }
  if (p === '/api/health') {
    const localEditor = resolveLocalForkEditor();
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify({
      ok: true,
      project: 'animation_studio',
      vendorDir: path.basename(vendorDir),
      localForkEditor: localEditor ? { available: true, isFork: localEditor.isFork, path: localEditor.path } : { available: false },
      nativeDll: getNativeDllStatus(),
    }));
    return;
  }
  if (p === '/launch-local-demo' || p === '/api/launch-local-demo') {
    const wantsJson = p === '/api/launch-local-demo' || url.searchParams.get('dry_run') === '1' || String(req.headers.accept || '').includes('application/json');
    if (!isLoopbackDirectRequest(req)) {
      res.writeHead(403, { 'Content-Type': wantsJson ? 'application/json; charset=utf-8' : 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(wantsJson ? JSON.stringify({ ok: false, error: 'loopback_only' }) : '<!doctype html><html lang="ko"><meta charset="utf-8"><body style="background:#12151b;color:#e8f0f8;font:14px system-ui;padding:24px"><h2>로컬 PC 전용 링크</h2><p><a href="/" style="color:#62e6d8">웹 에디터로 돌아가기</a></p></body></html>');
      return;
    }
    const localEditor = resolveLocalForkEditor();
    if (!localEditor) {
      res.writeHead(404, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify({ ok: false, error: 'editor_not_found' }));
      return;
    }
    const rawScene = url.searchParams.get('scene') || 'arena';
    const safeScene = DEMO_SCENES[rawScene] || (/^res:\/\/[A-Za-z0-9_./-]+\.tscn$/.test(rawScene) ? rawScene : DEMO_SCENES.arena);
    const launchArgs = ['--path', PROJECT_DIR, safeScene];
    const dryRun = url.searchParams.get('dry_run') === '1';
    let pid = null;
    if (!dryRun) {
      const child = spawn(localEditor.path, launchArgs, {
        cwd: PROJECT_DIR,
        detached: true,
        stdio: 'ignore',
        windowsHide: false,
      });
      pid = child.pid || null;
      child.unref();
    }
    res.writeHead(200, { 'Content-Type': wantsJson ? 'application/json; charset=utf-8' : 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    if (wantsJson) {
      res.end(JSON.stringify({ ok: true, dryRun, pid, isFork: localEditor.isFork, editorPath: localEditor.path, args: launchArgs }));
    } else {
      res.end(`<!doctype html><html lang="ko"><meta charset="utf-8"><title>로컬 포크 플레이어 데모 실행</title><body style="background:#12151b;color:#e8f0f8;font:14px system-ui,'Malgun Gothic',sans-serif;padding:28px;line-height:1.6"><h2 style="color:#72ebe0;margin-top:0">로컬 포크 엔진 데모를 실행했습니다</h2><p><strong>실행 파일:</strong> ${localEditor.path}</p><p><strong>열린 씬:</strong> ${safeScene}</p><p><strong>PID:</strong> ${pid ?? 'spawned'}</p><p style="margin-top:20px"><a href="/local-fork" style="color:#f39c2b;margin-right:16px">로컬 포크 런처로 돌아가기</a><a href="/" style="color:#62e6d8">웹 에디터로 돌아가기</a></p></body></html>`);
    }
    return;
  }
  if (p === '/api/build-and-test-local') {
    if (!isLoopbackDirectRequest(req)) {
      res.writeHead(403, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify({ ok: false, error: 'loopback_only', message: '로컬 빌드/테스트는 127.0.0.1에서만 허용됩니다.' }));
      return;
    }
    if (!fs.existsSync(BUILD_CMD_PATH)) {
      res.writeHead(404, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify({ ok: false, error: 'cmd_not_found' }));
      return;
    }
    const skipNative = url.searchParams.get('skip_native') === '1';
    const cmdArgs = ['/c', BUILD_CMD_PATH, '--test-only'];
    if (skipNative) cmdArgs.push('--skip-native');
    const t0 = Date.now();
    let output = '';
    const child = spawn('cmd.exe', cmdArgs, { cwd: PROJECT_DIR, windowsHide: true });
    child.stdout.on('data', (chunk) => { output += chunk.toString('utf8'); });
    child.stderr.on('data', (chunk) => { output += chunk.toString('utf8'); });
    child.on('close', (code) => {
      const elapsedSec = ((Date.now() - t0) / 1000).toFixed(1);
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify({ ok: code === 0, exitCode: code, elapsedSec, output: output.slice(-16000) }));
    });
    return;
  }
  if (p === '/launch-local-editor' || p === '/api/launch-local-editor') {
    const wantsJson = p === '/api/launch-local-editor' || url.searchParams.get('dry_run') === '1' || String(req.headers.accept || '').includes('application/json');
    if (!isLoopbackDirectRequest(req)) {
      res.writeHead(403, { 'Content-Type': wantsJson ? 'application/json; charset=utf-8' : 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
      if (wantsJson) {
        res.end(JSON.stringify({ ok: false, error: 'loopback_only', message: '로컬 포크 엔진 실행은 로컬 호스트(127.0.0.1) 접속에서만 허용됩니다.' }));
      } else {
        res.end('<!doctype html><html lang="ko"><meta charset="utf-8"><body style="background:#12151b;color:#e8f0f8;font:14px system-ui;padding:24px"><h2>로컬 PC 전용 링크</h2><p>로컬 포크 엔진 직접 실행은 호스트 PC의 <code>http://127.0.0.1:4792/launch-local-editor</code>에서만 허용됩니다.</p><p><a href="/" style="color:#62e6d8">웹 에디터로 돌아가기</a></p></body></html>');
      }
      return;
    }
    const localEditor = resolveLocalForkEditor();
    if (!localEditor) {
      res.writeHead(404, { 'Content-Type': wantsJson ? 'application/json; charset=utf-8' : 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
      if (wantsJson) {
        res.end(JSON.stringify({ ok: false, error: 'editor_not_found' }));
      } else {
        res.end('<!doctype html><html lang="ko"><meta charset="utf-8"><body style="background:#12151b;color:#ffd3d3;font:14px system-ui;padding:24px"><h2>로컬 포크 에디터를 찾을 수 없습니다</h2><p><a href="/" style="color:#62e6d8">웹 에디터로 돌아가기</a></p></body></html>');
      }
      return;
    }
    const requestedScene = url.searchParams.get('scene') || DEFAULT_SCENE;
    const safeScene = /^res:\/\/[A-Za-z0-9_./-]+\.tscn$/.test(requestedScene) ? requestedScene : DEFAULT_SCENE;
    const launchArgs = ['--editor', '--path', PROJECT_DIR, safeScene];
    const dryRun = url.searchParams.get('dry_run') === '1';
    let pid = null;
    if (!dryRun) {
      const child = spawn(localEditor.path, launchArgs, {
        cwd: PROJECT_DIR,
        detached: true,
        stdio: 'ignore',
        windowsHide: false,
      });
      pid = child.pid || null;
      child.unref();
    }
    res.writeHead(200, { 'Content-Type': wantsJson ? 'application/json; charset=utf-8' : 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    if (wantsJson) {
      res.end(JSON.stringify({ ok: true, dryRun, pid, isFork: localEditor.isFork, editorPath: localEditor.path, args: launchArgs }));
    } else {
      res.end(`<!doctype html><html lang="ko"><meta charset="utf-8"><title>로컬 포크 Godot 에디터 실행</title><body style="background:#12151b;color:#e8f0f8;font:14px system-ui,'Malgun Gothic',sans-serif;padding:28px;line-height:1.6"><h2 style="color:#f39c2b;margin-top:0">로컬 포크 Godot 에디터를 실행했습니다</h2><p><strong>엔진:</strong> ${localEditor.isFork ? 'Forge-Refactoring-engine (Godot 4.7.2 로컬 포크)' : 'Godot 4.7.2'}</p><p><strong>실행 파일:</strong> ${localEditor.path}</p><p><strong>프로젝트:</strong> ${PROJECT_DIR}</p><p><strong>열린 씬:</strong> ${safeScene}</p><p><strong>PID:</strong> ${pid ?? 'spawned'}</p><p style="margin-top:20px"><a href="/" style="color:#62e6d8;margin-right:16px">웹 에디터로 돌아가기</a><a href="/launch-local-editor" style="color:#f39c2b">다시 실행</a></p></body></html>`);
    }
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
