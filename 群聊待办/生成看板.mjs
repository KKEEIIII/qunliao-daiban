// 生成看板.mjs —— 把 群聊待办/todos.json 生成一个**自包含**的本地看板 群聊待办/看板.html
//
// 设计（为了"不引入服务器、不引入第三方包、不冒险重写 JSON"）：
//   · 看板是单个 HTML 文件，双击就能打开（数据内嵌在 <script type="application/json"> 里）
//   · 页面里勾选/忽略/重新打开 → **不直接改 todos.json**（浏览器写不了本地文件，也怕写坏）
//     而是导出一个小的"改动补丁" JSON（只含 id + 新状态），然后跑
//     生成看板.ps1 -Apply "<下载到的文件>" 由 Node 安全合并回去
//   · 推送给你的提醒（提醒器）和 MEMO.md 都会跟着更新：
//     本脚本内部复用插件里的 renderMemo（vm 抽真实源码），MEMO 格式零漂移
//
// 用法：
//   node .\群聊待办\生成看板.mjs                 # 生成/刷新 看板.html
//   node .\群聊待办\生成看板.mjs --noMemo        # 只生成看板，不动 MEMO.md
//   node .\群聊待办\生成看板.mjs --apply <补丁>  # 把看板导出的补丁合并回 todos.json
import { copyFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import vm from 'node:vm'

const here = dirname(fileURLToPath(import.meta.url))
const ws = resolve(here, '..')
const todoDir = join(ws, '群聊待办')
const todosPath = join(todoDir, 'todos.json')
const memoPath = join(todoDir, 'MEMO.md')
const boardPath = join(todoDir, '看板.html')
const pluginIndex = join(ws, 'dsh-msg-memo', 'lib', 'index.js')

const argv = process.argv.slice(2)
const NO_MEMO = argv.includes('--noMemo')
const APPLY = argv.includes('--apply')
const applyArg = APPLY ? argv[argv.indexOf('--apply') + 1] : null

function readTodos() {
  const raw = readFileSync(todosPath, 'utf8').replace(/^\uFEFF/, '')   // 去 BOM：PS 写过的 JSON 会带
  const doc = JSON.parse(raw)
  // 容忍"单元素数组被写成对象"（PowerShell ConvertTo-Json 的老坑）
  const items = Array.isArray(doc?.items) ? doc.items : doc?.items && typeof doc.items === 'object' ? [doc.items] : []
  return { doc, items }
}

/** 用插件自己的 renderMemo 重建 MEMO.md（从源码里抽函数，保证格式和插件一致） */
function renderMemoLikePlugin(items) {
  const src = readFileSync(pluginIndex, 'utf8')
  const start = src.indexOf('function renderMemo(items) {')
  if (start < 0) throw new Error('插件源码里找不到 renderMemo')
  let depth = 0
  let end = -1
  for (let i = src.indexOf('{', start); i < src.length; i += 1) {
    if (src[i] === '{') depth += 1
    else if (src[i] === '}') { depth -= 1; if (depth === 0) { end = i + 1; break } }
  }
  const fnSrc = src.slice(start, end)
  const sandbox = { console, Date, Number, String, Array, Object, JSON, Boolean }
  vm.createContext(sandbox)
  vm.runInContext(`${fnSrc}\nthis.renderMemo = renderMemo`, sandbox)
  return sandbox.renderMemo(items)
}

const nowIso = () => {
  const d = new Date()
  const off = -d.getTimezoneOffset()
  const pad = (n) => String(Math.abs(n)).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}${off >= 0 ? '+' : '-'}${pad(off / 60)}:${pad(off % 60)}`
}

// ───────────────────────── --apply：把看板导出的补丁合并回去 ─────────────────────────
if (APPLY) {
  if (!applyArg) { console.error('用法：node 生成看板.mjs --apply "<补丁文件路径>"'); process.exit(1) }
  const patchPath = resolve(applyArg)
  if (!existsSync(patchPath)) { console.error('找不到补丁文件：' + patchPath); process.exit(1) }
  const patch = JSON.parse(readFileSync(patchPath, 'utf8').replace(/^\uFEFF/, ''))
  const changes = Array.isArray(patch?.changes) ? patch.changes : []
  if (changes.length === 0) { console.log('补丁里没有任何改动，什么都没做。'); process.exit(0) }

  const { doc, items } = readTodos()
  const stamp = new Date().toISOString().replace(/[:.]/g, '-')
  copyFileSync(todosPath, `${todosPath}.bak-board-${stamp}`)
  if (existsSync(memoPath)) copyFileSync(memoPath, `${memoPath}.bak-board-${stamp}`)

  const VALID = new Set(['open', 'pending_confirm', 'done', 'ignored'])
  let applied = 0
  const skipped = []
  for (const c of changes) {
    const it = items.find((x) => x.id === c.id)
    if (!it) { skipped.push(`${c.id}（待办里找不到，可能已被归档）`); continue }
    const status = String(c.status ?? '')
    if (!VALID.has(status)) { skipped.push(`${c.id}（状态不合法：${status}）`); continue }
    if (String(it.status) === status) continue
    it.status = status
    if (status === 'open' || status === 'pending_confirm') delete it.closedAt
    else it.closedAt = nowIso()          // done/ignored 记关闭时间，插件的归档靠它
    if (c.note) it.boardNote = String(c.note)
    applied += 1
  }

  doc.items = items
  doc.updatedAt = nowIso()
  // ⚠️ 2026-10-15 深夜修（外部审查 F9）：原来先写 todos.json 再渲染 MEMO——渲染（vm 抽插件源码）一旦
  //   失败，todos 已改、MEMO 未改，用户还看到报错以为全失败。现在**先渲染、再落盘**。
  let memoText = null
  if (!NO_MEMO) memoText = renderMemoLikePlugin(items)
  writeFileSync(todosPath, JSON.stringify(doc, null, 2), 'utf8')   // 不带 BOM
  let memoNote = '（--noMemo：没动 MEMO.md）'
  if (memoText !== null) {
    writeFileSync(memoPath, memoText, 'utf8')
    memoNote = 'MEMO.md 已按插件格式重建'
  }
  console.log(`已应用 ${applied} 处改动（跳过 ${skipped.length} 处）；${memoNote}`)
  if (skipped.length) skipped.forEach((s) => console.log('  跳过：' + s))
  console.log('备份：todos.json' + `.bak-board-${stamp}`)
  process.exit(0)
}

// ───────────────────────── 默认：生成看板 ─────────────────────────
const { items } = readTodos()

const html = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>群聊待办看板</title>
<style>
  :root { --bg:#f6f7f9; --card:#fff; --line:#e3e6ea; --text:#1f2328; --dim:#6b7280; --accent:#2f6feb; }
  * { box-sizing: border-box; }
  body { margin:0; padding:24px 16px 120px; background:var(--bg); color:var(--text);
         font:15px/1.6 -apple-system,"Segoe UI","Microsoft YaHei",sans-serif; }
  .wrap { max-width: 900px; margin: 0 auto; }
  h1 { font-size:22px; margin:0 0 4px; }
  .sub { color:var(--dim); font-size:13px; margin-bottom:20px; }
  h2 { font-size:16px; margin:26px 0 10px; display:flex; align-items:center; gap:8px; }
  h2 .n { color:var(--dim); font-weight:400; font-size:13px; }
  .item { background:var(--card); border:1px solid var(--line); border-radius:10px;
          padding:12px 14px; margin-bottom:8px; display:flex; gap:12px; align-items:flex-start; }
  .item.changed { border-color:var(--accent); box-shadow:0 0 0 2px rgba(47,111,235,.12); }
  .item.done .t { text-decoration: line-through; color:var(--dim); }
  input[type=checkbox] { width:18px; height:18px; margin-top:3px; flex:0 0 auto; cursor:pointer; }
  .body { flex:1 1 auto; min-width:0; }
  .t { font-weight:600; }
  .meta { color:var(--dim); font-size:12.5px; margin-top:2px; word-break:break-all; }
  .why { color:#3d4450; font-size:13px; margin-top:6px; padding-left:8px; border-left:3px solid var(--line); }
  .ev { color:#8a9099; font-size:12.5px; margin-top:4px; white-space:pre-wrap; }
  .pill { display:inline-block; padding:1px 7px; border-radius:99px; font-size:11.5px;
          border:1px solid var(--line); color:var(--dim); margin-right:6px; }
  .pill.overdue { color:#b42318; border-color:#f4c7c3; background:#fef3f2; }
  .pill.today { color:#b54708; border-color:#f7d9a8; background:#fffaeb; }
  .pill.confirm { color:#6941c6; border-color:#ddd0fb; background:#f6f3ff; }
  .acts { flex:0 0 auto; display:flex; flex-direction:column; gap:6px; }
  .acts button { font-size:12px; padding:3px 8px; border:1px solid var(--line); background:#fff;
                 border-radius:6px; color:var(--dim); cursor:pointer; }
  .acts button:hover { color:var(--text); border-color:#c9ced6; }
  .bar { position:fixed; left:0; right:0; bottom:0; background:#1f2328; color:#fff;
         padding:12px 16px; display:flex; gap:14px; align-items:center; justify-content:center;
         font-size:14px; }
  .bar button { font-size:14px; padding:6px 14px; border-radius:8px; border:0; cursor:pointer;
                background:var(--accent); color:#fff; }
  .bar button.ghost { background:transparent; border:1px solid #5a6270; color:#d7dbe0; }
  .bar.hidden { display:none; }
  .empty { color:var(--dim); background:var(--card); border:1px dashed var(--line);
           border-radius:10px; padding:14px; }
  details summary { cursor:pointer; color:var(--dim); font-size:13px; }
</style>
</head>
<body>
<div class="wrap">
  <h1>群聊待办看板</h1>
  <div class="sub">
    数据来自 <code>群聊待办/todos.json</code>（生成于 <span id="gen">-</span>）·
    勾选后点右下角「导出改动」，再执行
    <code>powershell -File .\\群聊待办\\生成看板.ps1 -Apply "&lt;下载到的文件&gt;"</code>
  </div>
  <div id="app"></div>
</div>

<div class="bar hidden" id="bar">
  <span id="barText">-</span>
  <button id="export">导出改动</button>
  <button class="ghost" id="reset">放弃改动</button>
</div>

<script id="todo-data" type="application/json">__DATA__</script>
<script>
(function () {
  var el = document.getElementById('todo-data');
  // 用 TextDecoder 解 base64 里的 UTF-8：避免中文在 file:// 下的编码坑
  var data = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(el.textContent.trim()), function (c) { return c.charCodeAt(0); })));
  var items = data.items || [];
  document.getElementById('gen').textContent = data.generatedAt || '-';

  // 页面上的改动只存在内存里：{ id: 'done' | 'ignored' | 'open' }
  var pending = {};

  function pad(n) { return String(n).padStart(2, '0'); }
  function today0() { var d = new Date(); return new Date(d.getFullYear(), d.getMonth(), d.getDate()); }
  function dueDate(it) { return it.due ? new Date(it.due) : null; }
  function isValid(d) { return d && !isNaN(d.getTime()); }

  function bucketOf(it) {
    var st = String(it.status || 'open');
    if (st === 'done' || st === 'ignored' || st === 'expired') return 'closed';
    if (st === 'pending_confirm' || (typeof it.confidence === 'number' && it.confidence < 0.6)) return 'confirm';
    var d = dueDate(it);
    if (!isValid(d)) return 'later';
    var t0 = today0();
    if (d < t0) return 'overdue';
    if (d < new Date(t0.getTime() + 86400000)) return 'today';
    if (d < new Date(t0.getTime() + 7 * 86400000)) return 'week';
    return 'later';
  }
  var ORDER = [['overdue', '❗ 逾期'], ['today', '⏰ 今天'], ['week', '📅 本周'], ['later', '🗓 以后'], ['confirm', '❓ 待确认'], ['closed', '✅ 已完成/已忽略']];
  var LABEL = { overdue: '逾期', today: '今天', week: '本周', later: '以后', confirm: '待确认', closed: '已关闭' };

  function when(it) {
    var d = dueDate(it);
    if (!isValid(d)) return '';
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  function render() {
    var app = document.getElementById('app');
    app.textContent = '';
    var groups = {};
    ORDER.forEach(function (o) { groups[o[0]] = []; });
    items.forEach(function (it) { groups[bucketOf(it)].push(it); });

    var shown = 0;
    ORDER.forEach(function (o) {
      var key = o[0], list = groups[key];
      if (!list.length) return;
      var h = document.createElement('h2');
      h.appendChild(document.createTextNode(o[1]));
      var n = document.createElement('span'); n.className = 'n'; n.textContent = '（' + list.length + '）';
      h.appendChild(n);
      app.appendChild(h);

      list.slice().sort(function (a, b) {
        var da = dueDate(a), db = dueDate(b);
        var ta = isValid(da) ? da.getTime() : Infinity, tb = isValid(db) ? db.getTime() : Infinity;
        return ta - tb;
      }).forEach(function (it) {
        shown++;
        var eff = pending[it.id] || String(it.status || 'open');
        var closedEff = eff === 'done' || eff === 'ignored';
        var div = document.createElement('div');
        div.className = 'item' + (pending[it.id] ? ' changed' : '') + (closedEff ? ' done' : '');

        var cb = document.createElement('input');
        cb.type = 'checkbox';
        cb.checked = closedEff;
        cb.title = '勾选 = 标记完成；取消勾选 = 重新打开';
        cb.addEventListener('change', function () {
          if (cb.checked) pending[it.id] = 'done';
          else if (String(it.status) === 'done' || String(it.status) === 'ignored') pending[it.id] = 'open';
          else delete pending[it.id];
          syncBar(); render();
        });
        div.appendChild(cb);

        var body = document.createElement('div'); body.className = 'body';
        var t = document.createElement('div'); t.className = 't'; t.textContent = it.title || '(无标题)';
        body.appendChild(t);

        var pills = document.createElement('div'); pills.className = 'meta';
        var b = bucketOf(Object.assign({}, it, { status: eff }));
        var p1 = document.createElement('span'); p1.className = 'pill ' + b; p1.textContent = LABEL[b];
        pills.appendChild(p1);
        var w = when(it);
        if (w) { var p2 = document.createElement('span'); p2.className = 'pill'; p2.textContent = w; pills.appendChild(p2); }
        if (typeof it.confidence === 'number') {
          var p3 = document.createElement('span'); p3.className = 'pill'; p3.textContent = '置信 ' + it.confidence;
          pills.appendChild(p3);
        }
        pills.appendChild(document.createTextNode((it.source && it.source.chat ? '｜ ' + it.source.chat : '') +
          (it.source && it.source.sender ? ' · ' + it.source.sender : '')));
        body.appendChild(pills);

        if (it.reason) {
          var why = document.createElement('div'); why.className = 'why';
          why.textContent = '为什么是待办：' + it.reason;
          body.appendChild(why);
        }
        if (it.evidence) {
          var det = document.createElement('details');
          var sum = document.createElement('summary'); sum.textContent = '原文（evidence）';
          det.appendChild(sum);
          var ev = document.createElement('div'); ev.className = 'ev'; ev.textContent = it.evidence;
          det.appendChild(ev);
          body.appendChild(det);
        }
        if (it.ignoredNote) {
          var nt = document.createElement('div'); nt.className = 'meta'; nt.textContent = '备注：' + it.ignoredNote;
          body.appendChild(nt);
        }
        div.appendChild(body);

        var acts = document.createElement('div'); acts.className = 'acts';
        var bIgn = document.createElement('button'); bIgn.textContent = '忽略';
        bIgn.addEventListener('click', function () { pending[it.id] = 'ignored'; syncBar(); render(); });
        var bRe = document.createElement('button'); bRe.textContent = '重新打开';
        bRe.addEventListener('click', function () {
          if (String(it.status) === 'open') delete pending[it.id]; else pending[it.id] = 'open';
          syncBar(); render();
        });
        acts.appendChild(bIgn); acts.appendChild(bRe);
        div.appendChild(acts);

        app.appendChild(div);
      });
    });
    if (!shown) {
      var e = document.createElement('div'); e.className = 'empty'; e.textContent = '没有待办。';
      app.appendChild(e);
    }
  }

  function syncBar() {
    var ids = Object.keys(pending);
    var bar = document.getElementById('bar');
    if (!ids.length) { bar.className = 'bar hidden'; return; }
    bar.className = 'bar';
    var map = { done: '完成', ignored: '忽略', open: '重新打开' };
    document.getElementById('barText').textContent = '有 ' + ids.length + ' 处改动待导出（' +
      ids.slice(0, 4).map(function (id) { return map[pending[id]] || pending[id]; }).join('、') +
      (ids.length > 4 ? ' …' : '') + '）';
  }

  document.getElementById('reset').addEventListener('click', function () { pending = {}; syncBar(); render(); });
  document.getElementById('export').addEventListener('click', function () {
    var changes = Object.keys(pending).map(function (id) { return { id: id, status: pending[id] }; });
    var patch = { kind: 'todo-board-changes', version: 1, exportedAt: new Date().toISOString(), changes: changes };
    var blob = new Blob([JSON.stringify(patch, null, 2)], { type: 'application/json' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = '看板改动-' + new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-') + '.json';
    document.body.appendChild(a); a.click(); document.body.removeChild(a);
    setTimeout(function () { URL.revokeObjectURL(a.href); }, 2000);
  });

  render();
  syncBar();
})();
</script>
</body>
</html>
`

// 数据以 base64(UTF-8) 内嵌：避免中文在 file:// + 各种默认编码下变乱码
const payload = { generatedAt: nowIso(), items }
const b64 = Buffer.from(JSON.stringify(payload), 'utf8').toString('base64')
writeFileSync(boardPath, html.replace('__DATA__', b64), 'utf8')

let memoNote = '（--noMemo：没动 MEMO.md）'
if (!NO_MEMO) {
  writeFileSync(memoPath, renderMemoLikePlugin(items), 'utf8')
  memoNote = 'MEMO.md 已按插件格式重建'
}
const open = items.filter((x) => !['done', 'ignored', 'expired'].includes(String(x.status))).length
console.log(`看板已生成：${boardPath}`)
console.log(`  待办 ${items.length} 条（未完成 ${open} 条）· ${memoNote}`)
console.log('  双击打开 看板.html → 勾选后点「导出改动」→ 再用 生成看板.ps1 -Apply "<文件>" 写回')
