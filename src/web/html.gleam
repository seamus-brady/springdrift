//// Embedded HTML/CSS/JS for the web chat GUI.

import gleam/string

pub fn page(agent_name: String, agent_version: String) -> String {
  let version_display = case agent_version {
    "" -> ""
    v -> " v" <> v
  }
  let title = escape(agent_name)
  let version = escape(version_display)
  let placeholder = "Message " <> escape(string.lowercase(agent_name)) <> "..."

  "<!DOCTYPE html>
<html lang=\"en\">
<head>
<meta charset=\"UTF-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
<title>" <> title <> "</title>
<script src=\"https://cdn.jsdelivr.net/npm/marked/marked.min.js\"></script>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  :root {
    --bg: #f7f7f8;
    --surface: #ffffff;
    --header-bg: #f0efe9;
    --header-border: #e3e2dc;
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
    flex-direction: column;
    font-size: 17px;
  }

  /* ── Header ──────────────────────────────────────── */
  #header {
    background: var(--header-bg);
    border-bottom: 1px solid var(--header-border);
    padding: 16px 24px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-shrink: 0;
  }
  #header-left {
    display: flex;
    align-items: baseline;
    gap: 10px;
  }
  #header h1 {
    font-size: 20px;
    font-weight: 600;
    color: var(--text);
    letter-spacing: -0.3px;
  }
  #header .version {
    font-size: 13px;
    color: var(--text-dim);
  }
  #header-right {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 13px;
    color: var(--text-dim);
  }
  .dot {
    display: inline-block;
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--text-dim);
  }
  .dot.connected { background: #34c759; }
  .dot.disconnected { background: #ff3b30; }

  /* ── Tab bar ──────────────────────────────────────── */
  #tab-bar {
    display: flex;
    gap: 0;
    border-bottom: 1px solid var(--border);
    background: var(--surface);
    padding: 0 10%;
    flex-shrink: 0;
  }
  .tab-btn {
    padding: 10px 20px;
    border: none;
    background: none;
    font-family: inherit;
    font-size: 15px;
    font-weight: 600;
    color: var(--text-dim);
    cursor: pointer;
    border-bottom: 2px solid transparent;
    transition: color 0.15s, border-color 0.15s;
  }
  .tab-btn:hover { color: var(--text); }
  .tab-btn.active {
    color: var(--accent);
    border-bottom-color: var(--accent);
  }
  .tab-btn.chat-disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  /* ── Tab content ─────────────────────────────────── */
  #content-area {
    flex: 1;
    display: flex;
    flex-direction: column;
    min-height: 0;
    width: 80%;
    max-width: 1200px;
    margin: 0 auto;
  }
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
    padding: 32px 0 16px;
    display: flex;
    flex-direction: column;
    gap: 16px;
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
    padding: 4px 0;
    align-self: flex-start;
    font-style: italic;
  }
  .thinking {
    align-self: flex-start;
    padding: 14px 0;
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
    padding: 0 0 28px;
    flex-shrink: 0;
  }
  #input-area form {
    display: flex;
    align-items: flex-end;
    gap: 10px;
    background: var(--input-bg);
    border: 1px solid var(--input-border);
    border-radius: var(--radius);
    padding: 10px 10px 10px 18px;
    transition: border-color 0.15s, box-shadow 0.15s;
    box-shadow: 0 1px 4px rgba(0,0,0,0.04);
  }
  #input-area form:focus-within {
    border-color: var(--input-focus);
    box-shadow: 0 0 0 3px rgba(218,126,55,0.12);
  }
  #chat-input {
    flex: 1;
    padding: 6px 0;
    background: transparent;
    border: none;
    color: var(--text);
    font-size: 16px;
    font-family: inherit;
    outline: none;
    resize: none;
    line-height: 1.5;
    max-height: 200px;
    overflow-y: auto;
    scrollbar-width: none;
    -ms-overflow-style: none;
  }
  #chat-input::-webkit-scrollbar { display: none; }
  #chat-input::placeholder { color: var(--text-dim); }
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

  /* ── Thinking overlay (chat tab only) ────────────── */
  #thinking-overlay {
    display: none;
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    z-index: 10;
    background: rgba(247,247,248,0.4);
  }
  #thinking-overlay.active { display: block; }
  #chat-tab { position: relative; }

  /* ── Narrative tab ───────────────────────────────── */
  #narrative-container {
    flex: 1;
    overflow-y: auto;
    padding: 16px 0;
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
  .refresh-btn {
    padding: 6px 14px;
    margin: 12px 0;
    border: 1px solid var(--border);
    border-radius: 8px;
    background: var(--surface);
    font-family: inherit;
    font-size: 13px;
    color: var(--text-secondary);
    cursor: pointer;
  }
  .refresh-btn:hover { background: var(--code-bg); }

  /* ── Log tab ──────────────────────────────────────── */
  #log-container {
    flex: 1;
    overflow-y: auto;
    padding: 16px 0;
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
</style>
</head>
<body>
<div id=\"header\">
  <div id=\"header-left\">
    <h1>" <> title <> "</h1>
    <span class=\"version\">" <> version <> "</span>
  </div>
  <div id=\"header-right\">
    <span class=\"dot\" id=\"status-dot\"></span>
    <span id=\"status\">connecting...</span>
  </div>
