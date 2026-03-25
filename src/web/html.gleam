//// Embedded HTML/CSS/JS for the web chat GUI.
//// Split into two pages: /chat (chat only) and /admin (narrative + log).

import gleam/string

// ---------------------------------------------------------------------------
// Public page functions
// ---------------------------------------------------------------------------

pub fn chat_page(agent_name: String, agent_version: String) -> String {
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
<title>" <> title <> " — Chat</title>
<script src=\"https://cdn.jsdelivr.net/npm/marked/marked.min.js\"></script>
<style>
" <> shared_css() <> sidebar_css() <> "
</style>
</head>
<body>
<div id=\"layout\">
" <> sidebar_html("chat") <> "
<div id=\"main-content\">
" <> header_html(title, version) <> "
<div id=\"tab-bar\">
  <button class=\"tab-btn active\" data-tab=\"chat\">Chat</button>
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
</div>
</div>
</div>
<script>
" <> sidebar_js() <> "
(function() {
  // Chat history is server-authoritative — no localStorage
  var msgs = document.getElementById('messages');
  var form = document.getElementById('chat-form');
  var input = document.getElementById('chat-input');
  var statusEl = document.getElementById('status');
  var statusDot = document.getElementById('status-dot');
  var thinkingOverlay = document.getElementById('thinking-overlay');
  var ws = null;
  var thinkingEl = null;
  var isThinking = false;
  var waitingForAnswer = false;
  var wasRevised = false;
  var reconnectDelay = 1000;
  var chatHistory = [];

  marked.setOptions({ breaks: true, gfm: true });

  function renderMarkdown(text) {
    try { return marked.parse(text); }
    catch(e) { return escapeHtml(text); }
  }

  function saveChatHistory() {}

  function renderSessionHistory(messages) {
    msgs.innerHTML = '';
    chatHistory = [];
    if (!messages || messages.length === 0) return;
    messages.forEach(function(item) {
      if (item.role === 'user') {
        renderUserMessage(item.text);
        chatHistory.push({ role: 'user', text: item.text });
      } else if (item.role === 'assistant') {
        renderAssistantMessage(item.text, null, null, false);
        chatHistory.push({ role: 'assistant', text: item.text });
      }
    });
    scrollBottom();
  }

  " <> ws_connect_js() <> "

  function handleServerMessage(data) {
    switch (data.type) {
      case 'session_history':
        renderSessionHistory(data.messages);
        break;
      case 'assistant_message':
        removeThinking();
        waitingForAnswer = false;
        addAssistantMessage(data.text, data.model, data.usage, wasRevised);
        wasRevised = false;
        break;
      case 'thinking':
        showThinking();
        break;
      case 'question':
        removeThinking();
        var srcLabel = data.source === 'cognitive' ? '' : data.source.replace('agent:', '') + ' asks: ';
        addAssistantMessage(srcLabel + data.text, null, null);
        waitingForAnswer = true;
        break;
      case 'notification':
        if (data.kind === 'tool_calling') {
          addNotification('Using tool: ' + data.name);
        } else if (data.kind === 'save_warning') {
          addNotification(data.message);
        } else if (data.kind === 'safety') {
          var badge = data.decision === 'ACCEPT' ? '\\u2705' : data.decision === 'REJECT' ? '\\u274C' : '\\u26A0\\uFE0F';
          addNotification(badge + ' D\\' ' + data.decision + ' (score: ' + data.score.toFixed(2) + ')');
          if (data.decision === 'MODIFY') wasRevised = true;
        }
        break;
    }
  }

  function renderUserMessage(text) {
    var el = document.createElement('div');
    el.className = 'msg user';
    el.textContent = text;
    msgs.appendChild(el);
  }

  function renderAssistantMessage(text, model, usage, revised) {
    var el = document.createElement('div');
    el.className = 'msg assistant';
    if (revised) {
      var badge = document.createElement('span');
      badge.className = 'revised-badge';
      badge.textContent = 'revised';
      badge.title = 'This response was revised by the D\\' quality gate before delivery';
      el.appendChild(badge);
    }
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

  function addUserMessage(text) {
    renderUserMessage(text);
    chatHistory.push({ role: 'user', text: text });
    saveChatHistory();
    scrollBottom();
  }

  function addAssistantMessage(text, model, usage, revised) {
    renderAssistantMessage(text, model, usage, revised);
    chatHistory.push({ role: 'assistant', text: text, model: model, usage: usage, revised: revised || false });
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
    if (locked) {
      thinkingOverlay.classList.add('active');
    } else {
      thinkingOverlay.classList.remove('active');
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
    if (waitingForAnswer) {
      ws.send(JSON.stringify({ type: 'user_answer', text: text }));
      waitingForAnswer = false;
    } else {
      ws.send(JSON.stringify({ type: 'user_message', text: text }));
    }
    addUserMessage(text);
    input.value = '';
    input.style.height = 'auto';
  }

  function autoResize() {
    input.style.height = 'auto';
    input.style.height = Math.min(input.scrollHeight, 200) + 'px';
  }
  input.addEventListener('input', autoResize);

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

  // History is loaded from server on WebSocket connect (session_history message)
  connect();
})();
</script>
</body>
</html>"
}

pub fn admin_page(agent_name: String, agent_version: String) -> String {
  let version_display = case agent_version {
    "" -> ""
    v -> " v" <> v
  }
  let title = escape(agent_name)
  let version = escape(version_display)

  "<!DOCTYPE html>
<html lang=\"en\">
<head>
<meta charset=\"UTF-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
<title>" <> title <> " — Admin</title>
<style>
" <> shared_css() <> sidebar_css() <> "
</style>
</head>
<body>
<div id=\"layout\">
" <> sidebar_html("admin") <> "
<div id=\"main-content\">
" <> header_html(title, version) <> "
<div id=\"tab-bar\">
  <button class=\"tab-btn active\" data-tab=\"narrative\">Narrative</button>
  <button class=\"tab-btn\" data-tab=\"log\">Log</button>
  <button class=\"tab-btn\" data-tab=\"scheduler\">Scheduler</button>
  <button class=\"tab-btn\" data-tab=\"cycles\">Cycles</button>
  <button class=\"tab-btn\" data-tab=\"planner\">Planner</button>
  <button class=\"tab-btn\" data-tab=\"dprime\">D' Safety</button>
  <button class=\"tab-btn\" data-tab=\"dprime-config\">D' Config</button>
</div>
<div id=\"content-area\">
  <div id=\"narrative-tab\" class=\"tab-content active\">
    <button class=\"refresh-btn\" id=\"narrative-refresh\">Refresh</button>
    <div id=\"narrative-container\"><div class=\"narrative-empty\">Loading narrative entries...</div></div>
  </div>
  <div id=\"log-tab\" class=\"tab-content\">
    <button class=\"refresh-btn\" id=\"log-refresh\">Refresh</button>
    <div id=\"log-container\">Loading...</div>
  </div>
  <div id=\"scheduler-tab\" class=\"tab-content\">
    <button class=\"refresh-btn\" id=\"scheduler-refresh\">Refresh</button>
    <div id=\"scheduler-container\">
      <table class=\"admin-table\"><thead><tr>
        <th>Name</th><th>Kind</th><th>Status</th><th>Target</th><th>Due/Interval</th><th>Runs</th><th>Errors</th><th>Last Result</th>
      </tr></thead><tbody id=\"scheduler-body\"></tbody></table>
    </div>
  </div>
  <div id=\"cycles-tab\" class=\"tab-content\">
    <button class=\"refresh-btn\" id=\"cycles-refresh\">Refresh</button>
    <div id=\"cycles-container\">
      <table class=\"admin-table\"><thead><tr>
        <th>Cycle ID</th><th>Time</th><th>Outcome</th><th>Model</th><th>Tools</th><th>Tokens</th><th>Duration</th>
      </tr></thead><tbody id=\"cycles-body\"></tbody></table>
    </div>
  </div>
  <div id=\"planner-tab\" class=\"tab-content\">
    <button class=\"refresh-btn\" id=\"planner-refresh\">Refresh</button>
    <div id=\"planner-container\">
      <div id=\"planner-endeavours\"><h3 style=\"margin:12px 0 8px;font-size:15px;color:var(--text-secondary)\">Endeavours</h3><div id=\"endeavours-list\"><div class=\"narrative-empty\">Loading...</div></div></div>
      <div id=\"planner-tasks\" style=\"margin-top:20px\"><h3 style=\"margin:12px 0 8px;font-size:15px;color:var(--text-secondary)\">Active Tasks</h3>
        <table class=\"admin-table\"><thead><tr>
          <th>Task</th><th>Title</th><th>Status</th><th>Steps</th><th>Complexity</th><th>Forecast</th><th>Cycles</th>
        </tr></thead><tbody id=\"planner-body\"></tbody></table>
      </div>
    </div>
  </div>
  <div id=\"dprime-tab\" class=\"tab-content\">
    <button class=\"refresh-btn\" id=\"dprime-refresh\">Refresh</button>
    <div id=\"dprime-container\">
      <table class=\"admin-table\"><thead><tr>
        <th>Time</th><th>Cycle</th><th>Type</th><th>Gate</th><th>Decision</th><th>Score</th>
      </tr></thead><tbody id=\"dprime-body\"></tbody></table>
    </div>
  </div>
  <div id=\"dprime-config-tab\" class=\"tab-content\">
    <button class=\"refresh-btn\" id=\"dprime-config-refresh\">Refresh</button>
    <div id=\"dprime-config-container\">Loading D' configuration...</div>
  </div>
</div>
</div>
</div>
<script>
" <> sidebar_js() <> "
(function() {
  var statusEl = document.getElementById('status');
  var statusDot = document.getElementById('status-dot');
  var logContainer = document.getElementById('log-container');
  var narrativeContainer = document.getElementById('narrative-container');
  var tabBtns = document.querySelectorAll('.tab-btn');
  var ws = null;
  var reconnectDelay = 1000;

  tabBtns.forEach(function(btn) {
    btn.addEventListener('click', function() {
      var tab = btn.getAttribute('data-tab');
      tabBtns.forEach(function(b) { b.classList.remove('active'); });
      document.querySelectorAll('.tab-content').forEach(function(c) { c.classList.remove('active'); });
      btn.classList.add('active');
      document.getElementById(tab + '-tab').classList.add('active');
      if (tab === 'log') requestLogData();
      else if (tab === 'narrative') requestNarrativeData();
      else if (tab === 'scheduler') requestSchedulerData();
      else if (tab === 'cycles') requestSchedulerCycles();
      else if (tab === 'planner') requestPlannerData();
      else if (tab === 'dprime') requestDprimeData();
      else if (tab === 'dprime-config') requestDprimeConfig();
    });
  });

  document.getElementById('log-refresh').addEventListener('click', requestLogData);
  document.getElementById('narrative-refresh').addEventListener('click', requestNarrativeData);
  document.getElementById('scheduler-refresh').addEventListener('click', requestSchedulerData);
  document.getElementById('cycles-refresh').addEventListener('click', requestSchedulerCycles);
  document.getElementById('planner-refresh').addEventListener('click', requestPlannerData);
  document.getElementById('dprime-refresh').addEventListener('click', requestDprimeData);
  document.getElementById('dprime-config-refresh').addEventListener('click', requestDprimeConfig);

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

  function requestSchedulerData() {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'request_scheduler_data' }));
    }
  }

  function requestSchedulerCycles() {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'request_scheduler_cycles' }));
    }
  }

  function requestPlannerData() {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'request_planner_data' }));
    }
  }

  function requestDprimeData() {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'request_dprime_data' }));
    }
  }

  function requestDprimeConfig() {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'request_dprime_config' }));
    }
  }

  function dprimeScoreColor(score) {
    if (score < 0.35) return '#248a3d';
    if (score <= 0.55) return '#c77c00';
    return '#d70015';
  }

  function dprimeDecisionBadge(decision) {
    var d = decision.toUpperCase();
    if (d === 'ACCEPT') return '\\u2705 ACCEPT';
    if (d === 'MODIFY') return '\\u26A0\\uFE0F MODIFY';
    if (d === 'REJECT') return '\\u274C REJECT';
    if (d === 'ABORT') return '\\u26D4 ABORT';
    return decision;
  }

  function renderDprimeGates(gates) {
    var body = document.getElementById('dprime-body');
    if (!gates || gates.length === 0) {
      body.innerHTML = '<tr><td colspan=\"6\" style=\"text-align:center;opacity:.5\">No D\\' gate decisions today</td></tr>';
      return;
    }
    var sorted = gates.slice().reverse();
    body.innerHTML = sorted.map(function(g) {
      var time = (g.timestamp || '').substring(11, 19);
      var scoreColor = dprimeScoreColor(g.score);
      return '<tr>' +
        '<td>' + escapeHtml(time) + '</td>' +
        '<td>' + escapeHtml((g.cycle_id || '').substring(0, 8)) + '</td>' +
        '<td>' + escapeHtml(g.node_type) + '</td>' +
        '<td><span class=\"dprime-gate-badge dprime-gate-' + escapeHtml(g.gate) + '\">' + escapeHtml(g.gate) + '</span></td>' +
        '<td>' + dprimeDecisionBadge(g.decision) + '</td>' +
        '<td style=\"color:' + scoreColor + ';font-weight:600\">' + g.score.toFixed(3) + '</td>' +
        '</tr>';
    }).join('');
  }

  function renderDprimeConfig(config) {
    var container = document.getElementById('dprime-config-container');
    if (!config || config.error) {
      container.innerHTML = '<div style=\"opacity:.5;padding:20px\">D\\' config not available: ' + (config ? config.error : 'no data') + '</div>';
      return;
    }
    var html = '';

    // Gates
    var gates = config.gates || {};
    var gateNames = Object.keys(gates);
    gateNames.forEach(function(gateName) {
      var gate = gates[gateName];
      var features = gate.features || [];
      var canary = gate.canary_enabled ? '\\u2705 Canary enabled' : '\\u274c Canary disabled';
      html += '<div class=\"dprime-config-gate\">';
      html += '<h3 class=\"dprime-gate-title\"><span class=\"dprime-gate-badge dprime-gate-' + gateName + '\">' + gateName + '</span> gate';
      html += '<span class=\"dprime-thresholds\">modify: ' + (gate.modify_threshold || '?') + ' | reject: ' + (gate.reject_threshold || '?') + ' | ' + canary + '</span></h3>';
      html += '<table class=\"admin-table\"><thead><tr><th>Feature</th><th>Importance</th><th>Critical</th><th>Description</th></tr></thead><tbody>';
      features.forEach(function(f) {
        var imp = f.importance || 'medium';
        var impColor = imp === 'high' ? '#d70015' : imp === 'medium' ? '#c77c00' : '#248a3d';
        var crit = f.critical ? '\\u26a0\\ufe0f Yes' : 'No';
        html += '<tr><td style=\"font-weight:600\">' + escapeHtml(f.name) + '</td>';
        html += '<td style=\"color:' + impColor + '\">' + imp + '</td>';
        html += '<td>' + crit + '</td>';
        html += '<td style=\"opacity:.8;font-size:12px\">' + escapeHtml(f.description || '') + '</td></tr>';
      });
      html += '</tbody></table></div>';
    });

    // Agent overrides
    var overrides = config.agent_overrides || {};
    var agentNames = Object.keys(overrides);
    if (agentNames.length > 0) {
      html += '<div class=\"dprime-config-gate\"><h3 class=\"dprime-gate-title\">Agent Overrides</h3>';
      agentNames.forEach(function(agentName) {
        var ovr = overrides[agentName];
        var toolGate = ovr.tool || {};
        var features = toolGate.features || [];
        html += '<h4 style=\"margin:12px 0 6px;font-size:13px;color:var(--text-secondary)\">' + escapeHtml(agentName) + ' agent';
        if (toolGate.modify_threshold) html += ' <span class=\"dprime-thresholds\">modify: ' + toolGate.modify_threshold + ' | reject: ' + toolGate.reject_threshold + '</span>';
        html += '</h4>';
        if (features.length > 0) {
          html += '<table class=\"admin-table\"><thead><tr><th>Feature</th><th>Importance</th><th>Critical</th><th>Description</th></tr></thead><tbody>';
          features.forEach(function(f) {
            var imp = f.importance || 'medium';
            var impColor = imp === 'high' ? '#d70015' : imp === 'medium' ? '#c77c00' : '#248a3d';
            var crit = f.critical ? '\\u26a0\\ufe0f Yes' : 'No';
            html += '<tr><td style=\"font-weight:600\">' + escapeHtml(f.name) + '</td>';
            html += '<td style=\"color:' + impColor + '\">' + imp + '</td>';
            html += '<td>' + crit + '</td>';
            html += '<td style=\"opacity:.8;font-size:12px\">' + escapeHtml(f.description || '') + '</td></tr>';
          });
          html += '</tbody></table>';
        }
      });
      html += '</div>';
    }

    // Meta config
    var meta = config.meta;
    if (meta) {
      html += '<div class=\"dprime-config-gate\"><h3 class=\"dprime-gate-title\">Meta Observer</h3>';
      html += '<div style=\"font-size:13px;line-height:1.8;padding:8px 0\">';
      html += '<span style=\"opacity:.6\">Enabled:</span> ' + (meta.enabled ? '\\u2705' : '\\u274c') + ' &nbsp;';
      html += '<span style=\"opacity:.6\">Rate limit:</span> ' + (meta.rate_limit_max_cycles || '?') + ' cycles/' + ((meta.rate_limit_window_ms || 60000)/1000) + 's &nbsp;';
      html += '<span style=\"opacity:.6\">Elevated threshold:</span> ' + (meta.elevated_score_threshold || '?') + ' &nbsp;';
      html += '<span style=\"opacity:.6\">Streak threshold:</span> ' + (meta.elevated_streak_threshold || '?') + ' &nbsp;';
      html += '<span style=\"opacity:.6\">Rejection threshold:</span> ' + (meta.rejection_count_threshold || '?') + '/' + (meta.rejection_window_cycles || '?') + ' cycles &nbsp;';
      html += '<span style=\"opacity:.6\">Cooldown:</span> ' + (meta.cooldown_delay_ms || '?') + 'ms &nbsp;';
      html += '<span style=\"opacity:.6\">Tighten factor:</span> ' + (meta.tighten_factor || '?') + ' &nbsp;';
      html += '<span style=\"opacity:.6\">Decay:</span> ' + (meta.decay_days || '?') + ' days';
      html += '</div></div>';
    }

    // Deterministic pre-filter
    var det = config.deterministic;
    if (det) {
      html += '<div class=\"dprime-config-gate\"><h3 class=\"dprime-gate-title\">Deterministic Pre-filter</h3>';
      html += '<div style=\"font-size:13px;line-height:1.8;padding:8px 0\">';
      html += '<span style=\"opacity:.6\">Enabled:</span> ' + (det.enabled ? '\\u2705' : '\\u274c') + ' &nbsp;';
      var inputCount = (det.input_rules || []).length;
      var toolCount = (det.tool_rules || []).length;
      var outputCount = (det.output_rules || []).length;
      html += '<span style=\"opacity:.6\">Input rules:</span> ' + inputCount + ' &nbsp;';
      html += '<span style=\"opacity:.6\">Tool rules:</span> ' + toolCount + ' &nbsp;';
      html += '<span style=\"opacity:.6\">Output rules:</span> ' + outputCount + ' &nbsp;';
      var pathCount = (det.path_allowlist || []).length;
      var domainCount = (det.domain_allowlist || []).length;
      if (pathCount > 0) html += '<span style=\"opacity:.6\">Path allowlist:</span> ' + pathCount + ' entries &nbsp;';
      if (domainCount > 0) html += '<span style=\"opacity:.6\">Domain allowlist:</span> ' + domainCount + ' entries &nbsp;';
      html += '</div>';
      // Show rules in a table if any exist
      var allRules = [];
      (det.input_rules || []).forEach(function(r) { allRules.push({scope: 'input', id: r.id, action: r.action}); });
      (det.tool_rules || []).forEach(function(r) { allRules.push({scope: 'tool', id: r.id, action: r.action}); });
      (det.output_rules || []).forEach(function(r) { allRules.push({scope: 'output', id: r.id, action: r.action}); });
      if (allRules.length > 0) {
        html += '<table class=\"admin-table\"><thead><tr><th>Scope</th><th>Rule ID</th><th>Action</th></tr></thead><tbody>';
        allRules.forEach(function(r) {
          var actionColor = r.action === 'block' ? '#d70015' : '#c77c00';
          html += '<tr><td>' + r.scope + '</td><td style=\"font-weight:600\">' + escapeHtml(r.id) + '</td>';
          html += '<td style=\"color:' + actionColor + '\">' + r.action + '</td></tr>';
        });
        html += '</tbody></table>';
      }
      html += '</div>';
    }

    container.innerHTML = html || '<div style=\"opacity:.5;padding:20px\">No D\\' configuration loaded</div>';
  }

  function renderSchedulerJobs(jobs) {
    var body = document.getElementById('scheduler-body');
    if (!jobs || jobs.length === 0) { body.innerHTML = '<tr><td colspan=\"8\" style=\"text-align:center;opacity:.5\">No scheduled jobs</td></tr>'; return; }
    body.innerHTML = jobs.map(function(j) {
      var due = j.due_at ? j.due_at : (j.interval_ms > 0 ? (j.interval_ms/1000)+'s' : '-');
      var lr = j.last_result ? j.last_result.substring(0,80) : '-';
      return '<tr><td>'+j.name+'</td><td>'+j.kind+'</td><td>'+j.status+'</td><td>'+(j['for']||'-')+'</td><td>'+due+'</td><td>'+j.run_count+'</td><td>'+j.error_count+'</td><td style=\"max-width:200px;overflow:hidden;text-overflow:ellipsis\">'+lr+'</td></tr>';
    }).join('');
  }

  function renderSchedulerCycles(cycles) {
    var body = document.getElementById('cycles-body');
    if (!cycles || cycles.length === 0) { body.innerHTML = '<tr><td colspan=\"7\" style=\"text-align:center;opacity:.5\">No scheduler cycles today</td></tr>'; return; }
    body.innerHTML = cycles.map(function(c) {
      var badge = c.outcome === 'success' ? '\\u2705' : c.outcome === 'pending' ? '\\u23f3' : '\\u274c';
      var tokens = c.tokens_in + c.tokens_out;
      var dur = c.duration_ms > 0 ? (c.duration_ms/1000).toFixed(1)+'s' : '-';
      return '<tr><td>'+c.cycle_id.substring(0,8)+'</td><td>'+c.timestamp+'</td><td>'+badge+' '+c.outcome+'</td><td>'+c.model+'</td><td>'+c.tool_call_count+'</td><td>'+tokens+'</td><td>'+dur+'</td></tr>';
    }).join('');
  }

  function forecastColor(score) {
    if (score === null || score === undefined) return 'var(--text-dim)';
    if (score < 0.4) return '#248a3d';
    if (score <= 0.55) return '#c77c00';
    return '#d70015';
  }

  function renderPlannerData(tasks, endeavours) {
    var eList = document.getElementById('endeavours-list');
    if (!endeavours || endeavours.length === 0) {
      eList.innerHTML = '<div class=\"narrative-empty\">No endeavours yet.</div>';
    } else {
      eList.innerHTML = endeavours.map(function(e) {
        var statusBadge = e.status === 'open' ? '\\u25CB' : e.status === 'complete' ? '\\u2705' : '\\u274C';
        return '<div class=\"narrative-entry\">' +
          '<div class=\"narrative-header\">' +
            '<span class=\"narrative-status ' + e.status + '\">' + statusBadge + ' ' + e.status + '</span>' +
            '<strong>' + escapeHtml(e.title) + '</strong>' +
            '<span class=\"narrative-time\">' + e.task_count + ' task' + (e.task_count !== 1 ? 's' : '') + '</span>' +
          '</div>' +
          (e.description ? '<div class=\"narrative-summary\">' + escapeHtml(e.description) + '</div>' : '') +
        '</div>';
      }).join('');
    }
    var body = document.getElementById('planner-body');
    if (!tasks || tasks.length === 0) {
      body.innerHTML = '<tr><td colspan=\"7\" style=\"text-align:center;opacity:.5\">No active tasks</td></tr>';
    } else {
      body.innerHTML = tasks.map(function(t) {
        var progress = t.steps_completed + '/' + t.steps_total;
        var fc = t.forecast_score !== null ? t.forecast_score.toFixed(2) : '-';
        var fcStyle = ' style=\"color:' + forecastColor(t.forecast_score) + ';font-weight:600\"';
        var stepsHtml = '';
        if (t.steps && t.steps.length > 0) {
          stepsHtml = '<tr class=\"planner-steps-row\" data-task=\"' + t.task_id + '\" style=\"display:none\"><td colspan=\"7\"><div class=\"planner-steps\">' +
            t.steps.map(function(s) {
              var icon = s.status === 'complete' ? '\\u2705' : s.status === 'active' ? '\\u25B6' : '\\u25CB';
              return '<div style=\"padding:3px 0 3px 20px;font-size:13px\">' + icon + ' ' + escapeHtml(s.description) + '</div>';
            }).join('') +
            '</div></td></tr>';
        }
        return '<tr class=\"planner-task-row\" data-task=\"' + t.task_id + '\" style=\"cursor:pointer\">' +
          '<td>' + escapeHtml(t.task_id.substring(0,8)) + '</td>' +
          '<td>' + escapeHtml(t.title) + '</td>' +
          '<td>' + escapeHtml(t.status) + '</td>' +
          '<td>' + progress + '</td>' +
          '<td>' + escapeHtml(t.complexity) + '</td>' +
          '<td' + fcStyle + '>' + fc + '</td>' +
          '<td>' + t.cycle_count + '</td></tr>' + stepsHtml;
      }).join('');
      body.querySelectorAll('.planner-task-row').forEach(function(row) {
        row.addEventListener('click', function() {
          var tid = row.getAttribute('data-task');
          var sr = body.querySelector('.planner-steps-row[data-task=\"' + tid + '\"]');
          if (sr) sr.style.display = sr.style.display === 'none' ? '' : 'none';
        });
      });
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

  " <> ws_connect_js() <> "

  function handleServerMessage(data) {
    switch (data.type) {
      case 'log_data':
        renderLogEntries(data.entries);
        break;
      case 'narrative_data':
        renderNarrativeEntries(data.entries);
        break;
      case 'scheduler_data':
        renderSchedulerJobs(data.jobs);
        break;
      case 'scheduler_cycles_data':
        renderSchedulerCycles(data.cycles);
        break;
      case 'planner_data':
        renderPlannerData(data.tasks, data.endeavours);
        break;
      case 'dprime_data':
        renderDprimeGates(data.gates);
        break;
      case 'dprime_config_data':
        renderDprimeConfig(data.config);
        break;
      case 'notification':
        if (data.kind === 'safety') {
          var dprimeTab = document.getElementById('dprime-tab');
          if (dprimeTab && dprimeTab.classList.contains('active')) {
            var body = document.getElementById('dprime-body');
            var emptyRow = body.querySelector('td[colspan]');
            if (emptyRow) body.innerHTML = '';
            var now = new Date();
            var time = ('0'+now.getHours()).slice(-2)+':'+('0'+now.getMinutes()).slice(-2)+':'+('0'+now.getSeconds()).slice(-2);
            var scoreColor = dprimeScoreColor(data.score);
            var row = '<tr style=\"background:rgba(218,126,55,0.06)\">' +
              '<td>' + time + '</td>' +
              '<td>live</td>' +
              '<td>-</td>' +
              '<td>' + escapeHtml(data.decision.toLowerCase().indexOf('tool') >= 0 ? 'tool' : 'input') + '</td>' +
              '<td>' + dprimeDecisionBadge(data.decision) + '</td>' +
              '<td style=\"color:' + scoreColor + ';font-weight:600\">' + data.score.toFixed(3) + '</td>' +
              '</tr>';
            body.insertAdjacentHTML('afterbegin', row);
          }
        }
        break;
    }
  }

  function escapeHtml(s) {
    var d = document.createElement('div');
    d.textContent = s;
    return d.innerHTML;
  }

  connect();
  requestNarrativeData();
})();
</script>
</body>
</html>"
}

