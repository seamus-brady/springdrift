//// Embedded HTML/CSS/JS for the web chat GUI.

pub fn page() -> String {
  "<!DOCTYPE html>
<html lang=\"en\">
<head>
<meta charset=\"UTF-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
<title>Springdrift</title>
<script src=\"https://cdn.jsdelivr.net/npm/marked/marked.min.js\"></script>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  :root {
    --bg: #f7f7f8;
    --surface: #ffffff;
    --sidebar-bg: #f0efe9;
    --sidebar-border: #e3e2dc;
    --border: #e5e5e5;
    --border-hover: #d0d0d0;
    --text: #2d2d2d;
    --text-dim: #8e8e93;
    --text-secondary: #6e6e73;
    --accent: #da7e37;
    --accent-light: #f5e6d6;
    --user-bg: #ece4d9;
    --assistant-bg: #ffffff;
    --input-bg: #ffffff;
    --input-border: #d9d9d9;
    --input-focus: #da7e37;
    --code-bg: #f4f3ee;
    --code-border: #e3e2dc;
    --radius: 20px;
    --radius-sm: 12px;
  }
  body {
    font-family: 'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, 'Book Antiqua', serif;
    background: var(--bg);
    color: var(--text);
    height: 100vh;
    display: flex;
    font-size: 17px;
  }

  /* ── Sidebar ─────────────────────────────────────── */
  #sidebar {
    width: 30%;
    min-width: 220px;
    max-width: 340px;
    background: var(--sidebar-bg);
    border-right: 1px solid var(--sidebar-border);
    display: flex;
    flex-direction: column;
    padding: 20px 16px;
  }
  #sidebar h1 {
    font-size: 18px;
    font-weight: 600;
    color: var(--text);
    letter-spacing: -0.2px;
    margin-bottom: 20px;
  }
  #sidebar .sidebar-status {
    margin-top: auto;
    font-size: 13px;
    color: var(--text-dim);
  }
  #sidebar .sidebar-status .dot {
    display: inline-block;
    width: 7px;
    height: 7px;
    border-radius: 50%;
    margin-right: 6px;
    vertical-align: middle;
    background: var(--text-dim);
  }
  #sidebar .sidebar-status .dot.connected { background: #34c759; }
  #sidebar .sidebar-status .dot.disconnected { background: #ff3b30; }

  /* ── Main area ───────────────────────────────────── */
  #main {
    flex: 1;
    display: flex;
    flex-direction: column;
    min-width: 0;
    position: relative;
  }

  /* ── Tab bar ──────────────────────────────────────── */
  #tab-bar {
    display: flex;
    gap: 0;
    border-bottom: 1px solid var(--border);
    background: var(--surface);
    padding: 0 24px;
  }
  .tab-btn {
    padding: 10px 20px;
    border: none;
    background: none;
    font-family: inherit;
    font-size: 15px;
    color: var(--text-dim);
    cursor: pointer;
    border-bottom: 2px solid transparent;
    transition: color 0.15s, border-color 0.15s;
  }
  .tab-btn:hover { color: var(--text); }
  .tab-btn.active {
    color: var(--accent);
    border-bottom-color: var(--accent);
    font-weight: 600;
  }

  /* ── Tab content ─────────────────────────────────── */
  .tab-content { display: none; flex: 1; flex-direction: column; min-height: 0; }
  .tab-content.active { display: flex; }

  /* ── Hidden scrollbar ────────────────────────────── */
  #messages {
    scrollbar-width: none;
    -ms-overflow-style: none;
  }
  #messages::-webkit-scrollbar { display: none; }

  /* ── Messages ────────────────────────────────────── */
  #messages {
    flex: 1;
    overflow-y: auto;
    padding: 32px 24px 16px;
    display: flex;
    flex-direction: column;
    gap: 16px;
    max-width: 720px;
    width: 100%;
    margin: 0 auto;
  }
  .msg {
    padding: 14px 18px;
    border-radius: var(--radius);
    max-width: 80%;
    line-height: 1.6;
    word-wrap: break-word;
    font-size: 17px;
  }
  .msg.user {
    background: var(--user-bg);
    color: var(--text);
    align-self: flex-end;
    border-bottom-right-radius: 6px;
    white-space: pre-wrap;
  }
  .msg.assistant {
    background: var(--assistant-bg);
    border: 1px solid var(--border);
    align-self: flex-start;
    border-bottom-left-radius: 6px;
    box-shadow: 0 1px 3px rgba(0,0,0,0.04);
  }

  /* ── Markdown inside assistant messages ──────────── */
  .msg.assistant p { margin: 0 0 0.7em; }
  .msg.assistant p:last-child { margin-bottom: 0; }
  .msg.assistant h1, .msg.assistant h2, .msg.assistant h3,
  .msg.assistant h4, .msg.assistant h5, .msg.assistant h6 {
    font-family: inherit;
    margin: 1em 0 0.4em;
    line-height: 1.3;
  }
  .msg.assistant h1:first-child, .msg.assistant h2:first-child,
  .msg.assistant h3:first-child { margin-top: 0; }
  .msg.assistant h1 { font-size: 1.3em; }
  .msg.assistant h2 { font-size: 1.15em; }
  .msg.assistant h3 { font-size: 1.05em; }
  .msg.assistant ul, .msg.assistant ol {
    margin: 0.4em 0 0.7em 1.4em;
  }
  .msg.assistant li { margin-bottom: 0.25em; }
  .msg.assistant blockquote {
    border-left: 3px solid var(--accent);
    padding: 0.3em 0 0.3em 1em;
    margin: 0.5em 0;
    color: var(--text-secondary);
  }
  .msg.assistant code {
    font-family: 'SF Mono', 'Menlo', 'Consolas', monospace;
    font-size: 0.88em;
    background: var(--code-bg);
    border: 1px solid var(--code-border);
    border-radius: 5px;
    padding: 2px 6px;
  }
  .msg.assistant pre {
    background: var(--code-bg);
    border: 1px solid var(--code-border);
    border-radius: 10px;
    padding: 14px 16px;
    margin: 0.5em 0;
    overflow-x: auto;
    scrollbar-width: none;
    -ms-overflow-style: none;
  }
  .msg.assistant pre::-webkit-scrollbar { display: none; }
  .msg.assistant pre code {
    background: none;
    border: none;
    border-radius: 0;
    padding: 0;
    font-size: 0.85em;
    line-height: 1.5;
  }
  .msg.assistant table {
    border-collapse: collapse;
    margin: 0.5em 0;
    font-size: 0.95em;
  }
  .msg.assistant th, .msg.assistant td {
    border: 1px solid var(--border);
    padding: 6px 12px;
    text-align: left;
  }
  .msg.assistant th {
    background: var(--code-bg);
    font-weight: 600;
  }
  .msg.assistant hr {
    border: none;
    border-top: 1px solid var(--border);
    margin: 1em 0;
  }
  .msg.assistant a {
    color: var(--accent);
    text-decoration: none;
  }
  .msg.assistant a:hover { text-decoration: underline; }
  .msg.assistant strong { font-weight: 700; }
  .msg.assistant em { font-style: italic; }

  .msg .meta {
    font-size: 13px;
    color: var(--text-dim);
    margin-top: 8px;
  }
  .notification {
    font-size: 14px;
    color: var(--text-dim);
    padding: 4px 18px;
    align-self: flex-start;
    font-style: italic;
  }
  .thinking {
    align-self: flex-start;
    padding: 14px 18px;
    color: var(--text-dim);
    font-size: 17px;
  }
  .thinking .dots span {
    animation: blink 1.4s infinite both;
  }
  .thinking .dots span:nth-child(2) { animation-delay: 0.2s; }
  .thinking .dots span:nth-child(3) { animation-delay: 0.4s; }
  @keyframes blink {
    0%, 80%, 100% { opacity: 0.2; }
    40% { opacity: 1; }
  }
  .question-prompt {
    background: var(--accent-light);
    border: 1px solid var(--accent);
    border-radius: var(--radius);
    padding: 16px 18px;
    align-self: flex-start;
    max-width: 80%;
  }
  .question-prompt .q-source {
    font-size: 13px;
    font-weight: 600;
    color: var(--accent);
    margin-bottom: 6px;
  }
  .question-prompt .q-text {
    font-size: 17px;
    margin-bottom: 12px;
  }
  .question-prompt input {
    width: 100%;
    padding: 10px 14px;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 10px;
    color: var(--text);
    font-size: 16px;
    font-family: inherit;
    outline: none;
    transition: border-color 0.15s;
  }
  .question-prompt input:focus {
    border-color: var(--accent);
  }

  /* ── Input area ──────────────────────────────────── */
  #input-area {
    padding: 0 24px 28px;
    max-width: 720px;
    width: 100%;
    margin: 0 auto;
  }
  #input-area form {
    display: flex;
    align-items: center;
    gap: 10px;
    background: var(--input-bg);
    border: 1px solid var(--input-border);
    border-radius: var(--radius);
    padding: 6px 6px 6px 18px;
    transition: border-color 0.15s, box-shadow 0.15s;
    box-shadow: 0 1px 4px rgba(0,0,0,0.04);
  }
  #input-area form:focus-within {
    border-color: var(--input-focus);
    box-shadow: 0 0 0 3px rgba(218,126,55,0.12);
  }
  #input-area input {
    flex: 1;
    padding: 10px 0;
    background: transparent;
    border: none;
    color: var(--text);
    font-size: 16px;
    font-family: inherit;
    outline: none;
  }
  #input-area input::placeholder { color: var(--text-dim); }
  #input-area button {
    width: 36px;
    height: 36px;
    background: var(--accent);
    color: #fff;
    border: none;
    border-radius: 50%;
    cursor: pointer;
    font-size: 16px;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: background 0.15s;
    flex-shrink: 0;
  }
  #input-area button:hover { background: #c46f2e; }
  #input-area button:disabled { opacity: 0.35; cursor: not-allowed; }
  #input-area button svg { width: 18px; height: 18px; }
  #input-hint {
    text-align: center;
    font-size: 13px;
    color: var(--text-dim);
    margin-top: 8px;
  }

  /* ── Tab bar ──────────────────────────────────────── */
  #tab-bar {
    display: flex;
    gap: 0;
    border-bottom: 1px solid var(--border);
    padding: 0 24px;
    background: var(--surface);
  }
  .tab-btn {
    padding: 10px 20px;
    border: none;
    background: none;
    color: var(--text-dim);
    font-family: inherit;
    font-size: 15px;
    font-weight: 600;
    cursor: pointer;
    border-bottom: 2px solid transparent;
    transition: color 0.15s, border-color 0.15s;
  }
  .tab-btn:hover { color: var(--text); }
  .tab-btn.active {
    color: var(--accent);
    border-bottom-color: var(--accent);
  }
  .tab-content { display: none; flex: 1; flex-direction: column; min-height: 0; }
  .tab-content.active { display: flex; }

  /* ── Narrative tab ───────────────────────────────── */
  #narrative-container {
    flex: 1;
    overflow-y: auto;
    padding: 16px 24px;
    max-width: 720px;
    width: 100%;
    margin: 0 auto;
    scrollbar-width: none;
    -ms-overflow-style: none;
  }
  #narrative-container::-webkit-scrollbar { display: none; }
  .narrative-entry {
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    padding: 16px 18px;
    margin-bottom: 12px;
    background: var(--surface);
    box-shadow: 0 1px 3px rgba(0,0,0,0.04);
  }
  .narrative-header {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 8px;
    flex-wrap: wrap;
  }
  .narrative-cycle {
    font-family: 'SF Mono', 'Menlo', 'Consolas', monospace;
    font-size: 12px;
    color: #007aff;
    background: rgba(0,122,255,0.08);
    padding: 2px 7px;
    border-radius: 5px;
  }
  .narrative-time {
    font-size: 13px;
    color: var(--text-dim);
  }
  .narrative-status {
    font-size: 12px;
    font-weight: 600;
    padding: 2px 8px;
    border-radius: 5px;
  }
  .narrative-status.success { background: rgba(52,199,89,0.12); color: #248a3d; }
  .narrative-status.partial { background: rgba(255,149,0,0.12); color: #c77c00; }
  .narrative-status.failure { background: rgba(255,59,48,0.12); color: #d70015; }
  .narrative-thread {
    font-size: 13px;
    color: var(--text-secondary);
    padding: 2px 8px;
    background: var(--code-bg);
    border-radius: 5px;
  }
  .narrative-summary {
    font-size: 16px;
    line-height: 1.5;
    margin-bottom: 8px;
  }
  .narrative-keywords {
    display: flex;
    gap: 6px;
    flex-wrap: wrap;
    margin-bottom: 8px;
  }
  .narrative-keyword {
    font-size: 12px;
    color: var(--accent);
    background: var(--accent-light);
    padding: 2px 8px;
    border-radius: 5px;
  }
  .narrative-delegation {
    font-size: 13px;
    color: var(--text-secondary);
    border-top: 1px solid var(--border);
    padding-top: 8px;
    margin-top: 4px;
  }
  .narrative-delegation .agent-name {
    font-weight: 600;
    color: var(--text);
  }
  .narrative-empty {
    text-align: center;
    color: var(--text-dim);
    padding: 40px 20px;
    font-size: 15px;
  }
  #narrative-refresh {
    padding: 6px 14px;
    margin: 12px 24px;
    border: 1px solid var(--border);
    border-radius: 8px;
    background: var(--surface);
    font-family: inherit;
    font-size: 13px;
    color: var(--text-secondary);
    cursor: pointer;
  }
  #narrative-refresh:hover { background: var(--code-bg); }

  /* ── Thinking overlay ──────────────────────────── */
  #thinking-overlay {
    display: none;
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    z-index: 10;
  }
  #thinking-overlay.active { display: block; }
  .tab-btn.disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  /* ── Log tab ──────────────────────────────────────── */
  #log-container {
    flex: 1;
    overflow-y: auto;
    padding: 16px 24px;
    font-family: 'SF Mono', 'Menlo', 'Consolas', monospace;
    font-size: 13px;
    scrollbar-width: none;
    -ms-overflow-style: none;
  }
  #log-container::-webkit-scrollbar { display: none; }
  .log-entry {
    padding: 3px 0;
    display: flex;
    gap: 8px;
    line-height: 1.4;
  }
  .log-time { color: var(--text-dim); white-space: nowrap; }
  .log-level { font-weight: 600; white-space: nowrap; min-width: 36px; }
  .log-level.debug { color: var(--text-dim); }
  .log-level.info { color: #007aff; }
  .log-level.warn { color: #ff9500; }
  .log-level.error { color: #ff3b30; }
  .log-mod { color: var(--text-secondary); white-space: nowrap; }
  .log-msg { color: var(--text); word-break: break-all; }
  .log-cycle { color: var(--text-dim); white-space: nowrap; }
  #log-refresh {
    padding: 6px 14px;
    margin: 12px 24px;
    border: 1px solid var(--border);
    border-radius: 8px;
    background: var(--surface);
    font-family: inherit;
    font-size: 13px;
    color: var(--text-secondary);
    cursor: pointer;
  }
  #log-refresh:hover { background: var(--code-bg); }
</style>
</head>
<body>
<div id=\"sidebar\">
  <h1>Springdrift</h1>
  <div class=\"sidebar-status\">
    <span class=\"dot\" id=\"status-dot\"></span>
    <span id=\"status\">connecting...</span>
  </div>
</div>
<div id=\"main\">
  <div id=\"tab-bar\">
    <button class=\"tab-btn active\" data-tab=\"chat\">Chat</button>
    <button class=\"tab-btn\" data-tab=\"narrative\">Narrative</button>
    <button class=\"tab-btn\" data-tab=\"log\">Log</button>
  </div>
  <div id=\"thinking-overlay\"></div>
  <div id=\"chat-tab\" class=\"tab-content active\">
    <div id=\"messages\"></div>
    <div id=\"input-area\">
      <form id=\"chat-form\">
        <input id=\"chat-input\" type=\"text\" placeholder=\"Message springdrift...\" autocomplete=\"off\" autofocus>
        <button type=\"submit\" aria-label=\"Send\"><svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><line x1=\"22\" y1=\"2\" x2=\"11\" y2=\"13\"/><polygon points=\"22 2 15 22 11 13 2 9 22 2\"/></svg></button>
      </form>
      <div id=\"input-hint\">Press Enter to send</div>
    </div>
  </div>
  <div id=\"narrative-tab\" class=\"tab-content\">
    <button id=\"narrative-refresh\">Refresh</button>
    <div id=\"narrative-container\"><div class=\"narrative-empty\">Loading narrative entries...</div></div>
  </div>
  <div id=\"log-tab\" class=\"tab-content\">
    <button id=\"log-refresh\">Refresh</button>
    <div id=\"log-container\">Loading...</div>
  </div>
</div>
<script>
(function() {
  const msgs = document.getElementById('messages');
  const form = document.getElementById('chat-form');
  const input = document.getElementById('chat-input');
  const status = document.getElementById('status');
  const statusDot = document.getElementById('status-dot');
  const logContainer = document.getElementById('log-container');
  const narrativeContainer = document.getElementById('narrative-container');
  const thinkingOverlay = document.getElementById('thinking-overlay');
  const tabBtns = document.querySelectorAll('.tab-btn');
  let ws = null;
  let thinkingEl = null;
  let questionEl = null;
  let isThinking = false;
  let reconnectDelay = 1000;

  // Configure marked for safe rendering
  marked.setOptions({
    breaks: true,
    gfm: true
  });

  function renderMarkdown(text) {
    try {
      return marked.parse(text);
    } catch(e) {
      return escapeHtml(text);
    }
  }

  // ── Tab switching ──
  tabBtns.forEach(function(btn) {
    btn.addEventListener('click', function() {
      if (isThinking) return;
      tabBtns.forEach(function(b) { b.classList.remove('active'); });
      document.querySelectorAll('.tab-content').forEach(function(c) { c.classList.remove('active'); });
      btn.classList.add('active');
      var tabId = btn.getAttribute('data-tab') + '-tab';
      document.getElementById(tabId).classList.add('active');
      if (btn.getAttribute('data-tab') === 'log') {
        requestLogData();
      } else if (btn.getAttribute('data-tab') === 'narrative') {
        requestNarrativeData();
      }
    });
  });

  document.getElementById('log-refresh').addEventListener('click', requestLogData);
  document.getElementById('narrative-refresh').addEventListener('click', requestNarrativeData);

  function requestLogData() {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'request_log_data' }));
    }
  }

  function requestNarrativeData() {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'request_narrative_data' }));
    }
  }

  function renderNarrativeEntries(entries) {
    if (!entries || entries.length === 0) {
      narrativeContainer.innerHTML = '<div class=\"narrative-empty\">No narrative entries yet. Enable narrative logging with --narrative.</div>';
      return;
    }
    var html = '';
    // Show newest first
    var sorted = entries.slice().reverse();
    sorted.forEach(function(e) {
      var cycleShort = (e.cycle_id || '').substring(0, 8);
      var time = (e.timestamp || '').substring(0, 19).replace('T', ' ');
      var status = (e.outcome && e.outcome.status) || 'unknown';
      var statusClass = status;
      var statusLabel = status.charAt(0).toUpperCase() + status.slice(1);
      var threadHtml = '';
      if (e.thread && e.thread.thread_name) {
        threadHtml = '<span class=\"narrative-thread\">' + escapeHtml(e.thread.thread_name) + ' #' + (e.thread.position || 0) + '</span>';
      }
      var keywordsHtml = '';
      if (e.keywords && e.keywords.length > 0) {
        keywordsHtml = '<div class=\"narrative-keywords\">' +
          e.keywords.map(function(k) { return '<span class=\"narrative-keyword\">' + escapeHtml(k) + '</span>'; }).join('') +
          '</div>';
      }
      var delegationHtml = '';
      if (e.delegation_chain && e.delegation_chain.length > 0) {
        var agents = e.delegation_chain.map(function(d) {
          return '<span class=\"agent-name\">' + escapeHtml(d.agent_human_name || d.agent) + '</span>';
        }).join(' → ');
        delegationHtml = '<div class=\"narrative-delegation\">Delegated to: ' + agents + '</div>';
      }
      html += '<div class=\"narrative-entry\">' +
        '<div class=\"narrative-header\">' +
          '<span class=\"narrative-cycle\">' + escapeHtml(cycleShort) + '</span>' +
          '<span class=\"narrative-time\">' + escapeHtml(time) + '</span>' +
          '<span class=\"narrative-status ' + statusClass + '\">' + statusLabel + '</span>' +
          threadHtml +
        '</div>' +
        '<div class=\"narrative-summary\">' + escapeHtml(e.summary || '') + '</div>' +
        keywordsHtml +
        delegationHtml +
        '</div>';
    });
    narrativeContainer.innerHTML = html;
  }

  function renderLogEntries(entries) {
    if (!entries || entries.length === 0) {
      logContainer.innerHTML = '<div style=\"color:var(--text-dim);padding:20px;\">No log entries today.</div>';
      return;
    }
    var html = '';
    entries.forEach(function(e) {
      var time = (e.timestamp || '').substring(11, 19);
      var lvl = e.level || 'debug';
      var badge = lvl.toUpperCase().substring(0, 3);
      var cycleHtml = e.cycle_id ? '<span class=\"log-cycle\">' + escapeHtml(e.cycle_id.substring(0, 8)) + '</span>' : '';
      html += '<div class=\"log-entry\">' +
        '<span class=\"log-time\">' + escapeHtml(time) + '</span>' +
        '<span class=\"log-level ' + lvl + '\">' + badge + '</span>' +
        '<span class=\"log-mod\">' + escapeHtml(e.module + '::' + e.function) + '</span>' +
        '<span class=\"log-msg\">' + escapeHtml(e.message) + '</span>' +
        cycleHtml +
        '</div>';
    });
    logContainer.innerHTML = html;
    logContainer.scrollTop = logContainer.scrollHeight;
  }

  function connect() {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const params = new URLSearchParams(location.search);
    const token = params.get('token');
    const tokenParam = token ? '?token=' + encodeURIComponent(token) : '';
    ws = new WebSocket(proto + '//' + location.host + '/ws' + tokenParam);

    ws.onopen = function() {
      status.textContent = 'connected';
      statusDot.className = 'dot connected';
      reconnectDelay = 1000;
    };

    ws.onclose = function() {
      status.textContent = 'reconnecting...';
      statusDot.className = 'dot disconnected';
      setTimeout(connect, reconnectDelay);
      reconnectDelay = Math.min(reconnectDelay * 2, 10000);
    };

    ws.onerror = function() {};

    ws.onmessage = function(evt) {
      let data;
      try { data = JSON.parse(evt.data); } catch(e) { return; }
      handleServerMessage(data);
    };
  }

  function handleServerMessage(data) {
    removeThinking();
    switch (data.type) {
      case 'assistant_message':
        removeQuestion();
        addAssistantMessage(data.text, data.model, data.usage);
        break;
      case 'thinking':
        showThinking();
        break;
      case 'question':
        showQuestion(data.text, data.source);
        break;
      case 'notification':
        if (data.kind === 'tool_calling') {
          addNotification('Using tool: ' + data.name);
        } else if (data.kind === 'save_warning') {
          addNotification(data.message);
        } else if (data.kind === 'safety') {
          var badge = data.decision === 'ACCEPT' ? '\\u2705' : data.decision === 'REJECT' ? '\\u274C' : '\\u26A0\\uFE0F';
          addNotification(badge + ' D\\' ' + data.decision + ' (score: ' + data.score.toFixed(2) + ')');
        }
        break;
      case 'log_data':
        renderLogEntries(data.entries);
        break;
      case 'narrative_data':
        renderNarrativeEntries(data.entries);
        break;
    }
  }

  function addUserMessage(text) {
    const el = document.createElement('div');
    el.className = 'msg user';
    el.textContent = text;
    msgs.appendChild(el);
    scrollBottom();
  }

  function addAssistantMessage(text, model, usage) {
    const el = document.createElement('div');
    el.className = 'msg assistant';
    const body = document.createElement('div');
    body.className = 'md-body';
    body.innerHTML = renderMarkdown(text);
    el.appendChild(body);
    if (model || usage) {
      const meta = document.createElement('div');
      meta.className = 'meta';
      let parts = [];
      if (model) parts.push(model);
      if (usage) parts.push(usage.input + ' in / ' + usage.output + ' out');
      meta.textContent = parts.join(' | ');
      el.appendChild(meta);
    }
    msgs.appendChild(el);
    scrollBottom();
  }

  function addNotification(text) {
    const el = document.createElement('div');
    el.className = 'notification';
    el.textContent = text;
    msgs.appendChild(el);
    scrollBottom();
  }

  function setThinkingLock(locked) {
    isThinking = locked;
    if (locked) {
      thinkingOverlay.classList.add('active');
      tabBtns.forEach(function(b) { b.classList.add('disabled'); });
    } else {
      thinkingOverlay.classList.remove('active');
      tabBtns.forEach(function(b) { b.classList.remove('disabled'); });
    }
  }

  function showThinking() {
    if (thinkingEl) return;
    thinkingEl = document.createElement('div');
    thinkingEl.className = 'thinking';
    thinkingEl.innerHTML = '<span class=\"dots\"><span>.</span><span>.</span><span>.</span></span> Thinking';
    msgs.appendChild(thinkingEl);
    scrollBottom();
    setThinkingLock(true);
  }

  function removeThinking() {
    if (thinkingEl) { thinkingEl.remove(); thinkingEl = null; }
    setThinkingLock(false);
  }

  function showQuestion(text, source) {
    removeQuestion();
    questionEl = document.createElement('div');
    questionEl.className = 'question-prompt';
    const srcLabel = source === 'cognitive' ? 'Cognitive' : source.replace('agent:', '');
    questionEl.innerHTML =
      '<div class=\"q-source\">' + escapeHtml(srcLabel) + ' asks:</div>' +
      '<div class=\"q-text\">' + escapeHtml(text) + '</div>' +
      '<input type=\"text\" placeholder=\"Type your answer...\" autofocus>';
    const qInput = questionEl.querySelector('input');
    qInput.addEventListener('keydown', function(e) {
      if (e.key === 'Enter' && qInput.value.trim()) {
        const answer = qInput.value.trim();
        ws.send(JSON.stringify({ type: 'user_answer', text: answer }));
        addUserMessage(answer);
        removeQuestion();
        input.focus();
      }
    });
    msgs.appendChild(questionEl);
    scrollBottom();
    qInput.focus();
  }

  function removeQuestion() {
    if (questionEl) { questionEl.remove(); questionEl = null; }
  }

  function scrollBottom() {
    msgs.scrollTop = msgs.scrollHeight;
  }

  function escapeHtml(s) {
    const d = document.createElement('div');
    d.textContent = s;
    return d.innerHTML;
  }

  function sendMessage() {
    const text = input.value.trim();
    if (!text || !ws || ws.readyState !== WebSocket.OPEN || isThinking) return;
    ws.send(JSON.stringify({ type: 'user_message', text: text }));
    addUserMessage(text);
    input.value = '';
  }

  input.addEventListener('keydown', function(e) {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      sendMessage();
    }
  });

  form.addEventListener('submit', function(e) {
    e.preventDefault();
    sendMessage();
  });

  connect();
})();
</script>
</body>
</html>"
}
