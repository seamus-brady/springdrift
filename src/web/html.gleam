//// Embedded HTML/CSS/JS for the web chat GUI.
//// Split into two pages: /chat (chat only) and /admin (narrative + log).

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

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
<div id=\"ambient-layer\" aria-hidden=\"true\"></div>
<div id=\"layout\">
" <> sidebar_html("chat") <> "
<aside id=\"history-panel\" aria-label=\"Chat history\">
  <div id=\"history-header\">
    <button id=\"history-toggle\" aria-label=\"Collapse chat history\" title=\"Collapse\">
      <span class=\"history-toggle-icon\">&#9776;</span>
    </button>
    <span id=\"history-title\">Chats</span>
  </div>
  <div id=\"history-list\"></div>
  <div id=\"history-empty\" class=\"hidden\">No past conversations yet.</div>
  <div id=\"history-loading\" class=\"hidden\">Loading\\u2026</div>
</aside>
<div id=\"main-content\">
" <> header_html(title, version) <> "
<div id=\"tab-bar\">
  <button class=\"tab-btn active\" data-tab=\"chat\">Chat</button>
  <button class=\"tab-btn\" data-tab=\"activity\">Activity</button>
</div>
<div id=\"content-area\">
  <div id=\"chat-tab\" class=\"tab-content active\">
    <div id=\"status-strip\" class=\"hidden\" aria-live=\"polite\">
      <span class=\"status-label\">Idle</span>
      <span class=\"status-detail\"></span>
      <span class=\"status-meta\"></span>
    </div>
    <div id=\"messages\"></div>
    <div id=\"input-area\">
      <form id=\"chat-form\">
        <textarea id=\"chat-input\" rows=\"1\" placeholder=\"" <> placeholder <> "\" autofocus></textarea>
        <button type=\"submit\" aria-label=\"Send\"><svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><line x1=\"22\" y1=\"2\" x2=\"11\" y2=\"13\"/><polygon points=\"22 2 15 22 11 13 2 9 22 2\"/></svg></button>
      </form>
      <div id=\"input-hint\">Enter to send, Shift+Enter for new line</div>
    </div>
  </div>
  <div id=\"activity-tab\" class=\"tab-content\">
    <div id=\"activity-messages\"></div>
    <div id=\"activity-empty\" style=\"padding:2em;text-align:center;color:#888\">No activity yet</div>
  </div>