// ---------------------------------------------------------------------------
// Shared HTML/CSS/JS helpers
// ---------------------------------------------------------------------------

fn header_html(title: String, version: String) -> String {
  "<div id=\"header\">
  <div id=\"header-left\">
    <h1>" <> title <> "</h1>
    <span class=\"version\">" <> version <> "</span>
  </div>
  <div id=\"header-right\">
    <span class=\"dot\" id=\"status-dot\"></span>
    <span id=\"status\">connecting...</span>
  </div>
</div>"
}

fn shared_css() -> String {
  "  * { margin: 0; padding: 0; box-sizing: border-box; }
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
    margin: 0;
    font-size: 17px;
  }

  /* ── Layout ──────────────────────────────────────── */
  #layout {
    display: flex;
    height: 100vh;
  }
  #main-content {
    flex: 1;
    display: flex;
    flex-direction: column;
    min-width: 0;
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
    padding: 0 24px;
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
    position: relative;
  }
  .revised-badge {
    display: inline-block;
    font-size: 10px;
    font-weight: 600;
    color: #c77c00;
    background: rgba(255,149,0,0.10);
    padding: 2px 7px;
    border-radius: 4px;
    margin-bottom: 6px;
    cursor: help;
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
  .admin-table { width: 100%; border-collapse: collapse; font-size: 13px; }
  .admin-table th, .admin-table td { padding: 6px 10px; border-bottom: 1px solid var(--border); text-align: left; }
  .admin-table th { background: var(--header-bg); font-weight: 600; position: sticky; top: 0; }
  .admin-table tr:hover td { background: var(--accent-light); }
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

  /* ── D' Safety tab ─────────────────────────────── */
  #dprime-container {
    flex: 1;
    overflow-y: auto;
    padding: 0 0 16px;
    scrollbar-width: none;
    -ms-overflow-style: none;
  }
  #dprime-container::-webkit-scrollbar { display: none; }
  .dprime-gate-badge {
    font-size: 11px;
    font-weight: 600;
    padding: 2px 8px;
    border-radius: 5px;
    text-transform: uppercase;
  }
  .dprime-gate-input { background: rgba(0,122,255,0.10); color: #007aff; }
  .dprime-gate-tool { background: rgba(255,149,0,0.12); color: #c77c00; }
  .dprime-gate-output { background: rgba(52,199,89,0.12); color: #248a3d; }
  .dprime-gate-post_exec { background: rgba(175,82,222,0.12); color: #8944ab; }

  /* ── D' Config tab ─────────────────────────────── */
  #dprime-config-container { max-height: calc(100vh - 200px); overflow-y: auto; }
  .dprime-config-gate { margin-bottom: 24px; }
  .dprime-gate-title { font-size: 14px; font-weight: 600; margin: 16px 0 8px; display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
  .dprime-thresholds { font-size: 12px; font-weight: 400; opacity: 0.6; margin-left: 8px; }
"
}

fn sidebar_css() -> String {
  "
  /* ── Sidebar ──────────────────────────────────────── */
  #sidebar {
    width: 200px;
    background: var(--header-bg);
    border-right: 1px solid var(--header-border);
    display: flex;
    flex-direction: column;
    flex-shrink: 0;
    transition: width 0.2s ease;
    overflow: hidden;
  }
  #sidebar.collapsed {
    width: 48px;
  }
  #sidebar-toggle {
    width: 100%;
    padding: 14px 12px;
    border: none;
    background: none;
    cursor: pointer;
    text-align: left;
    font-size: 18px;
    color: var(--text-secondary);
    display: flex;
    align-items: center;
    gap: 10px;
  }
  #sidebar-toggle:hover {
    background: rgba(0,0,0,0.04);
  }
  #sidebar-toggle .toggle-icon {
    flex-shrink: 0;
    width: 24px;
    text-align: center;
  }
  #sidebar-toggle .toggle-label {
    white-space: nowrap;
    font-size: 14px;
    font-weight: 600;
    font-family: inherit;
  }
  #sidebar.collapsed .toggle-label {
    display: none;
  }
  #sidebar nav {
    display: flex;
    flex-direction: column;
    padding: 4px 8px;
    gap: 2px;
  }
  #sidebar nav a {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 10px 12px;
    border-radius: 8px;
    text-decoration: none;
    color: var(--text-secondary);
    font-size: 14px;
    font-weight: 500;
    font-family: inherit;
    white-space: nowrap;
    transition: background 0.15s, color 0.15s;
  }
  #sidebar nav a:hover {
    background: rgba(0,0,0,0.04);
    color: var(--text);
  }
  #sidebar nav a.active {
    background: var(--accent-light);
    color: var(--accent);
    font-weight: 600;
  }
  #sidebar nav a .nav-icon {
    flex-shrink: 0;
    width: 20px;
    text-align: center;
    font-size: 16px;
  }
  #sidebar nav a .nav-label {
    overflow: hidden;
  }
  #sidebar.collapsed nav a .nav-label {
    display: none;
  }