</div>
<div id=\"tab-bar\">
  <button class=\"tab-btn active\" data-tab=\"chat\">Chat</button>
  <button class=\"tab-btn\" data-tab=\"narrative\">Narrative</button>
  <button class=\"tab-btn\" data-tab=\"log\">Log</button>
</div>
<div id=\"content-area\">
  <div id=\"chat-tab\" class=\"tab-content active\">
    <div id=\"thinking-overlay\"></div>
    <div id=\"messages\"></div>
    <div id=\"input-area\">
      <form id=\"chat-form\">
        <textarea id=\"chat-input\" rows=\"1\" placeholder=\"" <> placeholder <> "\" autofocus></textarea>
        <button type=\"submit\" aria-label=\"Send\"><svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><line x1=\"22\" y1=\"2\" x2=\"11\" y2=\"13\"/><polygon points=\"22 2 15 22 11 13 2 9 22 2\"/></svg></button>
      </form>
      <div id=\"input-hint\">Enter to send, Shift+Enter for new line</div>
    </div>
  </div>
  <div id=\"narrative-tab\" class=\"tab-content\">
    <button class=\"refresh-btn\" id=\"narrative-refresh\">Refresh</button>
    <div id=\"narrative-container\"><div class=\"narrative-empty\">Loading narrative entries...</div></div>
  </div>
  <div id=\"log-tab\" class=\"tab-content\">
    <button class=\"refresh-btn\" id=\"log-refresh\">Refresh</button>
    <div id=\"log-container\">Loading...</div>
  </div>
