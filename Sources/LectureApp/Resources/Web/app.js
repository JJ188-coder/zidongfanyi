(function () {
  "use strict";

  const token = new URLSearchParams(location.search).get("token") || sessionStorage.getItem("lecture.token") || "";
  if (token) sessionStorage.setItem("lecture.token", token);
  const savedSelection = (() => {
    try { return JSON.parse(localStorage.getItem("lecture.selection") || "{}"); } catch { return {}; }
  })();
  const state = {
    route: location.hash.slice(1) || "live",
    courses: [], lectures: [], currentCourseID: savedSelection.courseID || null, currentLectureID: savedSelection.lectureID || null,
    runtime: { recording: false, duration: 0, audioLevel: 0, volatileEnglish: "", volatileChinese: "", deepSeekConfigured: false },
    detail: null, chat: [], qaScope: savedSelection.qaScope || "lecture", connected: false, pendingAudioTime: null,
    ai: { configuration: null, keyConfigured: false, presets: [] },
    detailRequest: 0, runtimeRequest: 0, routeRenderGeneration: 0,
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
  function transcriptCharacters(values) { return (values || []).reduce((sum, value) => sum + String(value.text || "").trim().length, 0); }
  function transcriptCoverage(values) { if (!values?.length) return 0; return Math.max(...values.map(v => Number(v.endTime) || 0)) - Math.min(...values.map(v => Number(v.startTime) || 0)); }
  function preferredEnglish(live, reviewed) {
    if (!reviewed.length) return live;
    if (!live.length) return reviewed;
    return transcriptCharacters(reviewed) >= Math.max(120, transcriptCharacters(live) * .45)
      && transcriptCoverage(reviewed) >= Math.max(30, transcriptCoverage(live) * .8) ? reviewed : live;
  }
  function icon(name) { return `<svg aria-hidden="true"><use href="#icon-${name}"></use></svg>`; }
  function button(label, action, kind = "button-quiet", disabled = false) { return `<button class="button ${kind}" data-action="${action}" ${disabled ? "disabled" : ""}>${escapeHTML(label)}</button>`; }
  function course() { return state.courses.find(c => c.id === state.currentCourseID) || null; }
  function lecturesForCourse(courseID = state.currentCourseID) { return state.lectures.filter(l => l.courseID === courseID); }
  function selectedLecture() { return state.lectures.find(l => l.id === state.currentLectureID) || null; }
  function persistSelection() {
    localStorage.setItem("lecture.selection", JSON.stringify({ courseID: state.currentCourseID, lectureID: state.currentLectureID, qaScope: state.qaScope }));
  }
  function selectCourse(courseID, { chooseLatestLecture = true } = {}) {
    if (!state.courses.some(c => c.id === courseID)) return false;
    state.currentCourseID = courseID;
    const available = lecturesForCourse(courseID);
    if (!available.some(l => l.id === state.currentLectureID)) state.currentLectureID = chooseLatestLecture ? available[0]?.id || null : null;
    state.detailRequest += 1;
    state.detail = state.detail?.lecture?.id === state.currentLectureID ? state.detail : null;
    state.chat = [];
    persistSelection();
    return true;
  }
  function selectLecture(lectureID) {
    const lecture = state.lectures.find(l => l.id === lectureID);
    if (!lecture) return false;
    state.currentLectureID = lecture.id; state.currentCourseID = lecture.courseID;
    state.detailRequest += 1;
    state.detail = state.detail?.lecture?.id === lecture.id ? state.detail : null;
    state.chat = [];
    persistSelection();
    return true;
  }
  async function loadSelectedDetail() {
    if (!state.currentLectureID) { state.detail = null; return null; }
    const requestID = ++state.detailRequest; const lectureID = state.currentLectureID;
    const detail = await api(`/api/lectures/${lectureID}`);
    if (requestID !== state.detailRequest || lectureID !== state.currentLectureID) return null;
    state.detail = detail; return detail;
  }
  function selectorHTML({ includeLecture = true } = {}) {
    const lectures = lecturesForCourse();
    return `<div class="context-selectors"><label class="select-field"><span>课程</span><select data-select="course">${state.courses.map(c => `<option value="${c.id}" ${c.id === state.currentCourseID ? "selected" : ""}>${escapeHTML(c.name)}${c.code ? ` · ${escapeHTML(c.code)}` : ""}</option>`).join("")}</select></label>${includeLecture ? `<label class="select-field"><span>具体课堂录音</span><select data-select="lecture" ${lectures.length ? "" : "disabled"}>${lectures.length ? lectures.map(l => `<option value="${l.id}" ${l.id === state.currentLectureID ? "selected" : ""}>${escapeHTML(l.title)} · ${date(l.startedAt)}</option>`).join("") : `<option>这门课还没有录音</option>`}</select></label>` : ""}</div>`;
  }
  async function refreshStorage() { try { state.storage = await api("/api/storage"); } catch {} }
  async function refreshAIConfiguration() { try { state.ai = await api("/api/ai/config"); } catch {} }

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
      state.courses = await api("/api/courses");
      state.lectures = await api("/api/lectures"); state.runtime = await api("/api/state");
      await Promise.all([refreshStorage(), refreshAIConfiguration()]);
      if (state.runtime.activeLectureID) selectLecture(state.runtime.activeLectureID);
      else if (!selectLecture(state.currentLectureID)) {
        if (!selectCourse(state.currentCourseID)) selectCourse(state.courses[0]?.id || null);
      }
      if (state.currentLectureID) await loadSelectedDetail();
      modeNote.textContent = "LOCAL · 127.0.0.1"; document.getElementById("local-state").innerHTML = `<span class="state-lamp"></span><span>本机服务已连接</span>`;
    } catch (error) { state.connected = false; modeNote.textContent = "本机服务未连接"; toast(error.message, true); }
    render();
    setInterval(refreshRuntime, 350);
  }

  async function refreshRuntime() {
    if (!state.connected) return;
    const requestID = ++state.runtimeRequest;
    try {
      const runtime = await api("/api/state");
      if (requestID !== state.runtimeRequest) return;
      state.runtime = runtime;
      if (state.runtime.activeLectureID) {
        if (state.runtime.recording && state.currentLectureID !== state.runtime.activeLectureID) selectLecture(state.runtime.activeLectureID);
        if (state.currentLectureID === state.runtime.activeLectureID) await loadSelectedDetail();
      }
      if (state.route === "live") updateLiveRuntime();
    } catch {}
  }

  function render() {
    syncNav();
    const route = state.route; const generation = ++state.routeRenderGeneration;
    const renderer = { live: renderLive, history: renderHistory, summary: renderSummary, qa: renderQA, settings: renderSettings, detail: renderDetail }[route] || renderLive;
    Promise.resolve(renderer(generation, route)).catch(error => {
      if (renderIsCurrent(generation, route)) toast(error.message, true);
    });
  }
  function renderIsCurrent(generation, route) { return generation === state.routeRenderGeneration && route === state.route; }

  function updateLiveRuntime() {
    const page = main.querySelector(".live-page");
    if (!page) { renderLive(); return; }
    const clock = page.querySelector(".lecture-clock strong");
    const recording = page.querySelector(".lecture-clock span");
    const level = page.querySelector(".level-track");
    const levelNote = page.querySelector(".level-block small");
    if (clock) clock.textContent = fmt(state.runtime.duration);
    if (recording) recording.textContent = state.runtime.recording ? "REC · 正在录音" : "READY · 等待开始";
    if (level) level.value = Math.round((state.runtime.audioLevel || 0) * 100);
    if (levelNote) levelNote.textContent = state.runtime.recording && state.runtime.receivingAudio === false ? "未收到声音，请检查输入设备" : state.runtime.recording && (state.runtime.audioLevel || 0) < .08 ? "声音偏小，请靠近教授" : "保持 Mac 靠近声源";
    updateLiveStream("english", state.runtime.volatileEnglish);
    updateLiveStream("chinese", state.runtime.volatileChinese);
  }

  function updateLiveStream(language, draft) {
    const stream = main.querySelector(`.transcript-stream[data-stream="${language}"]`);
    if (!stream) return;
    const segments = state.detail?.lecture?.id === state.currentLectureID
      ? transcriptWindow((state.detail.transcripts || []).filter(s => s.source === (language === "english" ? "liveEnglish" : "liveChinese"))) : [];
    const signature = `${segments.map(s => s.id).join("|")}::${draft || ""}`;
    if (stream.dataset.signature === signature) return;
    const previous = captureStreamPositions().find(item => item.name === language);
    updateStreamElements(stream, segments, draft, language);
    stream.dataset.signature = signature;
    if (previous) restoreStreamPositions([previous]); else stream.scrollTop = stream.scrollHeight;
  }

  function updateStreamElements(stream, segments, draft, language) {
    stream.querySelector(".list-empty")?.remove();
    const draftNode = stream.querySelector(`[data-draft="${language}"]`);
    const existing = new Set([...stream.querySelectorAll("[data-segment]")].map(node => node.dataset.segment));
    segments.forEach(segment => {
      if (existing.has(segment.id)) return;
      const holder = document.createElement("template");
      holder.innerHTML = liveSegmentMarkup(segment, language);
      stream.insertBefore(holder.content.firstElementChild, draftNode || null);
    });
    const allowed = new Set(segments.map(segment => segment.id));
    stream.querySelectorAll("[data-segment]").forEach(node => { if (!allowed.has(node.dataset.segment)) node.remove(); });
    if (draft) {
      const node = stream.querySelector(`[data-draft="${language}"]`);
      if (node) node.querySelector("p").textContent = draft;
      else { const holder = document.createElement("template"); holder.innerHTML = draftMarkup(draft, language); stream.append(holder.content.firstElementChild); }
    } else {
      stream.querySelector(`[data-draft="${language}"]`)?.remove();
    }
    if (!segments.length && !draft) stream.innerHTML = emptyStreamMarkup(language);
  }

  function empty(title, copy, action = "新建课程") { const actionID = action === "查看课程历史" ? "view-history" : "new-course"; return `<section class="empty-state"><div><span class="eyebrow">LOCAL ARCHIVE</span><h2>${escapeHTML(title)}</h2><p>${escapeHTML(copy)}</p>${button(action, actionID, "button-primary")}</div></section>`; }

  function captureStreamPositions() {
    return [...main.querySelectorAll(".transcript-stream[data-stream]")].map(stream => {
      const children = [...stream.querySelectorAll("[data-segment]")];
      const anchor = children.find(node => node.offsetTop + node.offsetHeight > stream.scrollTop);
      return {
        name: stream.dataset.stream,
        scrollTop: stream.scrollTop,
        scrollHeight: stream.scrollHeight,
        wasNearBottom: stream.scrollHeight - stream.scrollTop - stream.clientHeight < 72,
        anchorID: anchor?.dataset.segment || null,
        anchorOffset: anchor ? anchor.offsetTop - stream.scrollTop : 0
      };
    });
  }

  function restoreStreamPositions(positions) {
    positions.forEach(previous => {
      const stream = main.querySelector(`.transcript-stream[data-stream="${previous.name}"]`);
      if (!stream) return;
      if (previous.wasNearBottom) { stream.scrollTop = stream.scrollHeight; return; }
      const anchor = previous.anchorID
        ? [...stream.querySelectorAll("[data-segment]")].find(node => node.dataset.segment === previous.anchorID)
        : null;
      if (anchor) {
        stream.scrollTop = anchor.offsetTop - previous.anchorOffset;
        return;
      }
      stream.scrollTop = previous.scrollTop + Math.max(0, stream.scrollHeight - previous.scrollHeight);
    });
  }

  function transcriptWindow(values) {
    return values.slice(-240).sort((a, b) => Number(a.startTime) - Number(b.startTime));
  }

  function liveSegmentMarkup(s, language) {
    return language === "english"
      ? `<button class="segment ${s.confidence != null && s.confidence < .55 ? "is-low" : ""}" data-segment="${escapeHTML(s.id)}" data-time="${s.startTime}"><time>${fmt(s.startTime)}</time><p>${escapeHTML(s.text)}</p>${s.confidence != null ? `<small>${Math.round(s.confidence * 100)}%</small>` : ""}</button>`
      : `<div class="segment" data-segment="${escapeHTML(s.id)}"><time>${fmt(s.startTime)}</time><p>${escapeHTML(s.text)}</p></div>`;
  }
  function emptyStreamMarkup(language) { return `<div class="list-empty">${language === "english" ? (state.runtime.recording ? "正在聆听教授…" : "开始课堂后，确认的英文会出现在这里。") : "中文会跟随确认后的英文逐段出现。"}</div>`; }
  function draftMarkup(draft, language) { return draft ? `<div class="segment draft" data-draft="${language}"><time>LIVE</time><p>${escapeHTML(draft)}</p></div>` : ""; }

  function liveStreamMarkup(segments, draft, language) {
    const content = segments.length ? segments.map(s => liveSegmentMarkup(s, language)).join("") : emptyStreamMarkup(language);
    return content + draftMarkup(draft, language);
  }

  function renderLive() {
    breadcrumb.textContent = "课堂 / 实时课堂"; const selected = course();
    if (!state.courses.length) { main.innerHTML = empty("先建立第一门课程", "课程词汇表会直接帮助本地英文识别器更准确地听懂教授、术语和缩写。"); return; }
    const preservedStreams = captureStreamPositions();
    const segments = state.detail?.lecture?.id === state.currentLectureID ? state.detail.transcripts || [] : [];
    const english = transcriptWindow(segments.filter(s => s.source === "liveEnglish"));
    const chinese = transcriptWindow(segments.filter(s => s.source === "liveChinese"));
    const transitionLabel = state.runtime.transitionKind === "starting" ? "正在准备…" : state.runtime.transitionKind === "stopping" ? "正在保存…" : null;
    main.innerHTML = `<section class="page live-page">
      <header class="page-head live-head"><div><span class="eyebrow">LIVE LECTURE</span><h1>听课，不漏掉上下文。</h1><p>英文识别和中文翻译在本机运行；原始录音始终保留。</p></div><div class="lecture-clock"><strong>${fmt(state.runtime.duration)}</strong><span>${state.runtime.recording ? "REC · 正在录音" : "READY · 等待开始"}</span></div></header>
      <div class="control-rail"><label class="select-field"><span>当前课程</span><select id="course-select" ${state.runtime.recording ? "disabled" : ""}>${state.courses.map(c => `<option value="${c.id}" ${c.id === selected?.id ? "selected" : ""}>${escapeHTML(c.name)}${c.code ? ` · ${escapeHTML(c.code)}` : ""}</option>`).join("")}</select><small>${escapeHTML(localeLabel(selected?.speechLocaleIdentifier))} · ${(selected?.vocabulary || []).length} 个专业词</small></label><div class="level-block"><span>麦克风</span><progress class="level-track" max="100" value="${Math.round((state.runtime.audioLevel || 0) * 100)}" aria-label="麦克风音量"></progress><small>${state.runtime.recording && state.runtime.receivingAudio === false ? "未收到声音，请检查输入设备" : state.runtime.recording && (state.runtime.audioLevel || 0) < .08 ? "声音偏小，请靠近教授" : "保持 Mac 靠近声源"}</small></div><div class="control-actions">${button("标记重点", "marker", "button-quiet", !state.runtime.recording || state.runtime.transitioning)}${button(transitionLabel || (state.runtime.recording ? "结束课堂" : "开始课堂"), state.runtime.recording ? "stop" : "start", state.runtime.recording ? "button-danger" : "button-primary", state.runtime.transitioning)}</div></div>
      <div class="transcript-workspace"><article class="transcript-column"><header><span class="mono-label">ENGLISH · LOCAL SPEECH</span><span>时间正序 · 草稿在底部自动更新</span></header><div class="transcript-stream" data-stream="english">${liveStreamMarkup(english, state.runtime.volatileEnglish, "english")}</div></article>
      <article class="transcript-column chinese"><header><span class="mono-label">简体中文 · APPLE</span><span>时间正序</span></header><div class="transcript-stream" data-stream="chinese">${liveStreamMarkup(chinese, state.runtime.volatileChinese, "chinese")}</div></article></div>
      <footer class="live-status"><span>${escapeHTML(state.runtime.statusMessage || "录音、识别、翻译互相独立；翻译失败不会停止录音。")}${!state.runtime.translationAvailable ? ` ${button("下载翻译语言", "translation-settings", "button-quiet")}` : ""}</span><span>源文件 · ~/Library/Application Support/Lecture</span></footer></section>`;
    restoreStreamPositions(preservedStreams);
    if (!preservedStreams.length) main.querySelectorAll(".transcript-stream").forEach(stream => { stream.scrollTop = stream.scrollHeight; });
    main.querySelector('[data-stream="english"]')?.setAttribute("data-signature", `${english.map(s => s.id).join("|")}::${state.runtime.volatileEnglish || ""}`);
    main.querySelector('[data-stream="chinese"]')?.setAttribute("data-signature", `${chinese.map(s => s.id).join("|")}::${state.runtime.volatileChinese || ""}`);
    document.getElementById("course-select")?.addEventListener("change", e => {
      if (state.runtime.recording) { e.target.value = state.currentCourseID; toast("录音过程中不能切换课程", true); return; }
      selectCourse(e.target.value, { chooseLatestLecture: false });
      renderLive();
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

  async function renderDetail(generation = state.routeRenderGeneration, route = state.route) {
    breadcrumb.textContent = "资料库 / 课堂详情";
    if (!state.currentLectureID) { setRoute("history"); return; }
    if (state.detail?.lecture?.id !== state.currentLectureID) {
      main.innerHTML = `<section class="page loading-page">${selectorHTML()}<p class="list-empty">正在更新这次课堂记录…</p></section>`;
    }
    try { if (!await loadSelectedDetail()) return; } catch (e) { toast(e.message, true); return; }
    if (!renderIsCurrent(generation, route) || route !== "detail") return;
    const { lecture, transcripts, markers, summaries, liveQuality, reviewedQuality } = state.detail; const reviewed = transcripts.filter(s => s.source === "reviewedEnglish"); const live = transcripts.filter(s => s.source === "liveEnglish"); const english = preferredEnglish(live, reviewed); const usingReviewed = english.length > 0 && english.every(s => s.source === "reviewedEnglish"); const corrected = transcripts.filter(s => s.source === "correctedChinese"); const englishIDs = new Set(english.map(s => s.id)); const correctedIDs = new Set(corrected.map(s => s.sourceSegmentID).filter(Boolean)); const correctedMatchesEnglish = corrected.length && corrected.every(s => englishIDs.has(s.sourceSegmentID)) && [...englishIDs].every(id => correctedIDs.has(id)); const zh = correctedMatchesEnglish ? corrected : transcripts.filter(s => s.source === "liveChinese");
    main.innerHTML = `<section class="page"><button class="back-link" data-action="back-history">${icon("back")}课程历史</button><header class="page-head"><div><span class="eyebrow">LECTURE RECORD</span><h1>${escapeHTML(lecture.title)}</h1><p>${date(lecture.startedAt)} · ${fmt(lecture.duration)} · ${escapeHTML(statusLabel(lecture.status))}</p></div>${["failed","interrupted","completed"].includes(lecture.status) && (!summaries.length || lecture.status !== "completed") ? button(summaries.length ? "重新处理" : "生成复核与总结", "retry", "button-primary") : ""}</header>
      <div class="audio-console"><audio id="audio" controls preload="metadata" src="/api/lectures/${lecture.id}/audio?token=${encodeURIComponent(token)}"></audio><span>原始录音 · 仅在本机</span></div>
      <section class="quality-panel"><div><span class="eyebrow">RECOGNITION QUALITY</span><h2>识别质量证据</h2><p>Whisper 在本机运行；原音、时间轴和实时/复核双版本用于抽查。严格准确率请用已知稿计算 WER。</p></div><div class="quality-cards">${qualityCard("实时确认稿", liveQuality)}${qualityCard("课后复核稿", reviewedQuality)}</div></section>
      <div class="detail-grid"><article class="paper transcript-paper"><header><span class="mono-label">${usingReviewed ? "REVIEWED ENGLISH" : "LIVE ENGLISH · SAFEST VERSION"}</span><span>${english.filter(s => s.confidence != null && s.confidence < .55).length} 处待复核</span></header>${english.map(s => `<button class="detail-segment" data-time="${s.startTime}"><time>${fmt(s.startTime)}</time><p>${escapeHTML(s.text)}</p></button>`).join("") || `<p class="list-empty">尚无英文逐字稿。</p>`}</article><article class="paper transcript-paper chinese"><header><span class="mono-label">${correctedMatchesEnglish ? "AI CORRECTED CHINESE" : "LIVE CHINESE · COMPLETE FALLBACK"}</span></header>${zh.map(s => `<div class="detail-segment"><time>${fmt(s.startTime)}</time><p>${escapeHTML(s.text)}</p></div>`).join("") || `<p class="list-empty">尚无中文翻译。</p>`}</article></div>
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

  async function renderSummary(generation = state.routeRenderGeneration, route = state.route) {
    breadcrumb.textContent = "复习 / 学习总结";
    if (state.currentLectureID && state.detail?.lecture?.id !== state.currentLectureID) {
      main.innerHTML = `<section class="page loading-page">${selectorHTML()}<p class="list-empty">正在载入所选课堂的总结…</p></section>`;
      try { if (!await loadSelectedDetail()) return; } catch (e) { toast(e.message, true); }
    }
    if (!renderIsCurrent(generation, route) || route !== "summary") return;
    const summary = state.detail?.summaries?.[0]?.content;
    if (!summary) { main.innerHTML = `<section class="page">${selectorHTML()}${empty("这次课堂还没有可读的总结", "结束课堂后，Lecture 会使用这次录音的完整英文稿生成学习资料。", "查看课程历史")}</section>`; return; }
    const list = (title, values) => `<section><h3>${title}</h3><ul>${(values || []).map(v => `<li>${escapeHTML(v)}</li>`).join("") || "<li>暂无</li>"}</ul></section>`;
    main.innerHTML = `<article class="page summary-document">${selectorHTML()}<header><span class="eyebrow">STUDY EDITION</span><h1>${escapeHTML(state.detail.lecture.title)} · 学习总结</h1><p>${escapeHTML(summary.overview)}</p></header><div class="summary-columns">${list("核心概念", summary.coreConcepts)}${list("定义", summary.definitions)}${list("教授举例", summary.professorExamples)}${list("教授强调", summary.professorEmphasis)}${list("可能的考试方向 *", summary.possibleExamTopics)}${list("仍待解决的问题", summary.unresolvedQuestions)}</div><section class="glossary"><h2>双语术语表</h2>${(summary.glossary || []).map(g => `<div><strong>${escapeHTML(g.english)}</strong><span>${escapeHTML(g.chinese)}</span><p>${escapeHTML(g.explanation)}</p></div>`).join("")}</section><small>* 仅为根据课堂内容推测的复习方向，不代表教授承诺的考试范围。</small></article>`;
  }

  async function renderQA(generation = state.routeRenderGeneration, route = state.route) {
    breadcrumb.textContent = "复习 / AI 问答"; const c = course();
    if (!c) { main.innerHTML = empty("先选择一门课程", "问答只会引用你自己的课堂逐字稿。"); return; }
    const lectureScope = state.qaScope === "lecture" && state.currentLectureID;
    const courseID = c.id; const lectureID = lectureScope ? state.currentLectureID : null;
    main.innerHTML = `<section class="page qa-page loading-page">${selectorHTML()}<p class="list-empty">正在载入${lectureScope ? "这次课堂" : "整门课程"}的问答记录…</p></section>`;
    let chat = []; try { chat = await api(`/api/courses/${courseID}/chat${lectureID ? `?lectureID=${lectureID}` : ""}`); } catch {}
    if (!renderIsCurrent(generation, route) || route !== "qa" || course()?.id !== courseID || (lectureScope ? state.currentLectureID !== lectureID : state.qaScope !== "course")) return;
    state.chat = chat;
    const selectedLecture = state.lectures.find(l => l.id === state.currentLectureID);
    main.innerHTML = `<section class="page qa-page">${selectorHTML()}<header class="page-head"><div><span class="eyebrow">GROUNDED Q&A</span><h1>只依据教授说过的话回答。</h1><p>每条回答都应带课堂和时间引用；证据不足时会明确说明。</p></div></header><div class="scope-switch"><button class="${lectureScope ? "" : "is-active"}" data-action="qa-scope:course">整门课程</button><button class="${lectureScope ? "is-active" : ""}" data-action="qa-scope:lecture" ${state.currentLectureID ? "" : "disabled"}>这次课堂</button><span>${escapeHTML(lectureScope ? selectedLecture?.title || c.name : c.name)}</span></div><div class="chat-stream">${state.chat.map(m => `<article class="chat ${m.role}"><span>${m.role === "user" ? "YOU" : "AI"}</span><p>${escapeHTML(m.text)}</p>${(m.citations || []).map(x => `<button data-time="${x.startTime}" data-lecture="${x.lectureID}">${escapeHTML(x.lectureTitle)} · ${fmt(x.startTime)}</button>`).join("")}</article>`).join("") || `<div class="list-empty">例如：教授如何解释这个概念？这节课最重要的三点是什么？</div>`}</div><form id="qa-form" class="question-box"><textarea name="question" required placeholder="向课堂记录提问…"></textarea><button class="button button-primary">${icon("send")}发送</button></form></section>`;
    document.getElementById("qa-form")?.addEventListener("submit", askQuestion);
  }

  function renderSettings() {
    breadcrumb.textContent = "Lecture / 设置与诊断"; const r = state.runtime; const config = state.ai.configuration || {};
    const providerOptions = (state.ai.presets || []).map((preset, index) => `<option value="${index}">${escapeHTML(preset.name)} · ${escapeHTML(preset.model)}</option>`).join("");
    main.innerHTML = `<section class="page settings-page"><header class="page-head"><div><span class="eyebrow">LOCAL DIAGNOSTICS</span><h1>课前，确认一切就绪。</h1><p>Lecture 的录音和英文识别留在本机；AI 服务只接收课堂文字。</p></div></header><div class="diagnostic-list"><div><span>${icon("mic")}麦克风与本地识别</span><strong>${r.speechAvailable ? "可用" : "需要重新安装"}</strong></div><div><span>${icon("external")}英文 → 简体中文</span><strong>${r.translationAvailable ? "可用" : "需要下载离线语言"}</strong>${r.translationAvailable ? "" : button("打开下载页", "translation-settings", "button-quiet")}</div><div><span>${icon("lock")}AI 服务</span><strong>${state.ai.keyConfigured ? `${escapeHTML(config.name || "已配置")} · ${escapeHTML(config.model || "")}` : "还需要 API Key"}</strong></div><div><span>${icon("database")}本地资料库</span><strong>${bytes(state.storage.totalBytes)} · ${state.storage.recordingCount || 0} 份录音</strong></div></div><section class="accuracy-guide"><div><span class="eyebrow">ACCURACY PROTOCOL</span><h2>收音与识别建议</h2></div><ol><li><strong>先改善距离</strong><span>麦克风越靠近教授，收益越大；远距离混响无法完全靠算法修复。</span></li><li><strong>实时草稿与断句</strong><span>本地模型约每 2–3 秒更新草稿；检测到约 0.75 秒停顿时提前确认一句。</span></li><li><strong>Silero VAD</strong><span>课后使用本地语音活动检测过滤静音和常见幻觉；复核稿过少时自动保留实时稿。</span></li><li><strong>外接设备</strong><span>前排指向性麦克风或教授佩戴的无线领夹麦效果最好；麦克风距离比价格更重要。</span></li></ol><p>DeepSeek 或其他聊天模型没有在听音频；它们只处理本地识别后的英文文本，所以不需要音频多模态能力。</p></section><section class="settings-section ai-provider-section"><div><span class="eyebrow">OPENAI-COMPATIBLE AI</span><h2>任意 AI 服务与模型</h2><p>可以使用 DeepSeek、OpenAI、OpenRouter 或本地 OpenAI 兼容服务。远程地址必须是 HTTPS；本地服务可用 127.0.0.1。</p></div><form id="ai-config-form" class="ai-config-form"><label class="field field-wide"><span>快速预设</span><select id="ai-preset"><option value="">自定义</option>${providerOptions}</select></label><label class="field"><span>显示名称</span><input name="name" required value="${escapeHTML(config.name || "")}"></label><label class="field"><span>服务类型</span><select name="providerKind"><option value="deepSeek" ${config.providerKind === "deepSeek" ? "selected" : ""}>DeepSeek</option><option value="openAICompatible" ${config.providerKind === "openAICompatible" ? "selected" : ""}>OpenAI 兼容</option><option value="local" ${config.providerKind === "local" ? "selected" : ""}>本地服务</option></select></label><label class="field field-wide"><span>Base URL</span><input name="baseURL" required spellcheck="false" value="${escapeHTML(config.baseURL || "")}"></label><label class="field field-wide"><span>模型名称</span><input name="model" required spellcheck="false" value="${escapeHTML(config.model || "")}"></label><label class="check-field"><input type="checkbox" name="requiresAPIKey" ${config.requiresAPIKey !== false ? "checked" : ""}><span>需要 API Key</span></label><label class="check-field"><input type="checkbox" name="sendThinkingDisabled" ${config.sendThinkingDisabled ? "checked" : ""}><span>发送 DeepSeek thinking disabled</span></label><label class="check-field"><input type="checkbox" name="supportsJSONResponseFormat" ${config.supportsJSONResponseFormat !== false ? "checked" : ""}><span>支持 JSON response_format</span></label><div class="ai-actions"><button class="button button-primary" type="submit">保存模型设置</button>${button(state.ai.keyConfigured ? "更换 API Key" : "保存 API Key", "key", "button-quiet")} ${button("测试连接", "test-key", "button-quiet")} ${state.ai.keyConfigured && config.requiresAPIKey !== false ? button("删除 Key", "delete-key", "button-danger") : ""}</div><p class="form-note">模型设置与“已配置”状态保存在本地网页/本机配置中；密钥输入一次后由 Lecture 安全保存，网页不会再次索要或显示明文。</p></form></section><section class="settings-section"><div><span class="eyebrow">LOCAL STORAGE</span><h2>本地资料与导出</h2><p>数据目录：~/Library/Application Support/Lecture。API Key 由本机钥匙串保存，因此不用每次输入密码，网页也无法取回明文。</p></div><strong>${bytes(state.storage.recordingBytes)} 录音 · ${bytes(state.storage.databaseBytes)} 历史库</strong></section></section>`;
    const form = document.getElementById("ai-config-form");
    form?.addEventListener("submit", saveAIConfiguration);
    document.getElementById("ai-preset")?.addEventListener("change", event => {
      const preset = state.ai.presets?.[Number(event.target.value)]; if (!preset) return;
      Object.entries(preset).forEach(([key, value]) => { const field = form.elements[key]; if (!field) return; if (field.type === "checkbox") field.checked = Boolean(value); else field.value = value; });
    });
  }

  async function saveAIConfiguration(event) {
    event.preventDefault(); const form = event.currentTarget; const values = new FormData(form);
    const body = { name: values.get("name"), baseURL: values.get("baseURL"), model: values.get("model"), providerKind: values.get("providerKind"), requiresAPIKey: form.elements.requiresAPIKey.checked, sendThinkingDisabled: form.elements.sendThinkingDisabled.checked, supportsJSONResponseFormat: form.elements.supportsJSONResponseFormat.checked };
    try { state.ai = await api("/api/ai/config", { method: "PUT", body: JSON.stringify(body) }); toast("AI 服务与模型设置已保存"); renderSettings(); } catch (e) { toast(e.message, true); }
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
      else if (value.startsWith("lecture:")) { selectLecture(value.split(":")[1]); setRoute("detail"); }
      else if (value.startsWith("qa-course:")) { selectCourse(value.split(":")[1]); state.qaScope = "course"; persistSelection(); setRoute("qa"); }
      else if (value.startsWith("qa-scope:")) { state.qaScope = value.split(":")[1]; persistSelection(); render(); }
      else if (value === "start") {
        if (state.runtime.transitioning || state.runtime.recording) return;
        state.runtime.transitioning = true; state.runtime.transitionKind = "starting"; renderLive();
        const c = course(); if (!c) return; toast("首次使用时，请在系统窗口允许麦克风");
        const lecture = await api("/api/lectures/start", { method: "POST", body: JSON.stringify({ courseID: c.id }) });
        state.lectures = await api("/api/lectures"); selectLecture(lecture.id); state.detail = await api(`/api/lectures/${lecture.id}`); toast("课堂已开始；关闭网页也会继续录音"); await reload();
      }
      else if (value === "stop") {
        if (state.runtime.transitioning || !state.runtime.recording) return;
        state.runtime.transitioning = true; state.runtime.transitionKind = "stopping"; renderLive();
        const lecture = await api("/api/lectures/stop", { method: "POST", body: "{}" }); selectLecture(lecture.id); toast("录音已保存，课后处理已开始"); await reload();
      }
      else if (value === "marker") { await api("/api/markers", { method: "POST", body: JSON.stringify({ label: "课堂重点" }) }); toast("已标记当前时间"); }
      else if (value === "retry") { await api(`/api/lectures/${state.currentLectureID}/retry`, { method: "POST", body: "{}" }); toast("已重新开始课后处理"); }
      else if (value === "key") document.getElementById("key-dialog").showModal();
      else if (value === "test-key") { await api("/api/ai/test", { method: "POST", body: "{}" }); toast("AI 服务连接正常"); }
      else if (value === "translation-settings") { await api("/api/translation/settings", { method: "POST", body: "{}" }); toast("请下载英语（美国）和中文（普通话，简体）"); }
      else if (value === "delete-key") { if (confirm("确定从 macOS 钥匙串删除当前 AI 服务的密钥？")) { await api("/api/ai/key", { method: "DELETE" }); await refreshAIConfiguration(); renderSettings(); } }
      else if (value === "back-history") setRoute("history");
      else if (value === "open-summary") setRoute("summary");
      else if (value === "view-history") setRoute("history");
    } catch (error) { toast(error.message, true); if (value === "start" || value === "stop") await reload().catch(() => null); }
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

  async function askQuestion(event) { event.preventDefault(); const form = new FormData(event.currentTarget); const question = String(form.get("question") || "").trim(); if (!question) return; const lectureID = state.qaScope === "lecture" ? state.currentLectureID : null; try { await api("/api/qa", { method: "POST", body: JSON.stringify({ question, courseID: course().id, lectureID }) }); render(); } catch (e) { toast(e.message, true); } }
  async function reload() {
    state.courses = await api("/api/courses");
    state.lectures = await api("/api/lectures");
    state.runtime = await api("/api/state");
    await Promise.all([refreshStorage(), refreshAIConfiguration()]);
    if (state.runtime.activeLectureID) {
      selectLecture(state.runtime.activeLectureID);
      await loadSelectedDetail();
    } else {
      if (!selectLecture(state.currentLectureID)) {
        if (!selectCourse(state.currentCourseID)) selectCourse(state.courses[0]?.id || null);
      }
      if (state.currentLectureID) await loadSelectedDetail();
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
    if (targetLectureID) selectLecture(targetLectureID);
    if (state.route !== "detail" || requiresLectureChange) {
      setRoute("detail");
      return;
    }
    applyPendingAudioJump();
  });
  document.addEventListener("change", async event => {
    const kind = event.target?.dataset?.select;
    if (kind === "course") { selectCourse(event.target.value); render(); }
    if (kind === "lecture") { selectLecture(event.target.value); render(); }
  });
  document.querySelectorAll("[data-close-dialog]").forEach(b => b.addEventListener("click", () => b.closest("dialog").close()));
  document.getElementById("course-form").addEventListener("submit", saveCourse);
  document.getElementById("delete-course").addEventListener("click", async () => { const id = document.getElementById("course-form").elements.id.value; if (id && confirm("删除课程会同时删除课堂、逐字稿和总结。确定继续？")) { await api(`/api/courses/${id}`, { method: "DELETE" }); document.getElementById("course-dialog").close(); await reload(); } });
  document.getElementById("key-form").addEventListener("submit", async event => { event.preventDefault(); const value = new FormData(event.currentTarget).get("apiKey"); try { await api("/api/ai/key", { method: "POST", body: JSON.stringify({ apiKey: value }) }); event.currentTarget.reset(); document.getElementById("key-dialog").close(); toast("密钥已安全保存并通过连接测试"); await refreshAIConfiguration(); renderSettings(); } catch (e) { toast(e.message, true); } });
  window.addEventListener("hashchange", () => { state.route = location.hash.slice(1) || "live"; render(); });
  document.addEventListener("keydown", e => { if (/^[1-5]$/.test(e.key) && !/INPUT|TEXTAREA|SELECT/.test(e.target.tagName)) setRoute(["live","history","summary","qa","settings"][Number(e.key)-1]); });
  setInterval(() => { const clock = document.getElementById("clock"); const now = new Date(); clock.dateTime = now.toISOString(); clock.textContent = now.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" }); }, 1000);

  bootstrap();
})();