"
}

fn sidebar_html(active: String) -> String {
  let chat_active = case active {
    "chat" -> " active"
    _ -> ""
  }
  let admin_active = case active {
    "admin" -> " active"
    _ -> ""
  }
  "<div id=\"sidebar\">
  <button id=\"sidebar-toggle\">
    <span class=\"toggle-icon\">&laquo;</span>
    <span class=\"toggle-label\">Menu</span>
  </button>
  <nav>
    <a href=\"/chat\" target=\"_blank\" class=\"" <> chat_active <> "\">
      <span class=\"nav-icon\">&bull;</span>
      <span class=\"nav-label\">Chat</span>
    </a>
    <a href=\"/admin\" target=\"_blank\" class=\"" <> admin_active <> "\">
      <span class=\"nav-icon\">&bull;</span>
      <span class=\"nav-label\">Admin</span>
    </a>
  </nav>
</div>"
}

fn sidebar_js() -> String {
  "(function() {
  var SIDEBAR_KEY = 'springdrift_sidebar';
  var sidebar = document.getElementById('sidebar');
  var toggle = document.getElementById('sidebar-toggle');
  var toggleIcon = toggle.querySelector('.toggle-icon');

  function setSidebarState(collapsed) {
    if (collapsed) {
      sidebar.classList.add('collapsed');
      toggleIcon.innerHTML = '&raquo;';
    } else {
      sidebar.classList.remove('collapsed');
      toggleIcon.innerHTML = '&laquo;';
    }
    try { localStorage.setItem(SIDEBAR_KEY, collapsed ? 'collapsed' : 'expanded'); }
    catch(e) {}
  }

  toggle.addEventListener('click', function() {
    setSidebarState(!sidebar.classList.contains('collapsed'));
  });

  try {
    var stored = localStorage.getItem(SIDEBAR_KEY);
    if (stored === 'collapsed') setSidebarState(true);
  } catch(e) {}
})();
"
}

fn ws_connect_js() -> String {
  "function connect() {
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
  }"
}

fn escape(s: String) -> String {
  s
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
}