</div>
<script>
(function() {
  var STORAGE_KEY = 'springdrift_chat_history';
  var msgs = document.getElementById('messages');
  var form = document.getElementById('chat-form');
  var input = document.getElementById('chat-input');
  var statusEl = document.getElementById('status');
  var statusDot = document.getElementById('status-dot');
  var logContainer = document.getElementById('log-container');
  var narrativeContainer = document.getElementById('narrative-container');
  var thinkingOverlay = document.getElementById('thinking-overlay');
  var tabBtns = document.querySelectorAll('.tab-btn');
  var ws = null;
  var thinkingEl = null;
  var questionEl = null;
  var isThinking = false;
  var reconnectDelay = 1000;
  var chatHistory = [];

  // Configure marked for safe rendering
  marked.setOptions({ breaks: true, gfm: true });

  function renderMarkdown(text) {
    try { return marked.parse(text); }
    catch(e) { return escapeHtml(text); }
  }

  // ── localStorage persistence ──
  function saveChatHistory() {
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(chatHistory)); }
    catch(e) {}
  }

  function loadChatHistory() {
    try {
      var stored = localStorage.getItem(STORAGE_KEY);
      if (stored) {
        chatHistory = JSON.parse(stored);
        chatHistory.forEach(function(item) {
          if (item.role === 'user') renderUserMessage(item.text);
          else if (item.role === 'assistant') renderAssistantMessage(item.text, item.model, item.usage);
          else if (item.role === 'notification') renderNotification(item.text);
        });
        scrollBottom();
      }
    } catch(e) { chatHistory = []; }
  }

  // ── Tab switching ──
  tabBtns.forEach(function(btn) {
    btn.addEventListener('click', function() {
      var tab = btn.getAttribute('data-tab');
      // During thinking, only the chat tab is locked — allow switching to others
      if (isThinking && tab === 'chat') return;
      tabBtns.forEach(function(b) { b.classList.remove('active'); });
      document.querySelectorAll('.tab-content').forEach(function(c) { c.classList.remove('active'); });
      btn.classList.add('active');
      document.getElementById(tab + '-tab').classList.add('active');
      if (tab === 'log') requestLogData();
      else if (tab === 'narrative') requestNarrativeData();
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
      narrativeContainer.innerHTML = '<div class=\"narrative-empty\">No narrative entries yet. Entries appear after conversations.</div>';
      return;
    }
    var html = '';
    var sorted = entries.slice().reverse();
    sorted.forEach(function(e) {
      var cycleShort = (e.cycle_id || '').substring(0, 8);
      var time = (e.timestamp || '').substring(0, 19).replace('T', ' ');
      var st = (e.outcome && e.outcome.status) || 'unknown';
      var statusLabel = st.charAt(0).toUpperCase() + st.slice(1);
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
        }).join(' \\u2192 ');
        delegationHtml = '<div class=\"narrative-delegation\">Delegated to: ' + agents + '</div>';
      }
      html += '<div class=\"narrative-entry\">' +
        '<div class=\"narrative-header\">' +
          '<span class=\"narrative-cycle\">' + escapeHtml(cycleShort) + '</span>' +
          '<span class=\"narrative-time\">' + escapeHtml(time) + '</span>' +
          '<span class=\"narrative-status ' + st + '\">' + statusLabel + '</span>' +
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

  // ── Auto-resize textarea ──
  function autoResize() {
    input.style.height = 'auto';
    input.style.height = Math.min(input.scrollHeight, 200) + 'px';
  }
  input.addEventListener('input', autoResize);

  function connect() {
    var proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    var params = new URLSearchParams(location.search);
    var token = params.get('token');
    var tokenParam = token ? '?token=' + encodeURIComponent(token) : '';
    ws = new WebSocket(proto + '//' + location.host + '/ws' + tokenParam);

    ws.onopen = function() {
      statusEl.textContent = 'connected';
      statusDot.className = 'dot connected';
      reconnectDelay = 1000;
    };

    ws.onclose = function() {
      statusEl.textContent = 'reconnecting...';
      statusDot.className = 'dot disconnected';
      setTimeout(connect, reconnectDelay);
      reconnectDelay = Math.min(reconnectDelay * 2, 10000);
    };

    ws.onerror = function() {};

    ws.onmessage = function(evt) {
      var data;
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

  // ── Render helpers (no state mutation) ──
  function renderUserMessage(text) {
    var el = document.createElement('div');
    el.className = 'msg user';
    el.textContent = text;
    msgs.appendChild(el);
  }

  function renderAssistantMessage(text, model, usage) {
    var el = document.createElement('div');
    el.className = 'msg assistant';
    var body = document.createElement('div');
    body.className = 'md-body';
    body.innerHTML = renderMarkdown(text);
    el.appendChild(body);
    if (model || usage) {
      var meta = document.createElement('div');
      meta.className = 'meta';
      var parts = [];
      if (model) parts.push(model);
      if (usage) parts.push(usage.input + ' in / ' + usage.output + ' out');
      meta.textContent = parts.join(' | ');
      el.appendChild(meta);
    }
    msgs.appendChild(el);
  }

  function renderNotification(text) {
    var el = document.createElement('div');
    el.className = 'notification';
    el.textContent = text;
    msgs.appendChild(el);
  }

  // ── State-mutating message adders ──
  function addUserMessage(text) {
    renderUserMessage(text);
    chatHistory.push({ role: 'user', text: text });
    saveChatHistory();
    scrollBottom();
  }

  function addAssistantMessage(text, model, usage) {
    renderAssistantMessage(text, model, usage);
    chatHistory.push({ role: 'assistant', text: text, model: model, usage: usage });
    saveChatHistory();
    scrollBottom();
  }

  function addNotification(text) {
    renderNotification(text);
    chatHistory.push({ role: 'notification', text: text });
    saveChatHistory();
    scrollBottom();
  }

  function setThinkingLock(locked) {
    isThinking = locked;
    var chatBtn = document.querySelector('.tab-btn[data-tab=\"chat\"]');
    if (locked) {
      thinkingOverlay.classList.add('active');
      chatBtn.classList.add('chat-disabled');
    } else {
      thinkingOverlay.classList.remove('active');
      chatBtn.classList.remove('chat-disabled');
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
    var srcLabel = source === 'cognitive' ? 'Cognitive' : source.replace('agent:', '');
    questionEl.innerHTML =
      '<div class=\"q-source\">' + escapeHtml(srcLabel) + ' asks:</div>' +
      '<div class=\"q-text\">' + escapeHtml(text) + '</div>' +
      '<input type=\"text\" placeholder=\"Type your answer...\" autofocus>';
    var qInput = questionEl.querySelector('input');
    qInput.addEventListener('keydown', function(e) {
      if (e.key === 'Enter' && qInput.value.trim()) {
        var answer = qInput.value.trim();
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
    var d = document.createElement('div');
    d.textContent = s;
    return d.innerHTML;
  }

  function sendMessage() {
    var text = input.value.trim();
    if (!text || !ws || ws.readyState !== WebSocket.OPEN || isThinking) return;
    ws.send(JSON.stringify({ type: 'user_message', text: text }));
    addUserMessage(text);
    input.value = '';
    input.style.height = 'auto';
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

  // Load history from localStorage, then connect
  loadChatHistory();
  connect();
})();
</script>
</body>
</html>"
}

fn escape(s: String) -> String {
  s
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
}