</div>
</div>
</div>
<script>
" <> sidebar_js() <> "
(function() {
  // Chat history is server-authoritative — no localStorage
  var msgs = document.getElementById('messages');
  var activityMsgs = document.getElementById('activity-messages');
  var activityEmpty = document.getElementById('activity-empty');
  var form = document.getElementById('chat-form');
  var input = document.getElementById('chat-input');
  var statusEl = document.getElementById('status');
  var statusDot = document.getElementById('status-dot');
  var statusStrip = document.getElementById('status-strip');
  var statusStripLabel = statusStrip.querySelector('.status-label');
  var statusStripDetail = statusStrip.querySelector('.status-detail');
  var statusStripMeta = statusStrip.querySelector('.status-meta');
  var ws = null;
  var thinkingEl = null;
  var thinkingSteps = null;
  var isThinking = false;
  var waitingForAnswer = false;
  var wasRevised = false;
  var reconnectDelay = 1000;
  var chatHistory = [];
  var activityCount = 0;
  // Status-strip state
  var cycleStartMs = 0;
  var elapsedTimer = null;
  var currentAgent = null;
  var currentTool = null;
  var currentTurn = 0;
  var currentMaxTurns = 0;
  var currentTokens = 0;

  // Tab switching
  var chatTabBtns = document.querySelectorAll('#tab-bar .tab-btn');
  var activityBadge = null;
  chatTabBtns.forEach(function(btn) {
    btn.addEventListener('click', function() {
      var tab = btn.getAttribute('data-tab');
      chatTabBtns.forEach(function(b) { b.classList.remove('active'); });
      document.querySelectorAll('.tab-content').forEach(function(c) { c.classList.remove('active'); });
      btn.classList.add('active');
      document.getElementById(tab + '-tab').classList.add('active');
      if (tab === 'activity' && activityBadge) {
        activityBadge.remove();
        activityBadge = null;
        activityCount = 0;
      }
    });
  });

  function isActivityTab() {
    var active = document.querySelector('#tab-bar .tab-btn.active');
    return active && active.getAttribute('data-tab') === 'activity';
  }

  function bumpActivityBadge() {
    if (isActivityTab()) return;
    activityCount++;
    var btn = document.querySelector('#tab-bar .tab-btn[data-tab=\"activity\"]');
    if (!activityBadge) {
      activityBadge = document.createElement('span');
      activityBadge.className = 'activity-badge';
      btn.appendChild(activityBadge);
    }
    activityBadge.textContent = activityCount > 99 ? '99+' : activityCount;
  }

  function isActivityNotification(name) {
    return name.indexOf('scheduler:') === 0 ||
           name.indexOf('reminder:') === 0 ||
           name.indexOf('planner:') === 0 ||
           name.indexOf('sandbox:') === 0 ||
           name.indexOf('email-inbound') !== -1 ||
           / (started|crashed|restarted|stopped)$/.test(name);
  }

  function addActivityItem(text) {
    activityEmpty.style.display = 'none';
    var el = document.createElement('div');
    el.className = 'activity-item';
    var time = new Date().toLocaleTimeString([], {hour:'2-digit',minute:'2-digit',second:'2-digit'});
    var category = 'system';
    if (text.indexOf('scheduler:') === 0 || text.indexOf('email-inbound') !== -1) category = 'scheduler';
    else if (text.indexOf('reminder:') === 0) category = 'reminder';
    else if (text.indexOf('planner:') === 0) category = 'planner';
    else if (text.indexOf('sandbox:') === 0) category = 'sandbox';
    el.innerHTML = '<span class=\"activity-time\">' + time + '</span>' +
      '<span class=\"activity-cat activity-cat-' + category + '\">' + category + '</span>' +
      '<span class=\"activity-text\">' + escapeHtml(text) + '</span>';
    activityMsgs.appendChild(el);
    activityMsgs.scrollTop = activityMsgs.scrollHeight;
    bumpActivityBadge();
  }

  marked.setOptions({ breaks: true, gfm: true });

  function renderMarkdown(text) {
    try { return marked.parse(text); }
    catch(e) { return escapeHtml(text); }
  }

  function saveChatHistory() {}

  // ── History sidebar ──────────────────────────────────────────────────
  // The narrative log is the source. Each day becomes an item in the
  // sidebar; click opens a read-only view of that day's entries. The live
  // chat session is never overwritten — the read-only view only replaces
  // the #messages area until the operator returns to live chat.
  var historyPanel = document.getElementById('history-panel');
  var historyToggle = document.getElementById('history-toggle');
  var historyList = document.getElementById('history-list');
  var historyEmpty = document.getElementById('history-empty');
  var historyLoading = document.getElementById('history-loading');
  var liveSnapshot = null;  // preserved chat when viewing history
  var viewingDate = null;

  if (historyToggle) {
    historyToggle.addEventListener('click', function() {
      var collapsed = historyPanel.classList.contains('collapsed');
      if (collapsed) {
        historyPanel.classList.remove('collapsed');
      } else {
        historyPanel.classList.add('collapsed');
      }
    });
  }

  function requestHistoryIndex() {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    historyLoading.classList.remove('hidden');
    ws.send(JSON.stringify({ type: 'request_history_index' }));
  }

  function renderHistoryIndex(days) {
    historyLoading.classList.add('hidden');
    historyList.innerHTML = '';
    historyList.dataset.loaded = '1';
    if (!days || days.length === 0) {
      historyEmpty.classList.remove('hidden');
      return;
    }
    historyEmpty.classList.add('hidden');
    days.forEach(function(d) {
      var btn = document.createElement('button');
      btn.className = 'history-day';
      btn.dataset.date = d.date;
      var dateEl = document.createElement('span');
      dateEl.className = 'date';
      dateEl.textContent = formatDateShort(d.date);
      btn.appendChild(dateEl);
      var countEl = document.createElement('span');
      countEl.className = 'count';
      countEl.textContent = d.cycle_count + ' ' + (d.cycle_count === 1 ? 'cycle' : 'cycles');
      btn.appendChild(countEl);
      if (d.headline) {
        var hl = document.createElement('span');
        hl.className = 'headline';
        hl.textContent = d.headline;
        hl.title = d.headline;
        btn.appendChild(hl);
      }
      btn.addEventListener('click', function() { loadHistoryDay(d.date, btn); });
      historyList.appendChild(btn);
    });
  }

  function loadHistoryDay(date, btn) {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    // Mark active
    Array.prototype.forEach.call(historyList.children, function(c) { c.classList.remove('active'); });
    if (btn) btn.classList.add('active');
    viewingDate = date;
    ws.send(JSON.stringify({ type: 'request_history_day', date: date }));
  }

  function renderHistoryDay(date, entries) {
    // Snapshot the live chat so incoming live messages don't mutate what we
    // restore. While viewingDate is truthy, live message handlers still
    // update chatHistory but skip DOM rendering. On close we rebuild
    // the #messages DOM from chatHistory — no window reload, no lost
    // agent replies arriving while the operator reads past cycles.
    liveSnapshot = chatHistory.slice();
    msgs.innerHTML = '';
    var header = document.createElement('div');
    header.className = 'history-day-header';
    var back = document.createElement('button');
    back.className = 'back-to-chat';
    back.setAttribute('aria-label', 'Return to live chat');
    back.innerHTML = '&larr; Back to live chat';
    back.addEventListener('click', returnToLiveChat);
    header.appendChild(back);
    var title = document.createElement('span');
    title.className = 'history-day-title';
    title.textContent = formatDateLong(date) + ' \\u00b7 ' + entries.length + ' ' + (entries.length === 1 ? 'cycle' : 'cycles') + ' \\u00b7 read-only';
    header.appendChild(title);
    msgs.appendChild(header);
    entries.forEach(function(e) {
      var entry = document.createElement('div');
      entry.className = 'history-entry';
      var ts = document.createElement('div');
      ts.className = 'ts';
      ts.textContent = formatTimestamp(e.timestamp);
      entry.appendChild(ts);
      var summary = document.createElement('div');
      summary.className = 'summary';
      summary.textContent = e.summary || '(no summary)';
      entry.appendChild(summary);
      var metaParts = [];
      if (e.intent && e.intent.domain) metaParts.push(e.intent.domain);
      if (e.outcome && e.outcome.status) metaParts.push(e.outcome.status);
      if (e.metrics && e.metrics.tool_calls) metaParts.push(e.metrics.tool_calls + ' tool calls');
      if (e.delegation_chain && e.delegation_chain.length) metaParts.push(e.delegation_chain.length + ' delegations');
      if (metaParts.length) {
        var meta = document.createElement('div');
        meta.className = 'meta';
        meta.textContent = metaParts.join(' \\u00b7 ');
        entry.appendChild(meta);
      }
      msgs.appendChild(entry);
    });
    scrollBottom();
  }

  function returnToLiveChat() {
    viewingDate = null;
    Array.prototype.forEach.call(historyList.children, function(c) { c.classList.remove('active'); });
    // Rebuild #messages from chatHistory which has been kept up-to-date
    // throughout (including any messages that arrived while reading
    // history). This preserves the agent's latest replies cleanly.
    msgs.innerHTML = '';
    chatHistory.forEach(function(item) {
      if (item.role === 'user') {
        if (item.text && item.text.indexOf('[Session started.') !== 0) {
          renderUserMessage(item.text);
        }
      } else if (item.role === 'assistant') {
        renderAssistantMessage(item.text, item.model || null, item.usage || null, item.revised || false);
      } else if (item.role === 'notification') {
        renderNotification(item.text);
      }
    });
    liveSnapshot = null;
    scrollBottom();
  }

  function formatDateShort(iso) {
    // iso is YYYY-MM-DD
    var parts = iso.split('-');
    if (parts.length !== 3) return iso;
    var today = new Date();
    var todayStr = today.getFullYear() + '-' + pad2(today.getMonth() + 1) + '-' + pad2(today.getDate());
    if (iso === todayStr) return 'Today';
    var yesterday = new Date(today.getTime() - 86400000);
    var yStr = yesterday.getFullYear() + '-' + pad2(yesterday.getMonth() + 1) + '-' + pad2(yesterday.getDate());
    if (iso === yStr) return 'Yesterday';
    var d = new Date(iso + 'T00:00:00');
    return d.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' });
  }

  function formatDateLong(iso) {
    var d = new Date(iso + 'T00:00:00');
    if (isNaN(d.getTime())) return iso;
    return d.toLocaleDateString(undefined, { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' });
  }

  function formatTimestamp(iso) {
    if (!iso) return '';
    var d = new Date(iso);
    if (isNaN(d.getTime())) return iso;
    return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  }

  function pad2(n) { return n < 10 ? '0' + n : '' + n; }

  function renderSessionHistory(messages) {
    msgs.innerHTML = '';
    chatHistory = [];
    if (!messages || messages.length === 0) return;
    var inSchedulerCycle = false;
    messages.forEach(function(item) {
      if (item.role === 'user') {
        var text = item.text || '';
        // Skip the synthetic bootstrap prompt the server sends to trigger
        // a session-opening greeting. It's a user-role message to the
        // cognitive loop, not something the operator typed.
        if (text.indexOf('[Session started.') === 0) {
          return;
        }
        if (text.indexOf('<scheduler_context>') === 0) {
          inSchedulerCycle = true;
          renderSchedulerMessage(text);
        } else if (text.trim()) {
          inSchedulerCycle = false;
          renderUserMessage(text);
        }
        chatHistory.push({ role: 'user', text: text });
      } else if (item.role === 'assistant') {
        if (inSchedulerCycle) {
          renderSchedulerResponse(item.text);
          inSchedulerCycle = false;
        } else {
          renderAssistantMessage(item.text, null, null, false);
        }
        chatHistory.push({ role: 'assistant', text: item.text });
      }
    });
    scrollBottom();
  }

  function renderSchedulerMessage(text) {
    var match = text.match(/<job_name>(.*?)<\\/job_name>/);
    var title = text.match(/<title>(.*?)<\\/title>/);
    var label = title ? title[1] : (match ? match[1] : 'Scheduler');
    addActivityItem('scheduler: ' + label);
  }

  function renderSchedulerResponse(text) {
    activityEmpty.style.display = 'none';
    var el = document.createElement('div');
    el.className = 'activity-response';
    var body = document.createElement('div');
    body.className = 'md-body';
    body.innerHTML = renderMarkdown(text);
    el.appendChild(body);
    activityMsgs.appendChild(el);
    activityMsgs.scrollTop = activityMsgs.scrollHeight;
    bumpActivityBadge();
  }

  " <> ws_connect_js() <> "

  function handleServerMessage(data) {
    switch (data.type) {
      case 'session_history':
        renderSessionHistory(data.messages);
        break;
      case 'history_index':
        renderHistoryIndex(data.days);
        break;
      case 'history_day':
        renderHistoryDay(data.date, data.entries);
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
          var nname = data.name || '';
          if (isActivityNotification(nname)) {
            addActivityItem(nname);
          } else {
            // Tool activity now surfaces in the live thinking card plus the
            // status strip instead of as inline chat notifications. The
            // card shows every tool as a step with arrow markers; the
            // strip shows the currently-active tool next to the agent name.
            // Posting a separate chat notification was double-counting.
            currentTool = nname;
            addThinkingStep(nname);
            updateStatusStrip();
          }
        } else if (data.kind === 'save_warning') {
          addNotification(data.message);
        } else if (data.kind === 'safety') {
          var badge = data.decision === 'ACCEPT' ? '\\u2705' : data.decision === 'REJECT' ? '\\u274C' : '\\u26A0\\uFE0F';
          addNotification(badge + ' D\\' ' + data.decision + ' (score: ' + data.score.toFixed(2) + ')');
          if (data.decision === 'MODIFY') wasRevised = true;
        } else if (data.kind === 'agent_progress') {
          currentAgent = data.agent_name;
          currentTurn = data.turn;
          currentMaxTurns = data.max_turns;
          currentTokens = data.tokens;
          currentTool = data.current_tool || currentTool;
          updateStatusStrip();
          addThinkingStep(data.agent_name + ' (turn ' + data.turn + '/' + data.max_turns + ')'
            + (data.current_tool ? ' \\u2192 ' + data.current_tool : ''));
        } else if (data.kind === 'status_transition') {
          statusStripLabel.textContent = humanizeStatus(data.status);
          if (data.detail) statusStripDetail.textContent = data.detail;
          applyStatusRhythm(data.status);
        } else if (data.kind === 'affect_tick') {
          applyAffectTick(data);
        }
        break;
    }
  }

  // Map the 5 affect dimensions + cognitive status to CSS custom properties
  // that drive the ambient background. Honest biometric mapping: hue shifts
  // with pressure, saturation with calm, opacity with confidence, and a red
  // tinge appears above a frustration threshold. Breathing rhythm reflects
  // whether the agent is idle or working.
  function applyAffectTick(d) {
    var root = document.documentElement;
    var pressure = typeof d.pressure === 'number' ? d.pressure : 0;
    var calm = typeof d.calm === 'number' ? d.calm : 75;
    var confidence = typeof d.confidence === 'number' ? d.confidence : 60;
    var frustration = typeof d.frustration === 'number' ? d.frustration : 0;
    // Hue: cool blue (220) -> magenta (320) as pressure climbs 0..100
    var hue = 220 + (pressure / 100) * 100;
    // Saturation: more calm = more saturated (deeper colour); grey when agitated
    var saturation = 20 + (calm / 100) * 60;
    // Opacity: more confident = slightly more visible. Range 0.06..0.14
    // Opacity range 0.15..0.30 — visible but not overwhelming
    var opacity = 0.15 + (confidence / 100) * 0.15;
    // Red accent shift when frustration exceeds 60; shift up to -40deg toward red
    var accent = frustration > 60 ? ((frustration - 60) / 40) * 40 : 0;
    root.style.setProperty('--affect-hue', hue + 'deg');
    root.style.setProperty('--affect-saturation', saturation + '%');
    root.style.setProperty('--affect-opacity', opacity.toFixed(3));
    root.style.setProperty('--affect-accent', accent + 'deg');
    applyStatusRhythm(d.status);
  }

  // Breathing rhythm reflects cognitive state:
  //   idle / waiting_for_user   -> 7s slow breath
  //   thinking / classifying    -> 2s faster
  //   waiting_for_agents        -> 3s
  //   evaluating_safety         -> 4s
  function applyStatusRhythm(status) {
    var duration;
    switch (status) {
      case 'thinking':
      case 'classifying':         duration = '2s'; break;
      case 'waiting_for_agents':  duration = '3s'; break;
      case 'evaluating_safety':   duration = '4s'; break;
      default:                    duration = '7s';
    }
    document.documentElement.style.setProperty('--breathing-duration', duration);
  }

  function humanizeStatus(s) {
    switch (s) {
      case 'idle': return 'Idle';
      case 'thinking': return 'Thinking';
      case 'classifying': return 'Classifying';
      case 'waiting_for_agents': return 'Delegating';
      case 'waiting_for_user': return 'Awaiting reply';
      case 'evaluating_safety': return 'Safety check';
      default: return s;
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
    if (!viewingDate) renderUserMessage(text);
    chatHistory.push({ role: 'user', text: text });
    saveChatHistory();
    if (!viewingDate) scrollBottom();
  }

  function addAssistantMessage(text, model, usage, revised) {
    if (!viewingDate) renderAssistantMessage(text, model, usage, revised);
    chatHistory.push({ role: 'assistant', text: text, model: model, usage: usage, revised: revised || false });
    saveChatHistory();
    if (!viewingDate) scrollBottom();
  }

  function addNotification(text) {
    if (!viewingDate) renderNotification(text);
    chatHistory.push({ role: 'notification', text: text });
    saveChatHistory();
    if (!viewingDate) scrollBottom();
  }

  function setThinkingLock(locked) {
    isThinking = locked;
  }

  function showThinking() {
    cycleStartMs = Date.now();
    startElapsedTimer();
    statusStrip.classList.remove('hidden');
    statusStripLabel.textContent = 'Thinking';
    statusStripDetail.textContent = '';
    statusStripMeta.textContent = '0s';
    if (thinkingEl) return;
    // Live status card — replaces the old three-dot bubble. Lists each step
    // as the cycle progresses: classify \\u2192 agent \\u2192 tool \\u2192 synthesize.
    thinkingEl = document.createElement('div');
    thinkingEl.className = 'thinking-card';
    thinkingSteps = document.createElement('ul');
    thinkingSteps.className = 'thinking-steps';
    thinkingEl.appendChild(thinkingSteps);
    msgs.appendChild(thinkingEl);
    // Seed a baseline step so simple LLM-only cycles (no tools, no delegation)
    // don't display an empty card. If tools/agents kick in later, real steps
    // replace the placeholder.
    addThinkingStep('thinking\\u2026');
    scrollBottom();
    setThinkingLock(true);
  }

  function addThinkingStep(text) {
    if (!thinkingSteps) return;
    // Dedup consecutive identical steps (tool calls often repeat with the same name)
    var last = thinkingSteps.lastElementChild;
    if (last && last.textContent === text) return;
    var li = document.createElement('li');
    li.textContent = text;
    thinkingSteps.appendChild(li);
    scrollBottom();
  }

  function removeThinking() {
    if (thinkingEl) { thinkingEl.remove(); thinkingEl = null; thinkingSteps = null; }
    statusStrip.classList.add('hidden');
    stopElapsedTimer();
    currentAgent = null;
    currentTool = null;
    currentTurn = 0;
    currentMaxTurns = 0;
    currentTokens = 0;
    setThinkingLock(false);
  }

  function startElapsedTimer() {
    stopElapsedTimer();
    elapsedTimer = setInterval(updateElapsed, 1000);
  }

  function stopElapsedTimer() {
    if (elapsedTimer) { clearInterval(elapsedTimer); elapsedTimer = null; }
  }

  function updateElapsed() {
    if (!cycleStartMs) return;
    var secs = Math.floor((Date.now() - cycleStartMs) / 1000);
    updateStatusStrip(secs);
  }

  function formatTokens(n) {
    if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
    return n + '';
  }

  function updateStatusStrip(secsOverride) {
    if (statusStrip.classList.contains('hidden')) return;
    var secs = typeof secsOverride === 'number'
      ? secsOverride
      : Math.floor((Date.now() - cycleStartMs) / 1000);
    var detail = '';
    if (currentAgent) {
      detail = currentAgent;
      if (currentTurn > 0 && currentMaxTurns > 0) {
        detail += ' \\u00b7 turn ' + currentTurn + '/' + currentMaxTurns;
      }
      if (currentTool) {
        detail += ' \\u00b7 ' + currentTool;
      }
    } else if (currentTool) {
      detail = currentTool;
    }
    statusStripDetail.textContent = detail;
    var meta = secs + 's';
    if (currentTokens > 0) {
      meta = formatTokens(currentTokens) + ' tokens \\u00b7 ' + meta;
    }
    statusStripMeta.textContent = meta;
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
<div id=\"ambient-layer\" aria-hidden=\"true\"></div>
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
  <button class=\"tab-btn\" data-tab=\"comms\">Comms</button>
  <button class=\"tab-btn\" data-tab=\"affect\">Affect</button>
</div>
<div id=\"content-area\">
  <div id=\"narrative-tab\" class=\"tab-content active\">
    <div class=\"filter-bar\">
      <button class=\"refresh-btn\" id=\"narrative-refresh\">Refresh</button>
      <select class=\"filter-select\" id=\"narrative-outcome-filter\"><option value=\"\">All Outcomes</option><option value=\"success\">Success</option><option value=\"failure\">Failure</option><option value=\"partial\">Partial</option></select>
      <input class=\"filter-input\" id=\"narrative-search\" type=\"text\" placeholder=\"Search entries...\">
      <span class=\"filter-count\" id=\"narrative-count\"></span>
    </div>
    <div id=\"narrative-container\"><div class=\"narrative-empty\">Loading narrative entries...</div></div>
  </div>
  <div id=\"log-tab\" class=\"tab-content\">
    <div class=\"filter-bar\">
      <button class=\"refresh-btn\" id=\"log-refresh\">Refresh</button>
      <select class=\"filter-select\" id=\"log-level-filter\"><option value=\"\">All Levels</option><option value=\"info\" selected>Info+</option><option value=\"warn\">Warn+</option><option value=\"error\">Error</option><option value=\"debug\">Debug</option></select>
      <input class=\"filter-input\" id=\"log-search\" type=\"text\" placeholder=\"Search logs...\">
      <span class=\"filter-count\" id=\"log-count\"></span>
    </div>
    <div id=\"log-container\">Loading...</div>
  </div>
  <div id=\"scheduler-tab\" class=\"tab-content\">
    <div class=\"filter-bar\">
      <button class=\"refresh-btn\" id=\"scheduler-refresh\">Refresh</button>
      <select class=\"filter-select\" id=\"scheduler-status-filter\"><option value=\"active\" selected>Active</option><option value=\"\">All Statuses</option><option value=\"pending\">Pending</option><option value=\"running\">Running</option><option value=\"completed\">Completed</option><option value=\"cancelled\">Cancelled</option><option value=\"failed\">Failed</option></select>
      <select class=\"filter-select\" id=\"scheduler-kind-filter\"><option value=\"\">All Kinds</option><option value=\"recurring_task\">Recurring</option><option value=\"reminder\">Reminder</option><option value=\"todo\">Todo</option><option value=\"appointment\">Appointment</option></select>
      <input class=\"filter-input\" id=\"scheduler-search\" type=\"text\" placeholder=\"Search jobs...\">
      <span class=\"filter-count\" id=\"scheduler-count\"></span>
    </div>
    <div id=\"scheduler-container\">
      <table class=\"admin-table\"><thead><tr>
        <th>Name</th><th>Kind</th><th>Status</th><th>Target</th><th>Due/Interval</th><th>Runs</th><th>Errors</th><th>Last Result</th>
      </tr></thead><tbody id=\"scheduler-body\"></tbody></table>
    </div>
  </div>
  <div id=\"cycles-tab\" class=\"tab-content\">
    <div class=\"filter-bar\">
      <button class=\"refresh-btn\" id=\"cycles-refresh\">Refresh</button>
      <select class=\"filter-select\" id=\"cycles-outcome-filter\"><option value=\"\">All Outcomes</option><option value=\"success\">Success</option><option value=\"pending\">Pending</option><option value=\"failure\">Failed</option></select>
      <input class=\"filter-input\" id=\"cycles-search\" type=\"text\" placeholder=\"Search cycles...\">
      <span class=\"filter-count\" id=\"cycles-count\"></span>
    </div>
    <div id=\"cycles-container\">
      <table class=\"admin-table\"><thead><tr>
        <th>Cycle ID</th><th>Time</th><th>Outcome</th><th>Model</th><th>Tools</th><th>Tokens</th><th>Duration</th>
      </tr></thead><tbody id=\"cycles-body\"></tbody></table>
    </div>
  </div>
  <div id=\"planner-tab\" class=\"tab-content\">
    <div class=\"filter-bar\">
      <button class=\"refresh-btn\" id=\"planner-refresh\">Refresh</button>
      <select class=\"filter-select\" id=\"planner-status-filter\"><option value=\"active\" selected>Active</option><option value=\"\">All Statuses</option><option value=\"pending\">Pending</option><option value=\"complete\">Complete</option><option value=\"failed\">Failed</option><option value=\"abandoned\">Abandoned</option></select>
      <input class=\"filter-input\" id=\"planner-search\" type=\"text\" placeholder=\"Search tasks...\">
      <span class=\"filter-count\" id=\"planner-count\"></span>
    </div>
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
    <div class=\"filter-bar\">
      <button class=\"refresh-btn\" id=\"dprime-refresh\">Refresh</button>
      <select class=\"filter-select\" id=\"dprime-decision-filter\"><option value=\"\">All Decisions</option><option value=\"ACCEPT\">Accept</option><option value=\"MODIFY\">Modify</option><option value=\"REJECT\">Reject</option><option value=\"ABORT\">Abort</option></select>
      <select class=\"filter-select\" id=\"dprime-gate-filter\"><option value=\"\">All Gates</option><option value=\"input\">Input</option><option value=\"tool\">Tool</option><option value=\"output\">Output</option></select>
      <input class=\"filter-input\" id=\"dprime-search\" type=\"text\" placeholder=\"Search gates...\">
      <span class=\"filter-count\" id=\"dprime-count\"></span>
    </div>
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
  <div id=\"comms-tab\" class=\"tab-content\">
    <div class=\"filter-bar\">
      <button class=\"refresh-btn\" id=\"comms-refresh\">Refresh</button>
      <select class=\"filter-select\" id=\"comms-direction-filter\"><option value=\"\">All Directions</option><option value=\"outbound\">Outbound</option><option value=\"inbound\">Inbound</option></select>
      <input class=\"filter-input\" id=\"comms-search\" type=\"text\" placeholder=\"Search messages...\">
      <span class=\"filter-count\" id=\"comms-count\"></span>
    </div>
    <div id=\"comms-container\"><table class=\"admin-table\"><thead><tr><th>Time</th><th>Dir</th><th>From</th><th>To</th><th>Subject</th><th>Status</th></tr></thead><tbody id=\"comms-body\"><tr><td colspan=\"6\" style=\"text-align:center;opacity:.5\">Loading...</td></tr></tbody></table></div>
  </div>
  <div id=\"affect-tab\" class=\"tab-content\">
    <div class=\"filter-bar\">
      <button class=\"refresh-btn\" id=\"affect-refresh\">Refresh</button>
      <input class=\"filter-input\" id=\"affect-search\" type=\"text\" placeholder=\"Search affect...\">
      <span class=\"filter-count\" id=\"affect-count\"></span>
    </div>
    <div id=\"affect-container\">
      <table class=\"admin-table\"><thead><tr>
        <th>Cycle</th><th>Time</th><th>Desperation</th><th>Calm</th><th>Confidence</th><th>Frustration</th><th>Pressure</th><th>Trend</th>
      </tr></thead><tbody id=\"affect-body\"></tbody></table>
    </div>
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
  var schedulerJobsRaw = [];
  var cyclesRaw = [];
  var logEntriesRaw = [];
  var narrativeEntriesRaw = [];
  var plannerTasksRaw = [];
  var plannerEndeavoursRaw = [];
  var dprimeGatesRaw = [];
  var commsMessagesRaw = [];
  var affectDataRaw = [];

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
      else if (tab === 'comms') requestCommsData();
      else if (tab === 'affect') requestAffectData();
    });
  });

  document.getElementById('log-refresh').addEventListener('click', requestLogData);
  document.getElementById('narrative-refresh').addEventListener('click', requestNarrativeData);
  document.getElementById('scheduler-refresh').addEventListener('click', requestSchedulerData);
  document.getElementById('cycles-refresh').addEventListener('click', requestSchedulerCycles);
  document.getElementById('planner-refresh').addEventListener('click', requestPlannerData);
  document.getElementById('dprime-refresh').addEventListener('click', requestDprimeData);
  document.getElementById('dprime-config-refresh').addEventListener('click', requestDprimeConfig);
  document.getElementById('comms-refresh').addEventListener('click', requestCommsData);
  document.getElementById('affect-refresh').addEventListener('click', requestAffectData);

  // Filter event listeners
  ['change'].forEach(function(ev) {
    document.getElementById('scheduler-status-filter').addEventListener(ev, applySchedulerFilter);
    document.getElementById('scheduler-kind-filter').addEventListener(ev, applySchedulerFilter);
    document.getElementById('cycles-outcome-filter').addEventListener(ev, applyCyclesFilter);
    document.getElementById('log-level-filter').addEventListener(ev, applyLogFilter);
    document.getElementById('narrative-outcome-filter').addEventListener(ev, applyNarrativeFilter);
    document.getElementById('planner-status-filter').addEventListener(ev, applyPlannerFilter);
    document.getElementById('dprime-decision-filter').addEventListener(ev, applyDprimeFilter);
    document.getElementById('dprime-gate-filter').addEventListener(ev, applyDprimeFilter);
    document.getElementById('comms-direction-filter').addEventListener(ev, applyCommsFilter);
  });
  ['input'].forEach(function(ev) {
    document.getElementById('affect-search').addEventListener(ev, applyAffectFilter);
    document.getElementById('scheduler-search').addEventListener(ev, applySchedulerFilter);
    document.getElementById('cycles-search').addEventListener(ev, applyCyclesFilter);
    document.getElementById('log-search').addEventListener(ev, applyLogFilter);
    document.getElementById('narrative-search').addEventListener(ev, applyNarrativeFilter);
    document.getElementById('planner-search').addEventListener(ev, applyPlannerFilter);
    document.getElementById('dprime-search').addEventListener(ev, applyDprimeFilter);
    document.getElementById('comms-search').addEventListener(ev, applyCommsFilter);
  });

  function filterCount(id, shown, total) {
    var el = document.getElementById(id);
    if (el) el.textContent = shown === total ? '' : shown + ' of ' + total;
  }

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

  function requestCommsData() {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'request_comms_data' }));
    }
  }

  function requestAffectData() {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'request_affect_data' }));
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
    dprimeGatesRaw = (gates || []).slice().reverse();
    applyDprimeFilter();
  }

  function applyDprimeFilter() {
    var decVal = document.getElementById('dprime-decision-filter').value;
    var gateVal = document.getElementById('dprime-gate-filter').value;
    var q = document.getElementById('dprime-search').value.toLowerCase();
    var filtered = dprimeGatesRaw.filter(function(g) {
      if (decVal && g.decision.toUpperCase() !== decVal) return false;
      if (gateVal && g.gate !== gateVal) return false;
      if (q) { var h = [g.cycle_id,g.node_type,g.gate,g.decision].join(' ').toLowerCase(); if (h.indexOf(q)===-1) return false; }
      return true;
    });
    filterCount('dprime-count', filtered.length, dprimeGatesRaw.length);
    var body = document.getElementById('dprime-body');
    if (filtered.length === 0) {
      body.innerHTML = '<tr><td colspan=\"6\" style=\"text-align:center;opacity:.5\">'+(dprimeGatesRaw.length===0?'No D\\' gate decisions today':'No gates match filter')+'</td></tr>';
      return;
    }
    body.innerHTML = filtered.map(function(g) {
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

  function renderCommsMessages(messages) {
    commsMessagesRaw = messages || [];
    applyCommsFilter();
  }

  function applyCommsFilter() {
    var dirVal = document.getElementById('comms-direction-filter').value;
    var q = document.getElementById('comms-search').value.toLowerCase();
    var filtered = commsMessagesRaw.filter(function(m) {
      if (dirVal && m.direction !== dirVal) return false;
      if (q) { var h = [m.from,m.to,m.subject,m.status].join(' ').toLowerCase(); if (h.indexOf(q)===-1) return false; }
      return true;
    });
    filterCount('comms-count', filtered.length, commsMessagesRaw.length);
    var body = document.getElementById('comms-body');
    if (filtered.length === 0) {
      body.innerHTML = '<tr><td colspan=\"6\" style=\"text-align:center;opacity:.5\">'+(commsMessagesRaw.length===0?'No messages':'No messages match filter')+'</td></tr>';
      return;
    }
    body.innerHTML = filtered.map(function(m) {
      var time = (m.timestamp || '').substring(0, 16).replace('T', ' ');
      var dir = m.direction === 'outbound' ? '&#8599;' : '&#8601;';
      var dirColor = m.direction === 'outbound' ? '#248a3d' : '#007aff';
      var statusColor = m.status === 'sent' || m.status === 'delivered' ? '#248a3d' : m.status === 'pending' ? '#c77c00' : '#d70015';
      return '<tr>' +
        '<td style=\"white-space:nowrap\">' + escapeHtml(time) + '</td>' +
        '<td style=\"color:' + dirColor + ';font-size:1.2em;text-align:center\">' + dir + '</td>' +
        '<td>' + escapeHtml(m.from || '') + '</td>' +
        '<td>' + escapeHtml(m.to || '') + '</td>' +
        '<td>' + escapeHtml(m.subject || '') + '</td>' +
        '<td style=\"color:' + statusColor + '\">' + escapeHtml(m.status || '') + '</td>' +
        '</tr>';
    }).join('');
  }

  function renderAffectData(snapshots) {
    affectDataRaw = (snapshots || []).slice().reverse();
    applyAffectFilter();
  }

  function applyAffectFilter() {
    var q = document.getElementById('affect-search').value.toLowerCase();
    var filtered = affectDataRaw.filter(function(s) {
      if (q) { var h = [s.cycle_id,s.timestamp,s.trend].join(' ').toLowerCase(); if (h.indexOf(q)===-1) return false; }
      return true;
    });
    filterCount('affect-count', filtered.length, affectDataRaw.length);
    var body = document.getElementById('affect-body');
    if (filtered.length === 0) {
      body.innerHTML = '<tr><td colspan=\"8\" style=\"text-align:center;opacity:.5\">'+(affectDataRaw.length===0?'No affect data yet':'No data matches filter')+'</td></tr>';
      return;
    }
    body.innerHTML = filtered.map(function(s) {
      return '<tr>' +
        '<td>' + (s.cycle_id || '').substring(0,8) + '</td>' +
        '<td>' + (s.timestamp || '').substring(0,19).replace('T',' ') + '</td>' +
        '<td style=\"color:' + affectColor(s.desperation) + '\">' + Math.round(s.desperation) + '%</td>' +
        '<td style=\"color:' + affectColor(100-s.calm) + '\">' + Math.round(s.calm) + '%</td>' +
        '<td style=\"color:' + affectColor(100-s.confidence) + '\">' + Math.round(s.confidence) + '%</td>' +
        '<td style=\"color:' + affectColor(s.frustration) + '\">' + Math.round(s.frustration) + '%</td>' +
        '<td style=\"color:' + affectColor(s.pressure) + ';font-weight:600\">' + Math.round(s.pressure) + '%</td>' +
        '<td>' + (s.trend === 'rising' ? '\\u2191' : s.trend === 'falling' ? '\\u2193' : '\\u2194') + '</td>' +
        '</tr>';
    }).join('');
  }

  function affectColor(v) {
    if (v < 30) return '#248a3d';
    if (v <= 60) return '#c77c00';
    return '#d70015';
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
      var mode = gateName === 'input' ? ' | Fast-accept (canary + deterministic only)' : '';
      html += '<div class=\"dprime-config-gate\">';
      html += '<h3 class=\"dprime-gate-title\"><span class=\"dprime-gate-badge dprime-gate-' + gateName + '\">' + gateName + '</span> gate';
      html += '<span class=\"dprime-thresholds\">modify: ' + (gate.modify_threshold || '?') + ' | reject: ' + (gate.reject_threshold || '?') + ' | ' + canary + mode + '</span></h3>';
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

    // Normative calculus
    var nc = config.normative_calculus;
    if (nc) {
      html += '<div class=\"dprime-config-gate\"><h3 class=\"dprime-gate-title\">Normative Calculus</h3>';
      html += '<div style=\"font-size:13px;line-height:1.8;padding:8px 0\">';
      html += '<span style=\"opacity:.6\">Enabled:</span> ' + (nc.enabled ? '\\u2705' : '\\u274c') + ' &nbsp;';
      html += '<span style=\"opacity:.6\">Character spec:</span> ' + (nc.character_loaded ? '\\u2705 loaded' : '\\u274c not found') + ' &nbsp;';
      if (nc.virtue_count) html += '<span style=\"opacity:.6\">Virtues:</span> ' + nc.virtue_count + ' &nbsp;';
      if (nc.endeavour_count) html += '<span style=\"opacity:.6\">Highest endeavour NPs:</span> ' + nc.endeavour_count + ' &nbsp;';
      html += '<span style=\"opacity:.6\">Output gate min length:</span> 300 chars';
      html += '</div>';
      if (nc.endeavours && nc.endeavours.length > 0) {
        html += '<table class=\"admin-table\"><thead><tr><th>Level</th><th>Operator</th><th>Description</th></tr></thead><tbody>';
        nc.endeavours.forEach(function(np) {
          var opColor = np.operator === 'required' ? '#d70015' : np.operator === 'ought' ? '#c77c00' : '#248a3d';
          html += '<tr><td>' + escapeHtml(np.level) + '</td>';
          html += '<td style=\"color:' + opColor + ';font-weight:600\">' + np.operator + '</td>';
          html += '<td>' + escapeHtml(np.description) + '</td></tr>';
        });
        html += '</tbody></table>';
      }
      html += '</div>';
    }

    container.innerHTML = html || '<div style=\"opacity:.5;padding:20px\">No D\\' configuration loaded</div>';
  }

  function renderSchedulerJobs(jobs) {
    schedulerJobsRaw = jobs || [];
    applySchedulerFilter();
  }

  function applySchedulerFilter() {
    var statusVal = document.getElementById('scheduler-status-filter').value;
    var kindVal = document.getElementById('scheduler-kind-filter').value;
    var q = document.getElementById('scheduler-search').value.toLowerCase();
    var filtered = schedulerJobsRaw.filter(function(j) {
      if (statusVal === 'active') { if (j.status === 'completed' || j.status === 'cancelled') return false; }
      else if (statusVal && j.status !== statusVal) return false;
      if (kindVal && j.kind !== kindVal) return false;
      if (q) { var h = [j.name,j.title,j['for'],j.last_result,(j.tags||[]).join(' ')].join(' ').toLowerCase(); if (h.indexOf(q)===-1) return false; }
      return true;
    });
    filterCount('scheduler-count', filtered.length, schedulerJobsRaw.length);
    var body = document.getElementById('scheduler-body');
    if (filtered.length === 0) { body.innerHTML = '<tr><td colspan=\"8\" style=\"text-align:center;opacity:.5\">'+(schedulerJobsRaw.length===0?'No scheduled jobs':'No jobs match filter')+'</td></tr>'; return; }
    body.innerHTML = filtered.map(function(j) {
      var due = j.due_at ? j.due_at : (j.interval_ms > 0 ? (j.interval_ms/1000)+'s' : '-');
      var lr = j.last_result ? j.last_result.substring(0,80) : '-';
      return '<tr><td>'+escapeHtml(j.name)+'</td><td>'+j.kind+'</td><td>'+j.status+'</td><td>'+(j['for']||'-')+'</td><td>'+due+'</td><td>'+j.run_count+'</td><td>'+j.error_count+'</td><td style=\"max-width:200px;overflow:hidden;text-overflow:ellipsis\">'+escapeHtml(lr)+'</td></tr>';
    }).join('');
  }

  function renderSchedulerCycles(cycles) {
    cyclesRaw = (cycles || []).slice().reverse();
    applyCyclesFilter();
  }

  function applyCyclesFilter() {
    var outcomeVal = document.getElementById('cycles-outcome-filter').value;
    var q = document.getElementById('cycles-search').value.toLowerCase();
    var filtered = cyclesRaw.filter(function(c) {
      if (outcomeVal) {
        if (outcomeVal === 'failure') { if (c.outcome === 'success' || c.outcome === 'pending') return false; }
        else if (c.outcome !== outcomeVal) return false;
      }
      if (q) { var h = [c.cycle_id,c.model,c.outcome,c.timestamp].join(' ').toLowerCase(); if (h.indexOf(q)===-1) return false; }
      return true;
    });
    filterCount('cycles-count', filtered.length, cyclesRaw.length);
    var body = document.getElementById('cycles-body');
    if (filtered.length === 0) { body.innerHTML = '<tr><td colspan=\"7\" style=\"text-align:center;opacity:.5\">'+(cyclesRaw.length===0?'No scheduler cycles today':'No cycles match filter')+'</td></tr>'; return; }
    body.innerHTML = filtered.map(function(c) {
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
    plannerTasksRaw = tasks || [];
    plannerEndeavoursRaw = endeavours || [];
    applyPlannerFilter();
  }

  function applyPlannerFilter() {
    var statusVal = document.getElementById('planner-status-filter').value;
    var q = document.getElementById('planner-search').value.toLowerCase();

    // Filter endeavours
    var eList = document.getElementById('endeavours-list');
    var filteredEnds = plannerEndeavoursRaw.filter(function(e) {
      if (statusVal === 'active') { if (e.status === 'complete' || e.status === 'abandoned') return false; }
      else if (statusVal && e.status !== statusVal) return false;
      if (q) { var h = [e.title,e.description||''].join(' ').toLowerCase(); if (h.indexOf(q)===-1) return false; }
      return true;
    });
    if (filteredEnds.length === 0) {
      eList.innerHTML = '<div class=\"narrative-empty\">'+(plannerEndeavoursRaw.length===0?'No endeavours yet.':'No endeavours match filter')+'</div>';
    } else {
      eList.innerHTML = filteredEnds.map(function(e) {
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

    // Filter tasks
    var filteredTasks = plannerTasksRaw.filter(function(t) {
      if (statusVal === 'active') { if (t.status === 'complete' || t.status === 'abandoned' || t.status === 'failed') return false; }
      else if (statusVal && t.status !== statusVal) return false;
      if (q) { var h = [t.task_id,t.title,t.status,t.complexity].join(' ').toLowerCase(); if (h.indexOf(q)===-1) return false; }
      return true;
    });
    filterCount('planner-count', filteredTasks.length + filteredEnds.length, plannerTasksRaw.length + plannerEndeavoursRaw.length);
    var body = document.getElementById('planner-body');
    if (filteredTasks.length === 0) {
      body.innerHTML = '<tr><td colspan=\"7\" style=\"text-align:center;opacity:.5\">'+(plannerTasksRaw.length===0?'No active tasks':'No tasks match filter')+'</td></tr>';
    } else {
      body.innerHTML = filteredTasks.map(function(t) {
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
    narrativeEntriesRaw = entries || [];
    applyNarrativeFilter();
  }

  function applyNarrativeFilter() {
    var outcomeVal = document.getElementById('narrative-outcome-filter').value;
    var q = document.getElementById('narrative-search').value.toLowerCase();
    var sorted = narrativeEntriesRaw.slice().reverse();
    var filtered = sorted.filter(function(e) {
      var st = (e.outcome && e.outcome.status) || 'unknown';
      if (outcomeVal && st !== outcomeVal) return false;
      if (q) { var h = [e.summary||'',(e.keywords||[]).join(' '),e.intent||''].join(' ').toLowerCase(); if (h.indexOf(q)===-1) return false; }
      return true;
    });
    filterCount('narrative-count', filtered.length, narrativeEntriesRaw.length);
    if (filtered.length === 0) {
      narrativeContainer.innerHTML = '<div class=\"narrative-empty\">'+(narrativeEntriesRaw.length===0?'No narrative entries yet. Entries appear after conversations.':'No entries match filter')+'</div>';
      return;
    }
    var html = '';
    filtered.forEach(function(e) {
      try {
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
      } catch(err) {
        html += '<div class=\"narrative-entry\" style=\"opacity:.5\">Error rendering entry ' + (e.cycle_id || '?') + ': ' + err.message + '</div>';
      }
    });
    narrativeContainer.innerHTML = html;
  }

  var logLevelRank = { debug: 0, info: 1, warn: 2, error: 3 };

  function renderLogEntries(entries) {
    logEntriesRaw = entries || [];
    applyLogFilter();
  }

  function applyLogFilter() {
    var levelVal = document.getElementById('log-level-filter').value;
    var q = document.getElementById('log-search').value.toLowerCase();
    var minRank = logLevelRank[levelVal] || 0;
    var filtered = logEntriesRaw.filter(function(e) {
      var lvl = e.level || 'debug';
      if (levelVal && levelVal !== 'debug') { if ((logLevelRank[lvl] || 0) < minRank) return false; }
      if (q) { var h = [e.module,e.function,e.message,e.cycle_id||''].join(' ').toLowerCase(); if (h.indexOf(q)===-1) return false; }
      return true;
    });
    filterCount('log-count', filtered.length, logEntriesRaw.length);
    if (filtered.length === 0) {
      logContainer.innerHTML = '<div style=\"color:var(--text-dim);padding:20px;\">'+(logEntriesRaw.length===0?'No log entries today.':'No log entries match filter')+'</div>';
      return;
    }
    var html = '';
    filtered.forEach(function(e) {
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
      case 'comms_data':
        renderCommsMessages(data.messages);
        break;
      case 'affect_data':
        renderAffectData(data.snapshots);
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
    /* ── Affect-driven ambient variables ──────────────
       Driven by AffectTick notifications. JS sets these on arrival
       and CSS transitions smooth the change. Defaults mimic a calm,
       confident baseline so the background renders cleanly even
       before the first affect reading arrives. */
    --affect-hue: 220deg;         /* cool blue default */
    --affect-saturation: 40%;
    --affect-lightness: 55%;
    --affect-opacity: 0.22;
    --affect-accent: 0%;          /* red tinge for frustration spikes */
    --breathing-duration: 7s;     /* idle rhythm */
  }
  html {
    background: var(--bg);
  }
  body {
    font-family: 'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, 'Book Antiqua', serif;
    background: transparent;
    color: var(--text);
    height: 100vh;
    margin: 0;
    font-size: 17px;
    position: relative;
    z-index: 0;
  }

  /* ── Ambient affect layer ────────────────────────
     Fixed-position gradient wash driven by live affect telemetry.
     Sits behind all content but above the base bg. Honest biometric
     signal — the hue shifts as Curragh's interior state shifts.
     Respects reduced-motion. */
  #ambient-layer {
    position: fixed;
    inset: 0;
    z-index: 0;
    pointer-events: none;
    background:
      radial-gradient(
        ellipse 80% 60% at 30% 20%,
        hsla(
          calc(var(--affect-hue) - var(--affect-accent)),
          var(--affect-saturation),
          var(--affect-lightness),
          var(--affect-opacity)
        ) 0%,
        transparent 60%
      ),
      radial-gradient(
        ellipse 70% 70% at 70% 80%,
        hsla(
          calc(var(--affect-hue) + 20deg),
          var(--affect-saturation),
          calc(var(--affect-lightness) + 5%),
          calc(var(--affect-opacity) * 0.7)
        ) 0%,
        transparent 55%
      );
    animation: affect-breathe var(--breathing-duration) ease-in-out infinite;
    transition:
      --affect-hue 3s ease,
      --affect-saturation 3s ease,
      --affect-lightness 3s ease,
      --affect-opacity 3s ease,
      --affect-accent 3s ease,
      --breathing-duration 1.5s ease;
  }
  @keyframes affect-breathe {
    0%, 100% { opacity: 0.85; }
    50%      { opacity: 1.0; }
  }
  @media (prefers-reduced-motion: reduce) {
    #ambient-layer {
      animation: none;
      transition: none;
    }
  }

  /* ── Layout ──────────────────────────────────────── */
  #layout {
    display: flex;
    height: 100vh;
    position: relative;
    z-index: 1;
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
  .msg.scheduler {
    background: var(--code-bg);
    border: 1px solid var(--border);
    align-self: flex-start;
    border-radius: 12px;
    font-size: 13px;
    color: var(--text-secondary);
  }
  .scheduler-badge {
    display: inline-block;
    font-size: 11px;
    font-weight: 600;
    color: #007aff;
    letter-spacing: 0.02em;
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
  #activity-messages {
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding: 12px 0;
    overflow-y: auto;
    flex: 1;
  }
  .activity-item {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 12px;
    font-size: 13px;
    border-bottom: 1px solid var(--border);
  }
  .activity-time {
    color: var(--text-dim);
    font-family: monospace;
    font-size: 12px;
    flex-shrink: 0;
  }
  .activity-cat {
    font-size: 11px;
    font-weight: 600;
    padding: 1px 6px;
    border-radius: 3px;
    text-transform: uppercase;
    flex-shrink: 0;
  }
  .activity-cat-scheduler { background: #1a3a5c; color: #6cb4ee; }
  .activity-cat-reminder { background: #3a3520; color: #e0c050; }
  .activity-cat-planner { background: #1a3c2a; color: #50c878; }
  .activity-cat-sandbox { background: #3a2040; color: #c080e0; }
  .activity-cat-system { background: #2a2a2a; color: #999; }
  .activity-text {
    color: var(--text-secondary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .activity-response {
    padding: 8px 12px;
    margin: 2px 0;
    font-size: 14px;
    color: var(--text-primary);
    border-left: 3px solid var(--accent);
    background: var(--bg-secondary);
    border-radius: 0 4px 4px 0;
  }
  .activity-response .md-body { font-size: 14px; }
  .activity-badge {
    display: inline-block;
    background: var(--accent);
    color: #fff;
    font-size: 10px;
    font-weight: 700;
    min-width: 16px;
    height: 16px;
    line-height: 16px;
    text-align: center;
    border-radius: 8px;
    padding: 0 4px;
    margin-left: 6px;
    vertical-align: middle;
  }
  .thinking-card {
    align-self: flex-start;
    padding: 8px 0;
    color: var(--text-dim);
    font-size: 14px;
    max-width: 100%;
  }
  .thinking-card .thinking-steps {
    list-style: none;
    padding: 0;
    margin: 0;
  }
  .thinking-card .thinking-steps li {
    padding: 2px 0 2px 18px;
    position: relative;
    font-variant-numeric: tabular-nums;
    line-height: 1.5;
    animation: step-fade-in 0.2s ease-out;
  }
  .thinking-card .thinking-steps li::before {
    content: \"\\2192\";
    position: absolute;
    left: 0;
    color: var(--text-dim);
    opacity: 0.45;
  }
  .thinking-card .thinking-steps li:last-child {
    color: var(--text);
  }
  .thinking-card .thinking-steps li:last-child::before {
    opacity: 0.9;
    animation: step-pulse 1.4s infinite ease-in-out;
  }
  @keyframes step-fade-in {
    from { opacity: 0; transform: translateY(-2px); }
    to   { opacity: 1; transform: translateY(0); }
  }
  @keyframes step-pulse {
    0%, 100% { opacity: 0.35; }
    50%      { opacity: 0.9; }
  }
  @media (prefers-reduced-motion: reduce) {
    .thinking-card .thinking-steps li { animation: none; }
    .thinking-card .thinking-steps li:last-child::before { animation: none; opacity: 0.9; }
  }

  /* ── Status strip ───────────────────────────────── */
  /* Lives at the top of the chat tab. Shows current cognitive-loop state,
     active agent, tool, and elapsed time. Replaces the old overlay that
     blocked the entire chat tab behind a grey wash. */
  #status-strip {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 8px 14px;
    border-bottom: 1px solid var(--border);
    background: var(--bg);
    font-size: 13px;
    font-variant-numeric: tabular-nums;
    color: var(--text-dim);
    flex-shrink: 0;
    transition: opacity 0.2s;
  }
  #status-strip.hidden {
    display: none;
  }
  #status-strip .status-label {
    font-weight: 600;
    color: var(--text);
    letter-spacing: 0.02em;
  }
  #status-strip .status-detail {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  #status-strip .status-meta {
    color: var(--text-dim);
    font-size: 12px;
    flex-shrink: 0;
  }
  @media (prefers-reduced-motion: reduce) {
    #status-strip { transition: none; }
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

  /* ── Chat history panel — sits at #layout level between the outer
     nav sidebar and #main-content. Modern chat-app positioning:
     far-left is app nav, next column is conversation history, main
     area is the current chat. */
  #history-panel {
    width: 260px;
    flex-shrink: 0;
    border-right: 1px solid var(--border);
    background: var(--bg);
    display: flex;
    flex-direction: column;
    overflow: hidden;
    transition: width 0.2s ease;
    height: 100vh;
  }
  #history-panel.collapsed {
    width: 44px;
  }
  #history-panel.collapsed #history-title,
  #history-panel.collapsed .history-day,
  #history-panel.collapsed #history-empty,
  #history-panel.collapsed #history-loading,
  #history-panel.collapsed #history-list {
    display: none;
  }
  #history-header {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 12px 10px;
    border-bottom: 1px solid var(--border);
    flex-shrink: 0;
  }
  #history-toggle {
    background: transparent;
    border: none;
    cursor: pointer;
    padding: 4px 6px;
    font-size: 16px;
    color: var(--text-dim);
    border-radius: 6px;
  }
  #history-toggle:hover {
    background: var(--border);
    color: var(--text);
  }
  #history-title {
    font-size: 13px;
    font-weight: 600;
    letter-spacing: 0.02em;
    color: var(--text);
    text-transform: uppercase;
  }
  #history-list {
    flex: 1;
    overflow-y: auto;
    padding: 6px 0;
    scrollbar-width: thin;
  }
  #history-list::-webkit-scrollbar { width: 6px; }
  #history-list::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
  .history-day {
    display: block;
    width: 100%;
    text-align: left;
    background: transparent;
    border: none;
    cursor: pointer;
    padding: 10px 14px;
    border-bottom: 1px solid transparent;
    transition: background 0.15s;
    color: var(--text);
  }
  .history-day:hover {
    background: var(--border);
  }
  .history-day.active {
    background: var(--accent-light);
    border-bottom-color: var(--border);
  }
  .history-day .date {
    font-size: 13px;
    font-weight: 600;
    color: var(--text);
    display: block;
    margin-bottom: 3px;
  }
  .history-day .count {
    font-size: 11px;
    color: var(--text-dim);
    display: inline;
    margin-right: 6px;
  }
  .history-day .headline {
    font-size: 12px;
    color: var(--text-dim);
    display: block;
    margin-top: 3px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    line-height: 1.4;
  }
  #history-empty, #history-loading {
    padding: 16px 14px;
    font-size: 13px;
    color: var(--text-dim);
  }
  .hidden { display: none !important; }

  /* Read-only history day view (rendered inline in #messages) */
  .history-day-header {
    padding: 14px 16px;
    margin-bottom: 8px;
    border-radius: var(--radius-sm);
    background: var(--accent-light);
    color: var(--text);
    font-size: 14px;
    display: flex;
    align-items: center;
    gap: 14px;
  }
  .history-day-header .back-to-chat {
    background: var(--surface);
    border: 1px solid var(--border);
    color: var(--text);
    font-family: inherit;
    font-size: 13px;
    cursor: pointer;
    padding: 6px 12px;
    border-radius: var(--radius-sm);
    transition: background 0.15s, border-color 0.15s;
  }
  .history-day-header .back-to-chat:hover {
    background: var(--bg);
    border-color: var(--border-hover);
  }
  .history-day-header .history-day-title {
    flex: 1;
    color: var(--text-secondary);
  }
  .history-entry {
    padding: 12px 16px;
    border-left: 2px solid var(--border);
    margin: 8px 0;
    background: var(--surface);
    border-radius: var(--radius-sm);
    font-size: 14px;
  }
  .history-entry .ts {
    font-size: 11px;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
    margin-bottom: 4px;
  }
  .history-entry .summary {
    color: var(--text);
    line-height: 1.5;
  }
  .history-entry .meta {
    margin-top: 6px;
    font-size: 11px;
    color: var(--text-dim);
  }

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
  .filter-bar { display:flex; align-items:center; gap:8px; padding:12px 0; flex-wrap:wrap; }
  .filter-select { padding:6px 10px; border:1px solid var(--border); border-radius:8px; background:var(--surface); font-family:inherit; font-size:13px; color:var(--text-secondary); cursor:pointer; }
  .filter-select:hover { background:var(--code-bg); }
  .filter-input { padding:6px 10px; border:1px solid var(--border); border-radius:8px; background:var(--surface); font-family:inherit; font-size:13px; color:var(--text); min-width:160px; }
  .filter-input::placeholder { color:var(--text-dim); }
  .filter-input:focus { outline:none; border-color:var(--accent); }
  .filter-count { font-size:11px; color:var(--text-dim); margin-left:4px; }

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
      // Load the chat-history index for the sidebar. Harmless on the
      // admin page — the handler on that page ignores history_index.
      if (typeof requestHistoryIndex === 'function') requestHistoryIndex();
      // Load data for the default active tab on connect
      var activeTab = document.querySelector('.tab-btn.active');
      if (activeTab) {
        var tab = activeTab.getAttribute('data-tab');
        if (tab === 'narrative') requestNarrativeData();
        else if (tab === 'log') requestLogData();
        else if (tab === 'scheduler') requestSchedulerData();
        else if (tab === 'cycles') requestSchedulerCycles();
        else if (tab === 'planner') requestPlannerData();
        else if (tab === 'dprime') requestDprimeData();
        else if (tab === 'dprime-config') requestDprimeConfig();
      }
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
      try { data = JSON.parse(evt.data); } catch(e) { console.error('WS parse error:', e.message, 'data length:', evt.data.length); return; }
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
