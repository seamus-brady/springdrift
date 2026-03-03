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
  }

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
  <div id=\"messages\"></div>
  <div id=\"input-area\">
    <form id=\"chat-form\">
      <input id=\"chat-input\" type=\"text\" placeholder=\"Message springdrift...\" autocomplete=\"off\" autofocus>
      <button type=\"submit\" aria-label=\"Send\"><svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><line x1=\"22\" y1=\"2\" x2=\"11\" y2=\"13\"/><polygon points=\"22 2 15 22 11 13 2 9 22 2\"/></svg></button>
    </form>
    <div id=\"input-hint\">Press Enter to send</div>
  </div>
</div>
<script>
(function() {
  const msgs = document.getElementById('messages');
  const form = document.getElementById('chat-form');
  const input = document.getElementById('chat-input');
  const status = document.getElementById('status');
  const statusDot = document.getElementById('status-dot');
  let ws = null;
  let thinkingEl = null;
  let questionEl = null;
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

  function connect() {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    ws = new WebSocket(proto + '//' + location.host + '/ws');

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
        }
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

  function showThinking() {
    if (thinkingEl) return;
    thinkingEl = document.createElement('div');
    thinkingEl.className = 'thinking';
    thinkingEl.innerHTML = '<span class=\"dots\"><span>.</span><span>.</span><span>.</span></span> Thinking';
    msgs.appendChild(thinkingEl);
    scrollBottom();
  }

  function removeThinking() {
    if (thinkingEl) { thinkingEl.remove(); thinkingEl = null; }
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
    if (!text || !ws || ws.readyState !== WebSocket.OPEN) return;
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
