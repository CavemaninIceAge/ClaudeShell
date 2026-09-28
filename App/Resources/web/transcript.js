/* 对话正文渲染。Swift 侧调用 CS.upsert / CS.remove / CS.setWorking；
   这里只负责把条目画成 DOM，Markdown 交给 marked，代码交给 highlight.js。 */
(function () {
  'use strict';

  const list = document.getElementById('list');
  const workingEl = document.getElementById('working');
  const workingText = document.getElementById('working-text');
  const reactions = new Map();
  const savedResponses = new Set();
  const nodes = new Map();       // item id → article
  const blockCache = new Map();  // block id / group id → { key, el, live }
  const HOME = window.CS_HOME || '';
  let stick = true;
  let activeEffort = '';   // 当前生效的思考强度（xhigh 等），流式思考行上显示，和终端「thinking with xhigh effort」一致
  let lastItem = null;

  const ICON_NAMES = ['terminal', 'file', 'pencil', 'search', 'globe', 'agent', 'wrench', 'sparkle', 'steps', 'chevron', 'folder', 'photo'];
  const icon = (name) => '<span class="icon icon-' + (ICON_NAMES.includes(name) ? name : 'wrench') + '"></span>';


  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }

  marked.use({
    gfm: true,
    breaks: false,
    renderer: {
      // 模型输出里的裸 HTML 一律当文本，不给它执行的机会。
      html({ text }) { return escapeHtml(text); },
    },
  });

  function md(text) {
    try { return marked.parse(text || ''); } catch (e) { return '<pre>' + escapeHtml(text) + '</pre>'; }
  }

  function decorateCode(root, done) {
    // Keep the native Codex table geometry while allowing wide content to scroll.
    root.querySelectorAll('table').forEach((table) => {
      if (table.parentElement.classList.contains('table-scroll')) return;
      const scroller = document.createElement('div');
      scroller.className = 'table-scroll';
      table.replaceWith(scroller);
      scroller.appendChild(table);
    });
    root.querySelectorAll('pre').forEach((pre) => {
      if (pre.closest('.codeblock')) return;
      const code = pre.querySelector('code');
      const lang = code && [...code.classList].map((c) => c.replace(/^language-/, '')).find((c) => c && !c.startsWith('hljs'));
      const wrap = document.createElement('div');
      wrap.className = 'codeblock';
      const head = document.createElement('div');
      head.className = 'codeblock-head';
      head.innerHTML = '<span>' + escapeHtml(lang || '代码') + '</span><button type="button" data-copy aria-label="复制代码" title="复制代码"><span class="copy-symbol" aria-hidden="true"></span></button>';
      pre.replaceWith(wrap);
      wrap.appendChild(head);
      wrap.appendChild(pre);
      if (code && done && code.textContent.length < 60000) {
        try { hljs.highlightElement(code); } catch (e) { /* 不认识的语言就素着 */ }
      }
    });
  }

  function shortPath(p) {
    if (!p) return '';
    if (HOME && p.startsWith(HOME + '/')) return '~' + p.slice(HOME.length);
    if (HOME && p === HOME) return '~';
    return p;
  }

  function summarize(t) {
    const i = t.input || {};
    const partial = t.partialInput || '';
    const firstString = () => { for (const k of Object.keys(i)) { if (typeof i[k] === 'string' && i[k]) return i[k]; } return ''; };
    switch (t.name) {
      case 'Bash': return { icon: 'terminal', label: i.description || '运行', code: i.command || partial.slice(0, 120) };
      case 'Read': return { icon: 'file', label: '读取', code: shortPath(i.file_path) || partial.slice(0, 120) };
      case 'Edit': case 'MultiEdit': case 'NotebookEdit': return { icon: 'pencil', label: '编辑', code: shortPath(i.file_path || i.notebook_path) || partial.slice(0, 120) };
      case 'Write': return { icon: 'pencil', label: '写入', code: shortPath(i.file_path) || partial.slice(0, 120) };
      case 'Grep': return { icon: 'search', label: '搜索', code: (i.pattern || '') + (i.path ? '  ' + shortPath(i.path) : '') };
      case 'Glob': return { icon: 'search', label: '查找文件', code: (i.pattern || '') + (i.path ? '  ' + shortPath(i.path) : '') };
      case 'WebFetch': return { icon: 'globe', label: '访问', code: i.url || '' };
      case 'WebSearch': return { icon: 'globe', label: '搜索网页', code: i.query || '' };
      case 'Task': case 'Agent': return { icon: 'agent', label: '子代理', code: i.description || i.prompt || '' };
      case 'Skill': return { icon: 'sparkle', label: '技能', code: i.skill || '' };
      case 'TodoWrite': return { icon: 'steps', label: '更新待办', code: '' };
      case 'AskUserQuestion': return { icon: 'wrench', label: '提问', code: '' };
      default: return { icon: 'wrench', label: t.name, code: firstString().slice(0, 160) };
    }
  }

  function pre(text, cls) {
    const el = document.createElement('pre');
    if (cls) el.className = cls;
    el.textContent = text;
    return el;
  }

  function label(text) {
    const el = document.createElement('div');
    el.className = 'label';
    el.textContent = text;
    return el;
  }

  function truncate(s, n) { return s && s.length > n ? s.slice(0, n) + '\n…' : (s || ''); }

  function renderToolInput(t) {
    const frag = document.createDocumentFragment();
    const i = t.input;
    if (!i) {
      if (t.partialInput) frag.appendChild(pre(truncate(t.partialInput, 2000)));
      return frag;
    }
    switch (t.name) {
      case 'Bash':
        frag.appendChild(pre(i.command || ''));
        break;
      case 'Edit':
        frag.appendChild(label('原文'));
        frag.appendChild(pre(truncate(i.old_string || '', 4000), 'old'));
        frag.appendChild(label('改为'));
        frag.appendChild(pre(truncate(i.new_string || '', 4000), 'new'));
        break;
      case 'Write':
        frag.appendChild(pre(truncate(i.content || '', 4000), 'new'));
        break;
      case 'Read':
      case 'Grep':
      case 'Glob':
      case 'WebFetch':
      case 'WebSearch':
        break;
      default:
        frag.appendChild(pre(truncate(JSON.stringify(i, null, 2), 4000)));
    }
    return frag;
  }

  function renderTool(t) {
    const info = summarize(t);
    const row = document.createElement('details');
    row.className = 'step' + (t.isError ? ' error' : '') + (t.done ? '' : ' running');
    const s = document.createElement('summary');
    s.innerHTML =
      '<span class="step-icon">' + icon(info.icon) + '</span>' +
      '<span class="step-label">' + escapeHtml(info.label) + '</span>' +
      (info.code ? '<code class="step-code">' + escapeHtml(info.code) + '</code>' : '') +
      (t.done ? '' : '<span class="spinner"></span>');
    row.appendChild(s);
    const body = document.createElement('div');
    body.className = 'step-body';
    body.appendChild(renderToolInput(t));
    if (t.result != null) {
      body.appendChild(pre(t.result === '' ? '（无输出）' : t.result, 'step-result'));
    }
    row.appendChild(body);
    return row;
  }

  // "已完成 3 步 · 12 秒"：从第一步开始到最后一步拿到结果。
  function groupDuration(run) {
    let t0 = Infinity, t1 = -Infinity;
    run.forEach((b) => {
      const t = b.tool;
      if (t.startedAt) t0 = Math.min(t0, Date.parse(t.startedAt));
      if (t.endedAt) t1 = Math.max(t1, Date.parse(t.endedAt));
    });
    if (!isFinite(t0) || !isFinite(t1) || t1 < t0) return '';
    const sec = Math.round((t1 - t0) / 1000);
    if (sec < 1) return '';
    if (sec < 60) return ' · ' + sec + ' 秒';
    const m = Math.floor(sec / 60), r = sec % 60;
    return ' · ' + m + ' 分' + (r ? ' ' + r + ' 秒' : '');
  }

  function renderToolGroup(run, live) {
    const gid = 'g:' + run[0].id;
    const key = run.map((b) => {
      const t = b.tool;
      return b.id + ':' + (t.done ? 1 : 0) + ':' + (t.result ? t.result.length : 0) + ':' + (t.input ? 1 : 0) + ':' + (t.partialInput || '').length + ':' + (t.isError ? 1 : 0);
    }).join('|') + '|' + live;
    const cached = blockCache.get(gid);
    if (cached && cached.key === key) return cached.el;

    const d = document.createElement('details');
    d.className = 'steps';
    const running = run.some((b) => !b.tool.done);
    // 进行中默认展开；一收尾就折起来（Codex 的做法）；之后用户自己开过就记住。
    d.open = running ? true : (cached && !cached.live ? cached.el.open : false);
    const s = document.createElement('summary');
    const n = run.length;
    const dur = running ? '' : groupDuration(run);
    s.innerHTML = icon('steps') +
      '<span class="' + (running ? 'live-text' : '') + '">' + (running ? '正在工作 · ' + n + ' 步' : '已完成 ' + n + ' 步' + dur) + '</span>' +
      '<span class="chev">' + icon('chevron') + '</span>';
    d.appendChild(s);
    const ul = document.createElement('div');
    ul.className = 'step-list';
    run.forEach((b) => ul.appendChild(renderTool(b.tool)));
    d.appendChild(ul);
    blockCache.set(gid, { key, el: d, live: running });
    return d;
  }

  function renderThinking(b) {
    const d = document.createElement('details');
    d.className = 'thinking';
    d.open = !b.done;
    const s = document.createElement('summary');
    // 还没有任何思考文字时不给箭头：没有可展开的东西。
    const label = b.done ? '思考过程' : ('正在思考' + (activeEffort ? '' : '…'));
    const effortTag = (!b.done && activeEffort) ? '<span class="effort-tag">' + activeEffort + '</span>' : '';
    s.innerHTML = icon('sparkle') +
      '<span class="' + (b.done ? '' : 'live-text') + '">' + label + '</span>' + effortTag +
      (b.text ? '<span class="chev">' + icon('chevron') + '</span>' : '');
    d.appendChild(s);
    const body = document.createElement('div');
    body.className = 'thinking-body';
    body.innerHTML = md(b.text);
    d.appendChild(body);
    return d;
  }

  function renderBlock(b) {
    const key = b.kind + ':' + (b.done ? 1 : 0) + ':' + b.text.length + (b.kind === 'thinking' && !b.done ? ':' + activeEffort : '');
    const cached = blockCache.get(b.id);
    if (cached && cached.key === key) return cached.el;
    let el;
    if (b.kind === 'thinking') {
      el = renderThinking(b);
      if (cached && cached.el.tagName === 'DETAILS' && b.done) el.open = cached.el.open;
    } else {
      el = document.createElement('div');
      el.className = 'text';
      el.innerHTML = md(b.text);
      decorateCode(el, b.done);
    }
    blockCache.set(b.id, { key, el, live: !b.done });
    return el;
  }

  function renderAssistant(el, item) {
    let blocks = item.blocks || [];
    if (item.done && blocks.some(b => b.kind === 'tool' || b.kind === 'thinking')) {
      const activity = document.createElement('details');
      activity.className = 'turn-activity';
      const summary = document.createElement('summary');
      const milliseconds = item.meta && item.meta.durationMs;
      const duration = milliseconds ? (milliseconds >= 60000 ? Math.floor(milliseconds / 60000) + 'm ' + Math.floor(milliseconds % 60000 / 1000) + 's' : Math.max(1, Math.round(milliseconds / 1000)) + 's') : '';
      summary.innerHTML = '<span>' + (duration ? 'Worked for ' + duration : 'View work') + '</span><span class="chev">' + icon('chevron') + '</span>';
      const body = document.createElement('div'); body.className = 'turn-activity-body';
      const tools = blocks.filter(b => b.kind === 'tool');
      if (tools.length) body.appendChild(renderToolGroup(tools, false));
      for (const thinking of blocks.filter(b => b.kind === 'thinking' && b.text.trim())) body.appendChild(renderBlock(thinking));
      activity.append(summary, body); el.appendChild(activity);
      blocks = blocks.filter(b => b.kind === 'text');
    }
    let i = 0;
    while (i < blocks.length) {
      const b = blocks[i];
      if (b.kind === 'tool') {
        const run = [];
        let j = i;
        while (j < blocks.length && blocks[j].kind === 'tool') run.push(blocks[j++]);
        el.appendChild(renderToolGroup(run, j === blocks.length && !item.done));
        i = j;
        continue;
      }
      if (b.kind === 'thinking' && b.done && !b.text.trim()) { i++; continue; }
      if (b.kind === 'text' && !b.text) { i++; continue; }
      el.appendChild(renderBlock(b));
      i++;
    }
  }

  function render(item) {
    const el = document.createElement('article');
    el.className = 'item ' + item.kind;
    el.dataset.id = item.id;
    if (item.kind === 'user') {
      const wrap = document.createElement('div');
      wrap.className = 'user-wrap';
      const atts = item.attachments || [];
      if (atts.length) wrap.appendChild(renderAttachments(atts));
      if (item.text) {
        const b = document.createElement('div');
        b.className = 'bubble';
        b.textContent = item.text;
        wrap.appendChild(b);
      }
      el.appendChild(wrap);
    } else if (item.kind === 'note') {
      el.classList.add('level-' + (item.level || 'info'));
      if (item.level === 'recap') {
        const tag = document.createElement('span');
        tag.className = 'recap-tag';
        tag.textContent = 'recap';
        const body = document.createElement('span');
        body.className = 'recap-body';
        body.textContent = item.text;
        el.appendChild(tag);
        el.appendChild(body);
      } else {
        el.textContent = item.text;
      }
    } else {
      renderAssistant(el, item);
      if (item.done && (item.blocks || []).some(b => b.kind === 'text' && b.text)) {
        const actions = document.createElement('div'); actions.className = 'response-actions';
        const icons = {
          copy: '<rect x="6" y="6" width="11" height="12" rx="2"/><path d="M13 6V4a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h2"/>',
          like: '<path d="M6 9l4-7c3 0 2 4 1 6h5a2 2 0 0 1 2 2l-2 7H6zM2 9h4v8H2z"/>',
          focus: '<path d="M12 2h6v6M18 2l-7 7M8 18H2v-6M2 18l7-7"/>',
          save: '<path d="M10 2v11m-4-4 4 4 4-4M3 13v5h14v-5"/>'
        };
        for (const [action, title] of [['copy','复制回答'],['like','赞（仅本机记录）'],['focus','聚焦这条回答'],['save','保存回答到资料库']]) {
          const button = document.createElement('button'); button.type = 'button'; button.dataset.responseAction = action;
          button.title = title; button.setAttribute('aria-label', title);
          if (action === 'like') button.setAttribute('aria-pressed', reactions.get(item.id) === true ? 'true' : 'false');
          if (action === 'save' && savedResponses.has(item.id)) button.title = '已保存到资料库';
          button.innerHTML = '<svg viewBox="0 0 20 20" aria-hidden="true">' + icons[action] + '</svg>';
          actions.appendChild(button);
        }
        el.appendChild(actions);
      }
    }
    return el;
  }

  // 用户消息上挂的附件：图片缩略图、文件 / 目录小片。有路径的点开走 Finder 默认程序。
  function renderAttachments(atts) {
    const row = document.createElement('div');
    row.className = 'attachments';
    for (const a of atts) {
      let node;
      if (a.kind === 'image' && a.preview) {
        node = document.createElement('img');
        node.className = 'att-image';
        node.src = a.preview;
        node.alt = a.name || '';
      } else {
        node = document.createElement('span');
        node.className = 'att-file';
        node.innerHTML = icon(a.kind === 'directory' ? 'folder' : (a.kind === 'image' ? 'photo' : 'file'))
          + '<span class="att-name">' + escapeHtml(a.name || '') + '</span>';
      }
      node.title = a.path ? shortPath(a.path) : (a.name || '');
      if (a.path) {
        node.dataset.path = a.path;
        node.classList.add('openable');
      }
      row.appendChild(node);
    }
    return row;
  }

  function maybeScroll() {
    if (!stick) return;
    requestAnimationFrame(() => window.scrollTo(0, document.documentElement.scrollHeight));
  }

  window.addEventListener('scroll', () => {
    const gap = document.documentElement.scrollHeight - (window.innerHeight + window.scrollY);
    stick = gap < 80;
  }, { passive: true });

  document.addEventListener('click', (e) => {
    const a = e.target.closest('a[href]');
    if (a) {
      e.preventDefault();
      post({ type: 'open', url: a.getAttribute('href') || a.href });
      return;
    }
    const att = e.target.closest('.openable[data-path]');
    if (att) {
      post({ type: 'open', path: att.dataset.path });
      return;
    }
    const responseAction = e.target.closest('button[data-response-action]');
    if (responseAction) {
      const article = responseAction.closest('article');
      const id = article.dataset.id;
      const action = responseAction.dataset.responseAction;
      if (action === 'copy') {
        post({type: 'copy_response', id}); responseAction.title = '已复制';
        setTimeout(() => { responseAction.title = '复制回答'; }, 1200);
      } else if (action === 'like') {
        const liked = !(reactions.get(id) === true); reactions.set(id, liked);
        responseAction.setAttribute('aria-pressed', liked ? 'true' : 'false');
        post({type: 'response_feedback', id, liked});
      } else if (action === 'focus') {
        const focused = !article.classList.contains('focused-response');
        document.querySelectorAll('.focused-response').forEach(node => node.classList.remove('focused-response'));
        article.classList.toggle('focused-response', focused); document.body.classList.toggle('response-focused', focused);
        responseAction.title = focused ? '返回完整对话' : '聚焦这条回答';
        responseAction.setAttribute('aria-label', responseAction.title);
      } else if (action === 'save') post({type: 'save_response', id});
      return;
    }
    const btn = e.target.closest('button[data-copy]');
    if (btn) {
      const code = btn.closest('.codeblock').querySelector('pre');
      post({ type: 'copy', text: code ? code.textContent : '' });
      btn.classList.add('copied');
      btn.setAttribute('aria-label', '已复制');
      btn.title = '已复制';
      setTimeout(() => {
        btn.classList.remove('copied');
        btn.setAttribute('aria-label', '复制代码');
        btn.title = '复制代码';
      }, 1200);
    }
  });

  window.CSResponseActions = {
    setFeedback(id, liked) { reactions.set(id, liked); const article = nodes.get(id); if (article) article.querySelector('[data-response-action="like"]')?.setAttribute('aria-pressed', liked ? 'true' : 'false'); },
    saved(id) { savedResponses.add(id); const article = nodes.get(id); if (article) { const button = article.querySelector('[data-response-action="save"]'); if (button) { button.title = '已保存到资料库'; button.setAttribute('aria-label', button.title); } } }
  };

  function post(msg) {
    try { window.webkit.messageHandlers.bridge.postMessage(msg); } catch (e) { /* 浏览器里预览时没有桥 */ }
  }

  function updateWorking(flag, text) {
    let show = flag;
    if (flag && lastItem && lastItem.kind === 'assistant') {
      // 只要正文里已经有一个在动的块（思考行在闪、步骤行在转、文字在流），这条脉冲行就是第二个指示器，不显示。
      const blocks = lastItem.blocks || [];
      const live = blocks.some((b) => !b.done || (b.kind === 'tool' && b.tool && !b.tool.done));
      if (live) show = false;
    }
    workingEl.hidden = !show;
    workingText.textContent = text || '正在思考…';
    if (show) maybeScroll();
  }

  window.CS = {
    upsert(item, index) {
      const el = render(item);
      const old = nodes.get(item.id);
      if (old) {
        old.replaceWith(el);
      } else {
        const ref = list.children[index];
        if (ref) list.insertBefore(el, ref); else list.appendChild(el);
      }
      nodes.set(item.id, el);
      if (list.lastElementChild === el) lastItem = item;
      maybeScroll();
    },
    remove(id) {
      const el = nodes.get(id);
      if (el) el.remove();
      nodes.delete(id);
    },
    setEffort(effort) { activeEffort = effort || ''; },
    setWorking(flag, text) { updateWorking(flag, text); },
    clear() { list.innerHTML = ''; nodes.clear(); blockCache.clear(); lastItem = null; },
  };

  // 脚本里抛了异常 Swift 侧才看得见（-testLog 启动时写进日志）。
  window.addEventListener('error', (e) => post({ type: 'log', text: 'error: ' + e.message + ' @' + e.lineno }));
  post({ type: 'ready' });
})();
