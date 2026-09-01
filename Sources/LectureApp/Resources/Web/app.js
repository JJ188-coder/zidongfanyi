(function () {
  "use strict";

  const token = new URLSearchParams(location.search).get("token") || sessionStorage.getItem("lecture.token") || "";
  if (token) sessionStorage.setItem("lecture.token", token);
  const state = {
    route: location.hash.slice(1) || "live",
    courses: [], lectures: [], currentCourseID: null, currentLectureID: null,
    runtime: { recording: false, duration: 0, audioLevel: 0, volatileEnglish: "", volatileChinese: "", deepSeekConfigured: false },
    detail: null, chat: [], qaScope: "course", connected: false, pendingAudioTime: null,
    storage: { totalBytes: 0, recordingBytes: 0, databaseBytes: 0, exportBytes: 0, recordingCount: 0 }
  };
  const main = document.getElementById("app-main");
  const breadcrumb = document.getElementById("breadcrumb");
  const modeNote = document.getElementById("mode-note");

  async function api(path, options = {}) {
    const headers = { "Content-Type": "application/json", "X-Lecture-Token": token, ...(options.headers || {}) };
    const response = await fetch(path, { ...options, headers, credentials: "same-origin" });
    const text = await response.text();
    let data = null; try { data = text ? JSON.parse(text) : null; } catch { data = text; }
    if (!response.ok) throw new Error(data?.error || `本机服务错误 ${response.status}`);
    return data;
  }

  function escapeHTML(value = "") { return String(value).replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c])); }
  function fmt(seconds = 0) { const s = Math.max(0, Math.floor(seconds)); return `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`; }
  function date(value) { try { return new Intl.DateTimeFormat("zh-CN", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }).format(new Date(value)); } catch { return ""; } }
  function bytes(value = 0) { const units = ["B", "KB", "MB", "GB"]; let amount = Math.max(0, Number(value) || 0), unit = 0; while (amount >= 1024 && unit < units.length - 1) { amount /= 1024; unit += 1; } return `${amount < 10 && unit ? amount.toFixed(1) : Math.round(amount)} ${units[unit]}`; }
  function statusLabel(value) { return ({ ready: "待开始", recording: "录音中", interrupted: "已中断", reviewingEnglish: "正在复核英文", translatingChinese: "正在翻译", processingDeepSeek: "正在生成总结", completed: "已完成", failed: "需要重试" })[value] || value || "未知"; }
  function localeLabel(value) { return ({ "en-US": "美式英语", "en-GB": "英式英语", "en-AU": "澳大利亚英语", "en-CA": "加拿大英语", "en-IN": "印度英语" })[value] || value || "美式英语"; }
  function qualityLabel(quality) {
    if (!quality?.scoredSegmentCount || quality.meanConfidence == null) return "Whisper 时间轴可回听";
    const lowRate = quality.lowConfidenceRate == null ? 0 : quality.lowConfidenceRate;
    if (quality.meanConfidence >= .82 && lowRate <= .10) return "稳定";
    if (quality.meanConfidence >= .68 && lowRate <= .25) return "可用，建议抽查";
    return "建议重点复核";
  }
  function qualityCard(label, quality) {
    const scored = quality?.scoredSegmentCount || 0;
    const confidence = quality?.meanConfidence == null ? "本地" : `${Math.round(quality.meanConfidence * 100)}%`;
    const lowRate = quality?.lowConfidenceRate == null ? "—" : `${Math.round(quality.lowConfidenceRate * 100)}%`;
    return `<article class="quality-card"><span>${escapeHTML(label)}</span><strong>${confidence}</strong><p>平均可信度</p><small>${escapeHTML(qualityLabel(quality))} · ${scored ? `低可信度 ${lowRate}` : "尚无确认字幕"}</small></article>`;
  }
  function icon(name) { return `<svg aria-hidden="true"><use href="#icon-${name}"></use></svg>`; }
  function button(label, action, kind = "button-quiet", disabled = false) { return `<button class="button ${kind}" data-action="${action}" ${disabled ? "disabled" : ""}>${escapeHTML(label)}</button>`; }
  function course() { return state.courses.find(c => c.id === state.currentCourseID) || state.courses[0]; }
  async function refreshStorage() { try { state.storage = await api("/api/storage"); } catch {} }

  function toast(message, danger = false) {
    const region = document.getElementById("toast-region"); const node = document.createElement("div");
    node.className = `toast ${danger ? "toast-danger" : ""}`; node.textContent = message; region.append(node); setTimeout(() => node.remove(), 4200);
  }

  function setRoute(route) {
    state.route = route;
    if (route === "qa" && !state.currentLectureID) state.qaScope = "course";
    const targetHash = `#${route}`;
    if (location.hash !== targetHash) { location.hash = route; return; }
    render();
  }
  function syncNav() { document.querySelectorAll("[data-route]").forEach(node => { const active = node.dataset.route === state.route; node.classList.toggle("is-active", active); active ? node.setAttribute("aria-current", "page") : node.removeAttribute("aria-current"); }); }

  async function bootstrap() {
    try {
      await api("/api/health"); state.connected = true;
      state.courses = await api("/api/courses"); state.currentCourseID ||= state.courses[0]?.id || null;
      state.lectures = await api("/api/lectures"); state.runtime = await api("/api/state");
      await refreshStorage();
      if (state.runtime.activeLectureID) { state.currentLectureID = state.runtime.activeLectureID; state.detail = await api(`/api/lectures/${state.runtime.activeLectureID}`); }
      modeNote.textContent = "LOCAL · 127.0.0.1"; document.getElementById("local-state").innerHTML = `<span class="state-lamp"></span><span>本机服务已连接</span>`;
    } catch (error) { state.connected = false; modeNote.textContent = "本机服务未连接"; toast(error.message, true); }
    render();
    setInterval(refreshRuntime, 1000);
  }

  async function refreshRuntime() {
    if (!state.connected) return;
    try {
      state.runtime = await api("/api/state");
      if (state.runtime.activeLectureID) {
        state.currentLectureID = state.runtime.activeLectureID;
        state.detail = await api(`/api/lectures/${state.runtime.activeLectureID}`);
      }
      if (state.route === "live") renderLive();
    } catch {}
  }

  function render() {
    syncNav();
    ({ live: renderLive, history: renderHistory, summary: renderSummary, qa: renderQA, settings: renderSettings, detail: renderDetail }[state.route] || renderLive)();
  }

  function empty(title, copy, action = "新建课程") { const actionID = action === "查看课程历史" ? "view-history" : "new-course"; return `<section class="empty-state"><div><span class="eyebrow">LOCAL ARCHIVE</span><h2>${escapeHTML(title)}</h2><p>${escapeHTML(copy)}</p>${button(action, actionID, "button-primary")}</div></section>`; }

  function renderLive() {
    breadcrumb.textContent = "课堂 / 实时课堂"; const selected = course();
    if (!state.courses.length) { main.innerHTML = empty("先建立第一门课程", "课程词汇表会直接帮助本地英文识别器更准确地听懂教授、术语和缩写。"); return; }
    const preservedStreams = [...main.querySelectorAll(".transcript-stream[data-stream]")].map(node => ({
      name: node.dataset.stream,
      scrollTop: node.scrollTop,
      scrollHeight: node.scrollHeight
    }));
    const segments = state.detail?.transcripts || [];
    const newestFirst = values => values.slice(-12).reverse();
    const english = newestFirst(segments.filter(s => s.source === "liveEnglish"));
    const chinese = newestFirst(segments.filter(s => s.source === "liveChinese"));
    const transitionLabel = state.runtime.transitionKind === "starting" ? "正在准备…" : state.runtime.transitionKind === "stopping" ? "正在保存…" : null;
    main.innerHTML = `<section class="page live-page">
      <header class="page-head live-head"><div><span class="eyebrow">LIVE LECTURE</span><h1>听课，不漏掉上下文。</h1><p>英文识别和中文翻译在本机运行；原始录音始终保留。</p></div><div class="lecture-clock"><strong>${fmt(state.runtime.duration)}</strong><span>${state.runtime.recording ? "REC · 正在录音" : "READY · 等待开始"}</span></div></header>
      <div class="control-rail"><label class="select-field"><span>当前课程</span><select id="course-select">${state.courses.map(c => `<option value="${c.id}" ${c.id === selected?.id ? "selected" : ""}>${escapeHTML(c.name)}${c.code ? ` · ${escapeHTML(c.code)}` : ""}</option>`).join("")}</select><small>${escapeHTML(localeLabel(selected?.speechLocaleIdentifier))} · ${(selected?.vocabulary || []).length} 个专业词</small></label><div class="level-block"><span>麦克风</span><progress class="level-track" max="100" value="${Math.round((state.runtime.audioLevel || 0) * 100)}" aria-label="麦克风音量"></progress><small>${state.runtime.recording && (state.runtime.audioLevel || 0) < .08 ? "声音偏小，请靠近教授" : "保持 Mac 靠近声源"}</small></div><div class="control-actions">${button("标记重点", "marker", "button-quiet", !state.runtime.recording || state.runtime.transitioning)}${button(transitionLabel || (state.runtime.recording ? "结束课堂" : "开始课堂"), state.runtime.recording ? "stop" : "start", state.runtime.recording ? "button-danger" : "button-primary", state.runtime.transitioning)}</div></div>
      <div class="transcript-workspace"><article class="transcript-column"><header><span class="mono-label">ENGLISH · WHISPER</span><span>最新内容在上方</span></header><div class="transcript-stream" data-stream="english">${state.runtime.volatileEnglish ? `<div class="segment draft"><time>LIVE</time><p>${escapeHTML(state.runtime.volatileEnglish)}</p></div>` : ""}${english.length ? english.map(s => `<button class="segment ${s.confidence != null && s.confidence < .55 ? "is-low" : ""}" data-time="${s.startTime}"><time>${fmt(s.startTime)}</time><p>${escapeHTML(s.text)}</p>${s.confidence != null ? `<small>${Math.round(s.confidence * 100)}%</small>` : ""}</button>`).join("") : `<div class="list-empty">${state.runtime.recording ? "正在聆听教授…" : "开始课堂后，确认的英文会出现在这里。"}</div>`}</div></article>
      <article class="transcript-column chinese"><header><span class="mono-label">简体中文 · APPLE</span><span>最新内容在上方</span></header><div class="transcript-stream" data-stream="chinese">${state.runtime.volatileChinese ? `<div class="segment draft"><time>LIVE</time><p>${escapeHTML(state.runtime.volatileChinese)}</p></div>` : ""}${chinese.length ? chinese.map(s => `<div class="segment"><time>${fmt(s.startTime)}</time><p>${escapeHTML(s.text)}</p></div>`).join("") : `<div class="list-empty">中文会跟随确认后的英文逐段出现。</div>`}</div></article></div>
      <footer class="live-status"><span>${escapeHTML(state.runtime.statusMessage || "录音、识别、翻译互相独立；翻译失败不会停止录音。")}${!state.runtime.translationAvailable ? ` ${button("下载翻译语言", "translation-settings", "button-quiet")}` : ""}</span><span>源文件 · ~/Library/Application Support/Lecture</span></footer></section>`;
    preservedStreams.forEach(previous => {
      const stream = main.querySelector(`.transcript-stream[data-stream="${previous.name}"]`);
      if (!stream || previous.scrollTop <= 1) return;
      stream.scrollTop = previous.scrollTop + Math.max(0, stream.scrollHeight - previous.scrollHeight);
    });
    document.getElementById("course-select")?.addEventListener("change", e => {
      if (state.runtime.recording) { e.target.value = state.currentCourseID; toast("录音过程中不能切换课程", true); return; }
      state.currentCourseID = e.target.value; state.currentLectureID = null; state.detail = null;
    });
  }

  function renderHistory() {
    breadcrumb.textContent = "资料库 / 课程历史";
    main.innerHTML = `<section class="page"><header class="page-head archive-head"><div><span class="eyebrow">COURSE ARCHIVE</span><h1>每门课，拥有自己的记忆。</h1><p>逐字稿、录音、标记、总结和问答都按课程归档。</p></div>${button("新建课程", "new-course", "button-primary")}</header>
      <div class="search-line">${icon("search")}<input id="course-search" placeholder="搜索课程、课程代码或教授"></div>
      <div class="course-list">${state.courses.length ? state.courses.map(c => {
        const lectures = state.lectures.filter(l => l.courseID === c.id);
        const lectureRows = lectures.length ? `<div class="lecture-list">${lectures.map(l => `<button class="lecture-row" data-action="lecture:${l.id}"><span><strong>${escapeHTML(l.title)}</strong><small>${date(l.startedAt)}</small></span><span>${escapeHTML(statusLabel(l.status))}</span><time>${fmt(l.duration)}</time>${icon("chevron")}</button>`).join("")}</div>` : `<div class="lecture-list-empty">还没有课堂记录。回到“实时课堂”即可开始第一节。</div>`;
        return `<article class="course-row" data-course="${c.id}"><div><span class="mono-label">${escapeHTML(c.code || "COURSE")}</span><h2>${escapeHTML(c.name)}</h2><p>${escapeHTML(c.professor || "未填写教授")} · ${escapeHTML(c.semester || "未填写学期")}</p></div><div class="course-meta"><strong>${lectures.length}</strong><span>节课堂</span></div><div class="row-actions">${button("编辑", `edit-course:${c.id}`)}${button("问这门课", `qa-course:${c.id}`, "button-quiet")}</div>${lectureRows}</article>`;
      }).join("") : empty("还没有课程", "先建立课程，再开始第一节英文课堂。")}</div></section>`;
    document.getElementById("course-search")?.addEventListener("input", e => document.querySelectorAll(".course-row").forEach(row => row.hidden = !row.textContent.toLowerCase().includes(e.target.value.toLowerCase())));
  }

  async function renderDetail() {
    breadcrumb.textContent = "资料库 / 课堂详情";
    if (!state.currentLectureID) { setRoute("history"); return; }
    try { state.detail = await api(`/api/lectures/${state.currentLectureID}`); } catch (e) { toast(e.message, true); return; }
    const { lecture, transcripts, markers, summaries, liveQuality, reviewedQuality } = state.detail; const reviewed = transcripts.filter(s => s.source === "reviewedEnglish"); const live = transcripts.filter(s => s.source === "liveEnglish"); const english = reviewed.length ? reviewed : live; const corrected = transcripts.filter(s => s.source === "correctedChinese"); const zh = corrected.length ? corrected : transcripts.filter(s => s.source === "liveChinese");
    main.innerHTML = `<section class="page"><button class="back-link" data-action="back-history">${icon("back")}课程历史</button><header class="page-head"><div><span class="eyebrow">LECTURE RECORD</span><h1>${escapeHTML(lecture.title)}</h1><p>${date(lecture.startedAt)} · ${fmt(lecture.duration)} · ${escapeHTML(statusLabel(lecture.status))}</p></div>${["failed","interrupted","completed"].includes(lecture.status) && (!summaries.length || lecture.status !== "completed") ? button(summaries.length ? "重新处理" : "生成复核与总结", "retry", "button-primary") : ""}</header>
      <div class="audio-console"><audio id="audio" controls preload="metadata" src="/api/lectures/${lecture.id}/audio?token=${encodeURIComponent(token)}"></audio><span>原始录音 · 仅在本机</span></div>
      <section class="quality-panel"><div><span class="eyebrow">RECOGNITION QUALITY</span><h2>识别质量证据</h2><p>Whisper 在本机运行；原音、时间轴和实时/复核双版本用于抽查。严格准确率请用已知稿计算 WER。</p></div><div class="quality-cards">${qualityCard("实时确认稿", liveQuality)}${qualityCard("课后复核稿", reviewedQuality)}</div></section>
      <div class="detail-grid"><article class="paper transcript-paper"><header><span class="mono-label">${reviewed.length ? "REVIEWED ENGLISH" : "LIVE ENGLISH"}</span><span>${english.filter(s => s.confidence != null && s.confidence < .55).length} 处待复核</span></header>${english.map(s => `<button class="detail-segment" data-time="${s.startTime}"><time>${fmt(s.startTime)}</time><p>${escapeHTML(s.text)}</p></button>`).join("") || `<p class="list-empty">尚无英文逐字稿。</p>`}</article><article class="paper transcript-paper chinese"><header><span class="mono-label">${corrected.length ? "DEEPSEEK CORRECTED" : "LIVE CHINESE"}</span></header>${zh.map(s => `<div class="detail-segment"><time>${fmt(s.startTime)}</time><p>${escapeHTML(s.text)}</p></div>`).join("") || `<p class="list-empty">尚无中文翻译。</p>`}</article></div>
      <section class="marker-strip"><span class="mono-label">MARKERS</span>${markers.map(m => `<button data-time="${m.time}">${fmt(m.time)} · ${escapeHTML(m.label)}</button>`).join("") || "没有课堂标记"}</section><section class="export-list"><a class="export-action" href="/api/lectures/${lecture.id}/export?token=${encodeURIComponent(token)}" download>${icon("download")}<span>导出 Markdown 学习档案</span><span>仅文字 · 不含 API Key</span></a></section>${summaries[0] ? `<section class="summary-preview"><span class="eyebrow">LATEST SUMMARY</span><h2>最新学习总结</h2><p>${escapeHTML(summaries[0].content.overview)}</p>${button("打开完整总结", "open-summary", "button-primary")}</section>` : ""}</section>`;
    applyPendingAudioJump();
  }

  function applyPendingAudioJump() {
    if (state.pendingAudioTime == null) return;
    const audio = document.getElementById("audio");
    if (!audio) return;
    const target = Math.max(0, Number(state.pendingAudioTime) || 0);
    const seek = () => { audio.currentTime = target; state.pendingAudioTime = null; audio.play().catch(() => {}); };
    if (audio.readyState >= 1) seek();
    else audio.addEventListener("loadedmetadata", seek, { once: true });
  }

  async function renderSummary() {
    breadcrumb.textContent = "复习 / 学习总结";
    if (!state.detail?.summaries?.length) {
      const candidates = [state.currentLectureID, ...state.lectures.map(l => l.id)].filter((id, index, values) => id && values.indexOf(id) === index);
      for (const id of candidates) {
        try {
          const detail = await api(`/api/lectures/${id}`);
          if (detail.summaries?.length) { state.currentLectureID = id; state.currentCourseID = detail.lecture.courseID; state.detail = detail; break; }
        } catch {}
      }
    }
    const summary = state.detail?.summaries?.[0]?.content;
    if (!summary) { main.innerHTML = empty("还没有可读的总结", "结束一节课堂后，Lecture 会先本地复核英文，再用 DeepSeek 生成忠于原文的学习资料。", "查看课程历史"); return; }
    const list = (title, values) => `<section><h3>${title}</h3><ul>${(values || []).map(v => `<li>${escapeHTML(v)}</li>`).join("") || "<li>暂无</li>"}</ul></section>`;
    main.innerHTML = `<article class="page summary-document"><header><span class="eyebrow">STUDY EDITION</span><h1>课堂学习总结</h1><p>${escapeHTML(summary.overview)}</p></header><div class="summary-columns">${list("核心概念", summary.coreConcepts)}${list("定义", summary.definitions)}${list("教授举例", summary.professorExamples)}${list("教授强调", summary.professorEmphasis)}${list("可能的考试方向 *", summary.possibleExamTopics)}${list("仍待解决的问题", summary.unresolvedQuestions)}</div><section class="glossary"><h2>双语术语表</h2>${(summary.glossary || []).map(g => `<div><strong>${escapeHTML(g.english)}</strong><span>${escapeHTML(g.chinese)}</span><p>${escapeHTML(g.explanation)}</p></div>`).join("")}</section><small>* 仅为根据课堂内容推测的复习方向，不代表教授承诺的考试范围。</small></article>`;
  }

  async function renderQA() {
    breadcrumb.textContent = "复习 / DeepSeek 问答"; const c = course();
    if (!c) { main.innerHTML = empty("先选择一门课程", "问答只会引用你自己的课堂逐字稿。"); return; }
    const lectureScope = state.qaScope === "lecture" && state.currentLectureID;
    try { state.chat = await api(`/api/courses/${c.id}/chat${lectureScope ? `?lectureID=${state.currentLectureID}` : ""}`); } catch {}
    const selectedLecture = state.lectures.find(l => l.id === state.currentLectureID);
    main.innerHTML = `<section class="page qa-page"><header class="page-head"><div><span class="eyebrow">GROUNDED Q&A</span><h1>只依据教授说过的话回答。</h1><p>每条回答都应带课堂和时间引用；证据不足时会明确说明。</p></div></header><div class="scope-switch"><button class="${lectureScope ? "" : "is-active"}" data-action="qa-scope:course">整门课程</button><button class="${lectureScope ? "is-active" : ""}" data-action="qa-scope:lecture" ${state.currentLectureID ? "" : "disabled"}>当前课堂</button><span>${escapeHTML(lectureScope ? selectedLecture?.title || c.name : c.name)}</span></div><div class="chat-stream">${state.chat.map(m => `<article class="chat ${m.role}"><span>${m.role === "user" ? "YOU" : "DEEPSEEK"}</span><p>${escapeHTML(m.text)}</p>${(m.citations || []).map(x => `<button data-time="${x.startTime}" data-lecture="${x.lectureID}">${escapeHTML(x.lectureTitle)} · ${fmt(x.startTime)}</button>`).join("")}</article>`).join("") || `<div class="list-empty">例如：教授如何解释这个概念？这节课最重要的三点是什么？</div>`}</div><form id="qa-form" class="question-box"><textarea name="question" required placeholder="向课堂记录提问…"></textarea><button class="button button-primary">${icon("send")}发送</button></form></section>`;
    document.getElementById("qa-form")?.addEventListener("submit", askQuestion);
  }

  function renderSettings() {
    breadcrumb.textContent = "Lecture / 设置与诊断"; const r = state.runtime;
    main.innerHTML = `<section class="page settings-page"><header class="page-head"><div><span class="eyebrow">LOCAL DIAGNOSTICS</span><h1>课前，确认一切就绪。</h1><p>Lecture 不提供云端录音，也不会把音频发送给 DeepSeek。</p></div></header><div class="diagnostic-list"><div><span>${icon("mic")}麦克风与本地 Whisper</span><strong>${r.speechAvailable ? "可用" : "需要重新安装"}</strong></div><div><span>${icon("external")}英文 → 简体中文</span><strong>${r.translationAvailable ? "可用" : "需要下载离线语言"}</strong>${r.translationAvailable ? "" : button("打开下载页", "translation-settings", "button-quiet")}</div><div><span>${icon("lock")}DeepSeek API</span><strong>${r.deepSeekConfigured ? "已存入钥匙串" : "尚未配置"}</strong></div><div><span>${icon("database")}本地资料库</span><strong>${bytes(state.storage.totalBytes)} · ${state.storage.recordingCount || 0} 份录音</strong></div></div><section class="accuracy-guide"><div><span class="eyebrow">ACCURACY PROTOCOL</span><h2>四层识别保障</h2></div><ol><li><strong>本地模型</strong><span>Whisper Base English 全程在这台 Mac 上识别。</span></li><li><strong>课程词汇</strong><span>专业词、人名和缩写会作为识别提示词。</span></li><li><strong>完整复核</strong><span>停止录音后用完整原音再识别一次，替代课堂分段稿。</span></li><li><strong>证据可追溯</strong><span>保留原音、时间轴及实时/复核双版本。</span></li></ol><p>软件不能承诺 100% 正确。要测真实准确率，请用一段已知英文稿计算词错误率（WER）。</p></section><section class="settings-section"><div><span class="eyebrow">LOCAL STORAGE</span><h2>本地资料与导出</h2><p>数据目录：~/Library/Application Support/Lecture。每节课堂可从详情页导出 Markdown，录音不会嵌入导出文件。</p></div><strong>${bytes(state.storage.recordingBytes)} 录音 · ${bytes(state.storage.databaseBytes)} 历史库 · ${bytes(state.storage.exportBytes)} 导出</strong></section><section class="settings-section"><div><span class="eyebrow">MACOS KEYCHAIN</span><h2>DeepSeek 密钥</h2><p>网页只负责提交；密钥由原生助手直接写入 macOS 钥匙串，浏览器不会保存。</p></div><div>${button(r.deepSeekConfigured ? "更换密钥" : "保存密钥", "key", "button-primary")} ${r.deepSeekConfigured ? button("测试连接", "test-key") + button("删除", "delete-key", "button-danger") : ""}</div></section></section>`;
  }

  async function action(value, source = null) {
    const control = source?.closest?.("button[data-action]");
    const originalLabel = control?.textContent;
    if (control && ["start", "stop", "retry", "test-key"].includes(value)) {
      control.disabled = true;
      control.textContent = value === "start" ? "正在准备…" : value === "stop" ? "正在保存…" : "处理中…";
    }
    try {
      if (value === "new-course") openCourseDialog();
      else if (value.startsWith("edit-course:")) openCourseDialog(state.courses.find(c => c.id === value.split(":")[1]));
      else if (value.startsWith("lecture:")) { state.currentLectureID = value.split(":")[1]; const lecture = state.lectures.find(l => l.id === state.currentLectureID); state.currentCourseID = lecture?.courseID || state.currentCourseID; setRoute("detail"); }
      else if (value.startsWith("qa-course:")) { state.currentCourseID = value.split(":")[1]; state.qaScope = "course"; setRoute("qa"); }
      else if (value.startsWith("qa-scope:")) { state.qaScope = value.split(":")[1]; await renderQA(); }
      else if (value === "start") { const c = course(); if (!c) return; toast("首次使用时，请在系统窗口允许麦克风与语音识别"); const lecture = await api("/api/lectures/start", { method: "POST", body: JSON.stringify({ courseID: c.id }) }); state.currentLectureID = lecture.id; state.currentCourseID = c.id; state.detail = await api(`/api/lectures/${lecture.id}`); toast("课堂已开始；关闭网页也会继续录音"); await reload(); }
      else if (value === "stop") { const lecture = await api("/api/lectures/stop", { method: "POST", body: "{}" }); state.currentLectureID = lecture.id; toast("录音已保存，课后处理已开始"); await reload(); }
      else if (value === "marker") { await api("/api/markers", { method: "POST", body: JSON.stringify({ label: "课堂重点" }) }); toast("已标记当前时间"); }
      else if (value === "retry") { await api(`/api/lectures/${state.currentLectureID}/retry`, { method: "POST", body: "{}" }); toast("已重新开始课后处理"); }
      else if (value === "key") document.getElementById("key-dialog").showModal();
      else if (value === "test-key") { await api("/api/deepseek/test", { method: "POST", body: "{}" }); toast("DeepSeek 连接正常"); }
      else if (value === "translation-settings") { await api("/api/translation/settings", { method: "POST", body: "{}" }); toast("请下载英语（美国）和中文（普通话，简体）"); }
      else if (value === "delete-key") { if (confirm("确定从 macOS 钥匙串删除 DeepSeek 密钥？")) { await api("/api/deepseek/key", { method: "DELETE" }); await reload(); } }
      else if (value === "back-history") setRoute("history");
      else if (value === "open-summary") setRoute("summary");
      else if (value === "view-history") setRoute("history");
    } catch (error) { toast(error.message, true); }
    finally { if (control?.isConnected) { control.disabled = false; control.textContent = originalLabel; } }
  }

  function openCourseDialog(c = null) {
    const form = document.getElementById("course-form"); form.reset(); form.elements.id.value = c?.id || ""; form.elements.name.value = c?.name || ""; form.elements.code.value = c?.code || ""; form.elements.professor.value = c?.professor || ""; form.elements.semester.value = c?.semester || ""; form.elements.speechLocaleIdentifier.value = c?.speechLocaleIdentifier || "en-US"; form.elements.vocabulary.value = (c?.vocabulary || []).join("\n"); document.getElementById("course-dialog-title").textContent = c ? "编辑课程" : "新建课程"; document.getElementById("delete-course").classList.toggle("is-hidden", !c); document.getElementById("course-dialog").showModal();
  }

  async function saveCourse(event) {
    event.preventDefault(); const form = new FormData(event.currentTarget); const id = form.get("id") || crypto.randomUUID(); const existing = state.courses.find(c => c.id === id);
    const body = { id, name: form.get("name"), code: form.get("code") || null, professor: form.get("professor") || "", semester: form.get("semester") || null, speechLocaleIdentifier: String(form.get("speechLocaleIdentifier") || "en-US"), vocabulary: String(form.get("vocabulary") || "").split(/\n|,/).map(x => x.trim()).filter(Boolean), createdAt: existing?.createdAt || new Date().toISOString(), updatedAt: new Date().toISOString() };
    try { await api(existing ? `/api/courses/${id}` : "/api/courses", { method: existing ? "PUT" : "POST", body: JSON.stringify(body) }); document.getElementById("course-dialog").close(); await reload(); toast("课程已保存"); } catch (e) { toast(e.message, true); }
  }

  async function askQuestion(event) { event.preventDefault(); const form = new FormData(event.currentTarget); const question = String(form.get("question") || "").trim(); if (!question) return; const lectureID = state.qaScope === "lecture" ? state.currentLectureID : null; try { await api("/api/qa", { method: "POST", body: JSON.stringify({ question, courseID: course().id, lectureID }) }); await renderQA(); } catch (e) { toast(e.message, true); } }
  async function reload() {
    state.courses = await api("/api/courses");
    state.lectures = await api("/api/lectures");
    state.runtime = await api("/api/state");
    await refreshStorage();
    if (state.runtime.activeLectureID) {
      state.currentLectureID = state.runtime.activeLectureID;
      state.detail = await api(`/api/lectures/${state.runtime.activeLectureID}`);
    }
    render();
  }

  document.addEventListener("click", event => {
    const route = event.target.closest("[data-route]")?.dataset.route;
    if (route) setRoute(route);
    const actionNode = event.target.closest("[data-action]");
    const act = actionNode?.dataset.action;
    if (act) action(act, actionNode);
    const timed = event.target.closest("[data-time]");
    if (!timed) return;
    const targetLectureID = timed.dataset.lecture;
    const requiresLectureChange = Boolean(targetLectureID && targetLectureID !== state.currentLectureID);
    state.pendingAudioTime = Number(timed.dataset.time);
    if (targetLectureID) state.currentLectureID = targetLectureID;
    if (state.route !== "detail" || requiresLectureChange) {
      setRoute("detail");
      return;
    }
    applyPendingAudioJump();
  });
  document.querySelectorAll("[data-close-dialog]").forEach(b => b.addEventListener("click", () => b.closest("dialog").close()));
  document.getElementById("course-form").addEventListener("submit", saveCourse);
  document.getElementById("delete-course").addEventListener("click", async () => { const id = document.getElementById("course-form").elements.id.value; if (id && confirm("删除课程会同时删除课堂、逐字稿和总结。确定继续？")) { await api(`/api/courses/${id}`, { method: "DELETE" }); document.getElementById("course-dialog").close(); await reload(); } });
  document.getElementById("key-form").addEventListener("submit", async event => { event.preventDefault(); const value = new FormData(event.currentTarget).get("apiKey"); try { await api("/api/deepseek/key", { method: "POST", body: JSON.stringify({ apiKey: value }) }); event.currentTarget.reset(); document.getElementById("key-dialog").close(); toast("密钥已安全保存并通过连接测试"); await reload(); } catch (e) { toast(e.message, true); } });
  window.addEventListener("hashchange", () => { state.route = location.hash.slice(1) || "live"; render(); });
  document.addEventListener("keydown", e => { if (/^[1-5]$/.test(e.key) && !/INPUT|TEXTAREA|SELECT/.test(e.target.tagName)) setRoute(["live","history","summary","qa","settings"][Number(e.key)-1]); });
  setInterval(() => { const clock = document.getElementById("clock"); const now = new Date(); clock.dateTime = now.toISOString(); clock.textContent = now.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" }); }, 1000);

  bootstrap();
})();
