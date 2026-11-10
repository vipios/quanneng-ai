/* ==========================================================================
   ui.html · 引擎
   职责：把 SPEC（界面规格）+ DATA（数据）渲染成可交互界面，并维护一份
   全局状态 S。任何页面都不持有自己的副本状态 —— 这是「联动」的实现方式。
   ========================================================================== */

(function () {
  "use strict";

  /* ── 小工具 ─────────────────────────────────────────────────── */
  var $ = function (sel, root) { return (root || document).querySelector(sel); };
  var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };
  var clone = function (o) { return JSON.parse(JSON.stringify(o)); };
  var esc = function (s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  };

  /* ── 图标（SF Symbols 的极简替代，全部 24×24 stroke） ────────── */
  var ICONS = {
    key: '<circle cx="8" cy="13" r="4.2"/><path d="M11.2 10.2 20 4M17 6l2.4 2.4M14.6 8l2 2"/>',
    layers: '<path d="M12 3 3 8l9 5 9-5-9-5Z"/><path d="m3 12 9 5 9-5"/><path d="m3 16 9 5 9-5"/>',
    chart: '<path d="M4 20V9M10 20V4M16 20v-7M22 20H2"/>',
    server: '<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01"/>',
    wifi: '<path d="M2.5 9a15 15 0 0 1 19 0M6 12.5a10 10 0 0 1 12 0M9.5 16a5 5 0 0 1 5 0"/><circle cx="12" cy="19.5" r="1"/>',
    brush: '<path d="M14 4.5 19.5 10 11 18.5 5.5 13 14 4.5Z"/><path d="M5.5 13 3 21l8-2.5"/>',
    glass: '<rect x="4" y="3" width="16" height="18" rx="4"/><path d="M8 7.5h8M8 12h5" opacity=".7"/>',
    wrench: '<path d="M20 5.5a5 5 0 0 1-6.6 6.6L6 19.5a2.1 2.1 0 0 1-3-3l7.4-7.4A5 5 0 0 1 17 2.5l-3 3 2.5 2.5 3-3Z"/>',
    people: '<circle cx="9" cy="8" r="3.2"/><path d="M3 20c0-3.3 2.7-5.4 6-5.4s6 2.1 6 5.4"/><path d="M16.5 6.4a3 3 0 0 1 0 5.6M18 20c0-2.3-.9-4-2.4-5"/>',
    puzzle: '<path d="M10 4.5a2 2 0 1 1 4 0V6h2.5a1.5 1.5 0 0 1 1.5 1.5V10h1.5a2 2 0 1 1 0 4H18v2.5a1.5 1.5 0 0 1-1.5 1.5H14v-1.5a2 2 0 1 0-4 0V18H7.5A1.5 1.5 0 0 1 6 16.5V14H4.5a2 2 0 1 1 0-4H6V7.5A1.5 1.5 0 0 1 7.5 6H10V4.5Z"/>',
    sparkles: '<path d="M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9L12 3Z"/><path d="M18.5 15.5l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8.8-2.2Z"/>',
    brain: '<path d="M12 5.5A3 3 0 0 0 9 3a3 3 0 0 0-3 3 3 3 0 0 0-1.5 5.5A3 3 0 0 0 6 17a3 3 0 0 0 3 3 3 3 0 0 0 3-2.5V5.5Z"/><path d="M12 5.5A3 3 0 0 1 15 3a3 3 0 0 1 3 3 3 3 0 0 1 1.5 5.5A3 3 0 0 1 18 17a3 3 0 0 1-3 3 3 3 0 0 1-3-2.5"/>',
    stack: '<path d="M12 3 3 7.5 12 12l9-4.5L12 3Z"/><path d="M3 12l9 4.5 9-4.5"/><path d="M3 16.5 12 21l9-4.5"/>',
    terminal: '<rect x="3" y="4" width="18" height="16" rx="2.5"/><path d="m7 10 2.5 2.5L7 15M12.5 15.5H17"/>',
    archive: '<rect x="3" y="4" width="18" height="5" rx="1.5"/><path d="M4.5 9v9.5A1.5 1.5 0 0 0 6 20h12a1.5 1.5 0 0 0 1.5-1.5V9"/><path d="M9.5 13h5"/>',
    folder: '<path d="M3 7.5A1.5 1.5 0 0 1 4.5 6h4l2 2.5h9A1.5 1.5 0 0 1 21 10v7.5a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17.5v-10Z"/>',
    drive: '<rect x="3" y="6" width="18" height="12" rx="2"/><circle cx="7.5" cy="12" r="1.2"/><path d="M12 10.5h5M12 13.5h5"/>',
    cloud: '<path d="M7 18h10a4 4 0 0 0 .6-8 5.6 5.6 0 0 0-10.5 1.4A3.4 3.4 0 0 0 7 18Z"/>',
    clock: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3.2 2"/>',
    github: '<path d="M9 20v-2.4c-3 .5-3.8-1.4-3.8-1.4-.5-1.2-1.2-1.6-1.2-1.6-1-.7 0-.7 0-.7 1.1 0 1.7 1.2 1.7 1.2 1 1.7 2.6 1.2 3.2.9.1-.7.4-1.2.7-1.5-2.4-.3-4.9-1.2-4.9-5.3 0-1.2.4-2.1 1.1-2.9-.1-.3-.5-1.4.1-2.8 0 0 .9-.3 3 1.1a10 10 0 0 1 5.4 0c2.1-1.4 3-1.1 3-1.1.6 1.4.2 2.5.1 2.8.7.8 1.1 1.7 1.1 2.9 0 4.1-2.5 5-4.9 5.3.4.4.8 1.1.8 2.2V20"/>',
    shield: '<path d="M12 3 5 6v5.5c0 4.2 2.9 7.7 7 9.5 4.1-1.8 7-5.3 7-9.5V6l-7-3Z"/><path d="m9.2 12 2 2 3.6-3.8"/>',
    face: '<path d="M4 8V6a2 2 0 0 1 2-2h2M20 8V6a2 2 0 0 0-2-2h-2M4 16v2a2 2 0 0 0 2 2h2M20 16v2a2 2 0 0 1-2 2h-2"/><path d="M9 10v1.5M15 10v1.5M9.5 15.5c1.6 1 3.4 1 5 0"/>',
    doc: '<path d="M6 3h7l5 5v13H6V3Z"/><path d="M13 3v5h5"/><path d="M9 13h6M9 16.5h4"/>',
    bug: '<rect x="7" y="7" width="10" height="12" rx="5"/><path d="M12 7V4M9 4.5 10.5 6M15 4.5 13.5 6M4 11h3M17 11h3M4 15h3M17 15h3M9 19l-1.5 2M15 19l1.5 2"/>',
    check: '<circle cx="12" cy="12" r="8.5"/><path d="m8.2 12.2 2.6 2.6 5-5.4"/>',
    info: '<circle cx="12" cy="12" r="8.5"/><path d="M12 11v5.5M12 8h.01"/>',
    refresh: '<path d="M20 12a8 8 0 1 1-2.4-5.7"/><path d="M20 4v4h-4"/>',
    globe: '<circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17M12 3.5c2.5 2.4 2.5 14.1 0 17M12 3.5c-2.5 2.4-2.5 14.1 0 17"/>',
    mail: '<rect x="3" y="5.5" width="18" height="13" rx="2.5"/><path d="m4 7.5 8 5.5 8-5.5"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    bolt: '<path d="M13.5 3 5 13.5h5.5L10 21l8.5-10.5H13L13.5 3Z"/>',
    download: '<path d="M12 4v11M7.5 11 12 15.5 16.5 11"/><path d="M5 19h14"/>',
    trash: '<path d="M5 7h14M9.5 7V5h5v2M7 7l1 13h8l1-13"/><path d="M10.5 11v5.5M13.5 11v5.5"/>',
    ban: '<circle cx="12" cy="12" r="8.5"/><path d="m6.5 17.5 11-11"/>',
    cpu: '<rect x="7" y="7" width="10" height="10" rx="2"/><path d="M10 3v4M14 3v4M10 17v4M14 17v4M3 10h4M3 14h4M17 10h4M17 14h4"/>',
    search: '<circle cx="11" cy="11" r="6"/><path d="m15.6 15.6 4.4 4.4"/>',
    chevron: '<path d="m9.5 6 6 6-6 6"/>',
    back: '<path d="M15 5 8 12l7 7"/>',
    close: '<path d="M6 6l12 12M18 6 6 18"/>',
    send: '<path d="M12 20V5M6 11l6-6 6 6"/>',
    mic: '<rect x="9" y="3" width="6" height="10" rx="3"/><path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21"/>',
    clip: '<path d="M9 12.5 15 6.5a3.2 3.2 0 0 1 4.5 4.5l-8 8a5 5 0 0 1-7-7l8-8"/>',
    image: '<rect x="3" y="4.5" width="18" height="15" rx="2.5"/><circle cx="8.5" cy="10" r="1.6"/><path d="m4 17 5-4.5 4 3.5 3-2.5 4 3.5"/>',
    play: '<circle cx="12" cy="12" r="8.5"/><path d="M10 8.5 16 12l-6 3.5v-7Z"/>',
    pin: '<path d="M9 3h6l-.8 5.2 3.3 3.3H6.5l3.3-3.3L9 3Z"/><path d="M12 11.5V21"/>',
    gear: '<circle cx="12" cy="12" r="3.2"/><path d="M12 3v2.4M12 18.6V21M4.2 7.5l2.1 1.2M17.7 15.3l2.1 1.2M4.2 16.5l2.1-1.2M17.7 8.7l2.1-1.2"/>',
    more: '<circle cx="6" cy="12" r="1.4"/><circle cx="12" cy="12" r="1.4"/><circle cx="18" cy="12" r="1.4"/>',
    menu: '<path d="M4 7h16M4 12h16M4 17h10"/>',
    star: '<path d="m12 3.5 2.6 5.4 5.9.8-4.3 4.2 1 5.9-5.2-2.8-5.2 2.8 1-5.9L3.5 9.7l5.9-.8L12 3.5Z"/>',
    eye: '<path d="M2.5 12S6 6.5 12 6.5 21.5 12 21.5 12 18 17.5 12 17.5 2.5 12 2.5 12Z"/><circle cx="12" cy="12" r="2.6"/>'
  };

  function icon(name, size) {
    var p = ICONS[name] || ICONS.info;
    return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" ' +
      'stroke-linecap="round" stroke-linejoin="round"' + (size ? ' style="width:' + size + 'px;height:' + size + 'px"' : '') +
      '>' + p + '</svg>';
  }

  /* ── 状态 ────────────────────────────────────────────────────── */
  var SPEC = window.__SPEC__;
  var DATA = window.__DATA__;
  var DEFAULTS = window.__DEFAULTS__ || {};
  var S = clone(DEFAULTS);
  var derived = {};

  function get(path, root) {
    if (!path) return undefined;
    var parts = String(path).split(".");
    var cur = root === undefined ? S : root;
    for (var i = 0; i < parts.length; i++) {
      if (cur == null) return undefined;
      cur = cur[parts[i]];
    }
    return cur;
  }

  function set(path, val) {
    var parts = String(path).split(".");
    var cur = S;
    for (var i = 0; i < parts.length - 1; i++) {
      if (typeof cur[parts[i]] !== "object" || cur[parts[i]] === null) cur[parts[i]] = {};
      cur = cur[parts[i]];
    }
    cur[parts[parts.length - 1]] = val;
  }

  function getData(path) {
    var parts = String(path).split(".");
    var cur = DATA;
    for (var i = 0; i < parts.length; i++) {
      if (cur == null) return undefined;
      cur = cur[parts[i]];
    }
    return cur;
  }

  function getSession() {
    var list = DATA.sessions || [];
    for (var i = 0; i < list.length; i++) {
      if (list[i].id === S.session) return list[i];
    }
    return list[0] || null;
  }

  /* ── 派生量：任何状态变化都重算，供 {{}} 占位符读取 ──────────── */
  function recompute() {
    var on = function (o) { return o ? Object.keys(o).filter(function (k) { return o[k]; }).length : 0; };
    var total = function (o) { return o ? Object.keys(o).length : 0; };
    var cur = getSession();
    derived = {
      toolsOn: on(S.prefs.tools), toolsTotal: total(S.prefs.tools),
      skillsOn: on(S.prefs.skills), skillsTotal: total(S.prefs.skills),
      mcpOn: on(S.prefs.mcp), mcpTotal: total(S.prefs.mcp),
      subOn: on(S.prefs.subAgents), subTotal: total(S.prefs.subAgents),
      model: S.prefs.model,
      theme: S.prefs.theme, accent: S.prefs.accent,
      size: S.prefs.textSize, density: S.prefs.density,
      sessionTitle: cur ? cur.title : "新任务",
      sessionCount: (DATA.sessions || []).length
    };
  }

  function interp(str) {
    if (typeof str !== "string" || str.indexOf("{{") < 0) return str;
    return str.replace(/\{\{\s*([\w.]+)\s*\}\}/g, function (_, p) {
      var v = get(p, derived);
      if (v === undefined) v = get(p);
      if (v === undefined) v = getData(p);
      return v === undefined || v === null ? "" : String(v);
    });
  }

  /* ── 主题落地（唯一写 CSS 变量的地方） ─────────────────────── */
  function applyPrefs() {
    var h = document.documentElement;
    var t = S.prefs.theme;
    var dark = t === "深色" || (t === "跟随系统" && window.matchMedia &&
      window.matchMedia("(prefers-color-scheme: dark)").matches);
    h.setAttribute("data-theme", dark ? "dark" : "light");
    h.setAttribute("data-accent", S.prefs.accent);
    h.setAttribute("data-size", S.prefs.textSize);
    h.setAttribute("data-density", S.prefs.density);
    h.setAttribute("data-motion", S.prefs.reduceMotion ? "off" : "on");
    document.body.style.setProperty("--bg-tint", "transparent");
    var bg = S.prefs.bg || {};
    if (bg.material === "液态玻璃") {
      document.body.style.background =
        "radial-gradient(120% 80% at 20% 0%, hsl(" + accentHue() + " 90% 62% / .18), transparent 60%)," +
        "radial-gradient(120% 70% at 90% 10%, hsl(" + ((accentHue() + 60) % 360) + " 90% 60% / .14), transparent 55%)";
    } else if (bg.material === "图片") {
      document.body.style.background = "linear-gradient(160deg,#243b55,#141e30)";
    } else {
      document.body.style.background = "";
    }
  }

  function accentHue() {
    var m = { "蓝": 211, "青": 188, "绿": 145, "橙": 30, "粉": 336, "紫": 272 };
    return m[S.prefs.accent] || 211;
  }

  /* ── 渲染：通用块 ────────────────────────────────────────────── */

  function bindAttr(path, kind) {
    return ' data-bind="' + esc(path) + '" data-kind="' + kind + '"';
  }

  function rowIcon(r) {
    if (!r.icon) return "";
    return '<span class="r-ico c-' + esc(r.color || "gray") + '">' + icon(r.icon) + "</span>";
  }

  function renderRow(r) {
    var cls = "row" + (r.icon ? " has-icon" : "");
    var inner = rowIcon(r);
    inner += '<span class="r-body">';
    inner += '<span class="r-title' + (r.mono ? " mono" : "") + '" data-title-for="' + esc(r.renameId || "") + '">' + esc(interp(r.title)) + "</span>";
    if (r.sub) inner += '<span class="r-sub">' + esc(interp(r.sub)) + "</span>";
    inner += "</span>";

    if (r.kind === "toggle") {
      var on = !!get(r.bind);
      return '<button class="' + cls + '" data-act="toggle" data-arg="' + esc(r.bind) + '"' +
        ' data-id="' + esc(r.renameId || "") + '" data-name="' + esc(r.title) + '">' + inner +
        '<span class="sw" data-on="' + (on ? 1 : 0) + '"' + bindAttr(r.bind, "toggle") + "></span></button>";
    }
    if (r.badge) inner = inner.replace("</span></span>", '</span><span class="r-badge">' + esc(interp(r.badge)) + "</span></span>");
    if (r.value) inner += '<span class="r-val' + (r.mono ? " mono" : "") + '">' + esc(interp(r.value)) + "</span>";
    if (r.kind === "nav") {
      inner += '<span class="chev">' + icon("chevron") + "</span>";
      return '<button class="' + cls + '" data-act="nav" data-arg="' + esc(r.page) + '"' +
        ' data-id="' + esc(r.renameId || "") + '" data-name="' + esc(r.title) + '">' + inner + "</button>";
    }
    return '<div class="' + cls + '">' + inner + "</div>";
  }

  function renderList(b) {
    var items = getData(b.src) || [];
    var id = "list-" + b.src.replace(/\W/g, "-");
    var html = '<div class="section"><div class="sec-title" data-list-title="' + esc(b.src) + '"></div>' +
      '<div class="card list-card" id="' + id + '" data-src="' + esc(b.src) + '"></div></div>';
    return html;
  }

  function paintList(container, b, query) {
    var items = getData(b.src) || [];
    var q = (query || "").toLowerCase();
    if (q) {
      items = items.filter(function (it) {
        var hay = (it[b.key] || "") + " " + (it.sub || "") + " " + (it.name || "");
        return String(hay).toLowerCase().indexOf(q) >= 0;
      });
    }
    var card = container.querySelector(".list-card");
    if (!card) return;
    var titleEl = container.querySelector("[data-list-title]");
    if (titleEl) titleEl.textContent = q ? "匹配 " + items.length + " 项" : (b.listTitle || "");
    if (!items.length) {
      card.innerHTML = '<div class="empty"><div class="e-ico">' + icon("search") + "</div>" +
        "<h3>" + esc(b.emptyTitle || "空") + "</h3><p>" + esc(b.emptySub || "") + "</p></div>";
      return;
    }
    card.innerHTML = items.map(function (it) {
      var r = {
        kind: it.page ? "nav" : (it.toggle ? "toggle" : "value"),
        title: fill(it, b.item.title), sub: fill(it, b.item.sub),
        badge: b.item.badge ? fill(it, b.item.badge) : "",
        value: b.item.value ? fill(it, b.item.value) : "",
        icon: b.item.icon || "doc", color: b.item.color || "blue",
        mono: !!b.item.mono, page: it.page || "",
        bind: it.toggle ? fill(it, b.item.toggle) : ""
      };
      return renderRow(r);
    }).join("");
  }

  function fill(item, tpl) {
    if (!tpl) return "";
    return String(tpl).replace(/@(\w+)/g, function (_, k) {
      return item[k] === undefined || item[k] === null ? "" : item[k];
    });
  }

  function renderBlock(b) {
    switch (b.t) {
      case "hero":
        return '<div class="hero"><h1>' + esc(b.title) + "</h1>" +
          (b.sub ? "<p>" + esc(b.sub) + "</p>" : "") + "</div>";

      case "section":
        if (!b.rows || !b.rows.length) return "";
        return '<div class="section">' +
          (b.title ? '<div class="sec-title">' + esc(b.title) + "</div>" : "") +
          '<div class="card">' + b.rows.map(renderRow).join("") + "</div>" +
          (b.footer ? '<div class="sec-footer">' + esc(b.footer) + "</div>" : "") + "</div>";

      case "list":
        return renderList(b);

      case "seg":
        return '<div class="seg-wrap"><div class="seg-label">' + esc(b.title) + "</div>" +
          '<div class="seg">' + b.options.map(function (o) {
            return '<button data-act="seg" data-arg="' + esc(b.bind) + '" data-val="' + esc(o) + '"' +
              ' data-sel="' + (get(b.bind) === o ? 1 : 0) + '"' + bindAttr(b.bind, "seg") +
              ">" + esc(o) + "</button>";
          }).join("") + "</div>" +
          (b.sub ? '<div class="seg-sub">' + esc(b.sub) + "</div>" : "") + "</div>";

      case "slider":
        return '<div class="sl-wrap"><div class="sl-head"><b>' + esc(b.title) + "</b>" +
          '<span data-slv="' + esc(b.bind) + '">' + esc(String(get(b.bind))) + esc(b.unit || "") + "</span></div>" +
          '<input type="range" min="' + b.lo + '" max="' + b.hi + '" step="' + b.step + '" value="' + get(b.bind) + '"' +
          ' data-act="slide" data-arg="' + esc(b.bind) + '" data-unit="' + esc(b.unit || "") + '"' +
          bindAttr(b.bind, "slider") + "></div>";

      case "field":
        return '<div class="fld-wrap' + (b.mono ? " mono" : "") + '">' +
          '<div class="fld-label">' + esc(b.title) + "</div>" +
          '<input type="' + (b.secure ? "password" : "text") + '" placeholder="' + esc(b.ph || "") + '"' +
          ' value="' + esc(get(b.bind) || "") + '" data-act="field" data-arg="' + esc(b.bind) + '"' +
          bindAttr(b.bind, "field") + "></div>";

      case "picker":
        return '<div class="seg-wrap"><div class="seg-label">' + esc(b.title) + "</div>" +
          '<div class="seg">' + b.options.map(function (o) {
            return '<button data-act="seg" data-arg="' + esc(b.bind) + '" data-val="' + esc(o) + '"' +
              ' data-sel="' + (get(b.bind) === o ? 1 : 0) + '"' + bindAttr(b.bind, "seg") + ">" +
              esc(o) + "</button>";
          }).join("") + "</div>" +
          (b.sub ? '<div class="seg-sub">' + esc(b.sub) + "</div>" : "") + "</div>";

      case "btn":
        return '<div class="btn-row"><button class="btn ' + esc(b.kind === "plain" ? "" : b.kind) + '"' +
          ' data-act="cmd" data-arg="' + esc(b.action) + '" data-x="' + esc(b.arg) + '">' +
          (b.icon ? icon(b.icon) : "") + esc(b.title) + "</button></div>";

      case "text":
        return '<p class="txt ' + (b.muted ? "muted" : "") + " " + (b.size === "small" ? "small" : "") + '">' +
          esc(b.text) + "</p>";

      case "note":
        return '<div class="note">' + esc(b.text) + "</div>";

      case "code":
        return '<pre class="code">' + esc(b.text) + "</pre>";

      case "stat":
        return '<div class="stat">' + b.items.map(function (it) {
          return '<div class="s-item"><div class="s-k">' + esc(it.k) + '</div><div class="s-v">' +
            esc(it.v) + "</div></div>";
        }).join("") + "</div>";

      case "prog":
        return '<div class="prog ' + esc(b.color === "blue" ? "" : b.color) + '">' +
          '<div class="p-head"><b>' + esc(b.label) + "</b><span>" + esc(b.value || b.pct + "%") + "</span></div>" +
          '<div class="p-bar"><i class="p-fill" style="width:' + b.pct + '%"></i></div></div>';

      case "bars":
        var series = getData(b.series) || [];
        var max = Math.max.apply(null, series.concat([1]));
        return '<div class="bars"><div class="b-label">' + esc(b.label || "") + '</div><div class="b-row">' +
          series.map(function (v) {
            return '<div class="b-col" style="height:' + Math.round(v / max * 100) + '%"></div>';
          }).join("") + "</div></div>";

      case "swatches":
        var cols = [["蓝", "#0a84ff"], ["青", "#30b0c7"], ["绿", "#34c759"],
                    ["橙", "#ff9f0a"], ["粉", "#ff2d55"], ["紫", "#5e5ce6"]];
        return '<div class="swatches"><div class="s-title">' + esc(b.title) + '</div><div class="s-row">' +
          cols.map(function (c) {
            return '<button class="swatch" style="background:' + c[1] + '" data-act="accent" data-val="' +
              c[0] + '" data-sel="' + (S.prefs.accent === c[0] ? 1 : 0) + '"></button>';
          }).join("") + "</div></div>";

      case "textarea":
        return '<div class="fld-wrap"><div class="fld-label">' + esc(b.title) + "</div>" +
          '<textarea placeholder="' + esc(b.ph || "") + '" data-act="field" data-arg="' + esc(b.bind) + '"' +
          bindAttr(b.bind, "field") + ">" + esc(get(b.bind) || "") + "</textarea></div>";

      case "storageItems":
        return '<div class="st-items">' + (getData(b.src) || []).map(function (it) {
          return '<div class="st-item"><span class="st-name">' + esc(it.name) + "</span>" +
            '<span class="st-bar"><i style="width:' + Math.min(100, it.pct * 4) + '%"></i></span>' +
            '<span class="st-size">' + esc(it.size) + "</span></div>";
        }).join("") + "</div>";

      case "logs":
        return '<div class="logs">' + (getData(b.src) || []).map(function (l) {
          return '<div class="log"><span class="l-t">' + esc(l.t) + "</span>" +
            '<span class="l-lvl ' + esc(l.lvl) + '">' + esc(l.lvl.toUpperCase()) + "</span>" +
            '<span class="l-mod">' + esc(l.mod) + "</span>" +
            '<span class="l-msg">' + esc(l.msg) + "</span></div>";
        }).join("") + "</div>";

      case "term":
        var lines = getData(b.src) || [];
        return '<div class="term">' + lines.map(function (l) {
          var isPrompt = String(l).indexOf("$ ") === 0;
          return '<span class="' + (isPrompt ? "t-prompt" : "t-dim") + '">' + esc(l) + "</span>";
        }).join("\n") + "</div>";

      case "empty":
        return '<div class="empty"><div class="e-ico">' + icon("archive") + "</div>" +
          "<h3>" + esc(b.title) + "</h3>" + (b.sub ? "<p>" + esc(b.sub) + "</p>" : "") + "</div>";

      case "chat":
        return '<div class="chat-wrap" id="chatWrap"></div>';

      default:
        return "";
    }
  }

  /* ── 对话页 ──────────────────────────────────────────────────── */
  function renderChat() {
    var wrap = $("#chatWrap");
    if (!wrap) return;
    var msgs = DATA.messages || [];
    var html = '<div class="chat-scroll" id="chatScroll">';
    msgs.forEach(function (m) {
      if (m.role === "user") {
        html += '<div class="turn user"><div class="bubble-user">' + esc(m.text) + "</div></div>";
      } else {
        html += '<div class="turn assistant"><div class="a-head">' +
          '<span class="a-avatar">' + icon("sparkles") + "</span>" +
          '<span class="a-name">' + esc(S.prefs.model) + "</span></div>" +
          '<div class="a-body">';
        (m.blocks || []).forEach(function (b) {
          if (b.k === "text") html += '<p class="a-text">' + mdInline(b.text) + "</p>";
          else if (b.k === "code") html += '<pre class="blk-code">' + esc(b.text) + "</pre>";
          else if (b.k === "tool") {
            html += '<div class="tool-card"><div class="tool-head">' +
              '<span class="tool-ico">' + icon("terminal") + "</span>" +
              '<span class="tool-name">' + esc(b.name) + "</span>" +
              '<span class="tool-title">' + esc(b.title) + "</span>" +
              '<span class="tool-state">' + esc(b.status === "ok" ? "OK" : b.status) + "</span></div>" +
              '<pre class="tool-body">' + esc(b.body) + "</pre></div>";
          }
        });
        html += "</div></div>";
      }
    });
    if (window.__thinking) {
      html += '<div class="turn assistant"><div class="a-head">' +
        '<span class="a-avatar">' + icon("sparkles") + "</span>" +
        '<span class="a-name">' + esc(S.prefs.model) + "</span></div>" +
        '<div class="a-body"><p class="a-text" style="color:var(--muted)">正在处理…</p></div></div>';
    }
    html += "</div>";
    html += composerHtml();
    wrap.innerHTML = html;

    var sc = $("#chatScroll");
    if (sc) sc.scrollTop = sc.scrollHeight;

    var ta = $("#chatInput");
    if (ta) {
      ta.addEventListener("input", function () {
        ta.style.height = "auto";
        ta.style.height = Math.min(96, ta.scrollHeight) + "px";
        var b = $("#sendBtn");
        if (b) b.disabled = !ta.value.trim();
      });
      ta.addEventListener("keydown", function (e) {
        if (e.key === "Enter" && !e.shiftKey && window.innerWidth > 700) {
          e.preventDefault(); sendMessage();
        }
      });
    }
  }

  function mdInline(t) {
    return esc(t).replace(/`([^`]+)`/g, "<code>$1</code>");
  }

  function composerHtml() {
    var toolsOn = Object.keys(S.prefs.tools).filter(function (k) { return S.prefs.tools[k]; });
    var chips = '<div class="chips">' +
      '<button class="chip model" data-act="nav" data-arg="session-model">' + icon("layers") +
      esc(S.prefs.model) + "</button>" +
      '<button class="chip" data-act="nav" data-arg="agent-tools">' + icon("wrench") +
      "工具 " + toolsOn.length + "</button>" +
      '<button class="chip" data-act="nav" data-arg="mcp">' + icon("stack") +
      "MCP " + Object.keys(S.prefs.mcp).filter(function (k) { return S.prefs.mcp[k]; }).length + "</button>" +
      '<button class="chip" data-act="nav" data-arg="skills">' + icon("puzzle") +
      "技能 " + Object.keys(S.prefs.skills).filter(function (k) { return S.prefs.skills[k]; }).length + "</button>" +
      "</div>";
    return '<div class="composer">' + chips +
      '<div class="input-bar"><div class="input-shell">' +
      '<textarea id="chatInput" rows="1" placeholder="问点什么，或者让它动手"></textarea>' +
      '<button class="ib-btn" data-act="cmd" data-arg="attach">' + icon("clip") + "</button>" +
      '<button class="ib-btn" data-act="cmd" data-arg="voice">' + icon("mic") + "</button></div>" +
      '<button class="send-btn" id="sendBtn" data-act="cmd" data-arg="send" disabled>' +
      icon("send") + "</button></div></div>";
  }

  function sendMessage() {
    var ta = $("#chatInput");
    if (!ta) return;
    var v = ta.value.trim();
    if (!v) return;
    DATA.messages = DATA.messages || [];
    DATA.messages.push({ role: "user", text: v });
    ta.value = "";
    window.__thinking = true;
    renderChat();
    toast("已发送");
    setTimeout(function () {
      window.__thinking = false;
      DATA.messages.push({
        role: "assistant",
        blocks: [{ k: "text", text: "收到：\u201c" + v + "\u201d。这条是从模板里发出去的，真实发送由原生层接管。" }]
      });
      renderChat();
    }, 700);
  }

  /* ── 页面渲染 ────────────────────────────────────────────────── */
  function currentScreen() {
    var id = S.ui.page || "home";
    return { id: id, def: SPEC.screens[id] || SPEC.screens.home };
  }

  function renderMain() {
    var cur = currentScreen();
    var def = cur.def;
    var host = $("#mainScreen");
    if (!host) return;
    var chrome = def.chrome || "page";
    var body = '<div class="scroll">' + (def.blocks || []).map(renderBlock).join("") + "</div>";
    if (chrome === "chat") body = (def.blocks || []).map(renderBlock).join("");

    var hasHero = (def.blocks || []).some(function (b) { return b.t === "hero"; });
    host.innerHTML =
      '<div class="navbar">' +
      (S.ui.stack.length ? '<button class="nb-btn" data-act="back">' + icon("back") + "</button>"
                         : '<button class="nb-btn ghost" data-act="drawer">' + icon("menu") + "</button>") +
      '<div class="nb-title">' + (hasHero ? "" : esc(interp(def.title || ""))) + "</div>" +
      '<div class="nb-right">' +
      (chrome === "chat"
        ? '<button class="nb-btn" data-act="nav" data-arg="artifacts">' + icon("archive") + "</button>" +
          '<button class="nb-btn" data-act="sheet" data-arg="settings">' + icon("gear") + "</button>"
        : '<button class="nb-btn" data-act="cmd" data-arg="more">' + icon("more") + "</button>") +
      "</div></div>" + body;

    if (chrome === "chat") renderChat();
    $$("[data-src]", host).forEach(function (el) {
      var src = el.getAttribute("data-src");
      var blk = (def.blocks || []).filter(function (b) { return b.t === "list" && b.src === src; })[0];
      if (blk) paintList(el.closest(".section"), blk, "");
    });
    syncBound();
  }

  function renderSheet() {
    var def = SPEC.screens[S.ui.sheet];
    var layer = $("#sheetLayer");
    if (!def) { layer.innerHTML = ""; return; }
    var sub = S.ui.sheetStack.length ? SPEC.screens[S.ui.sheetStack[S.ui.sheetStack.length - 1]] : def;
    var title = S.ui.sheetStack.length ? sub.title : def.title;
    layer.innerHTML = '<div class="s-scrim" data-act="closeSheet"></div>' +
      '<div class="sheet"><div class="grabber"></div>' +
      '<div class="navbar" style="padding-top:6px">' +
      '<button class="nb-btn" data-act="' + (S.ui.sheetStack.length ? "sheetBack" : "closeSheet") + '">' +
      icon(S.ui.sheetStack.length ? "back" : "close") + "</button>" +
      '<div class="nb-title">' + ((((sub ? sub.blocks : []) || []).some(function (b) { return b.t === "hero"; })) ? "" : esc(title)) + "</div>" +
      '<div class="nb-right"><button class="nb-btn ghost" data-act="cmd" data-arg="more">' +
      icon("more") + "</button></div></div>" +
      '<div class="scroll" style="padding-bottom:40px">' +
      ((sub ? sub.blocks : []) || []).map(renderBlock).join("") + "</div></div>";

    $$("[data-src]", layer).forEach(function (el) {
      var src = el.getAttribute("data-src");
      var blk = ((sub ? sub.blocks : []) || []).filter(function (b) { return b.t === "list" && b.src === src; })[0];
      if (blk) paintList(el.closest(".section"), blk, "");
    });
    syncBound();
  }

  /* ── 抽屉 ────────────────────────────────────────────────────── */
  function renderDrawer() {
    var d = SPEC.drawer;
    var host = $("#drawer");
    if (!host) return;
    host.style.width = d.width + "px";
    var groups = {};
    (DATA.sessions || []).forEach(function (s) {
      var g = s.pinned ? (d.groups[0]) : s.day;
      (groups[g] = groups[g] || []).push(s);
    });
    var order = d.groups;
    var html = '<div class="d-head"><div class="d-top">' +
      '<div class="d-title">对话</div>' +
      '<button class="d-gear" data-act="sheet" data-arg="settings">' + icon("gear") + "</button></div>" +
      '<div class="d-search">' + icon("search") +
      '<input id="dSearch" placeholder="' + esc(d.searchPlaceholder) + '"></div></div>';

    html += '<div class="d-list" id="dList"></div>';

    html += '<div class="d-foot">' +
      d.footer.map(function (f) {
        return '<button class="d-row" data-act="nav" data-arg="' + f.id + '">' +
          '<span class="d-ico">' + icon(f.icon) + "</span>" +
          '<span class="d-body"><span class="d-name">' + esc(f.title) + "</span></span></button>";
      }).join("") +
      '<button class="d-primary" data-act="cmd" data-arg="new-chat">' +
      icon(d.primary.icon) + esc(d.primary.title) + "</button></div>";

    host.innerHTML = html;
    paintDrawerList("");

    var inp = $("#dSearch");
    if (inp) {
      inp.addEventListener("input", function () { paintDrawerList(inp.value); });
      inp.addEventListener("focus", function () { inp.select(); });
    }
  }

  function paintDrawerList(q) {
    var list = $("#dList");
    if (!list) return;
    var d = SPEC.drawer;
    var query = (q || "").trim().toLowerCase();

    if (query) {
      var sessions = (DATA.sessions || []).filter(function (s) {
        return (s.title + " " + (s.preview || "") + " " + (s.folder || "")).toLowerCase().indexOf(query) >= 0;
      });
      var arts = (DATA.artifacts || []).filter(function (a) {
        return (a.name + " " + a.session).toLowerCase().indexOf(query) >= 0;
      });
      var h = '<div class="d-hits">';
      h += '<div class="d-hit-k">对话 · ' + sessions.length + "</div>";
      h += sessions.length ? sessions.map(function (s) {
        return '<button class="d-row" data-act="open-session" data-arg="' + s.id + '">' +
          '<span class="d-ico">' + icon("doc") + "</span>" +
          '<span class="d-body"><span class="d-name">' + hl(s.title, query) + "</span>" +
          '<span class="d-sub">' + hl(s.preview || "", query) + "</span></span>" +
          '<span class="d-right"><span class="d-time">' + esc(s.time) + "</span></span></button>";
      }).join("") : '<div class="d-hit"><span class="h-t" style="color:var(--muted)">没有匹配</span></div>';
      h += '<div class="d-hit-k">产物 · ' + arts.length + "</div>";
      h += arts.length ? arts.map(function (a) {
        return '<button class="d-row" data-act="nav" data-arg="artifacts">' +
          '<span class="d-ico">' + icon("archive") + "</span>" +
          '<span class="d-body"><span class="d-name">' + hl(a.name, query) + "</span>" +
          '<span class="d-sub">' + esc(a.session) + "</span></span>" +
          '<span class="d-right"><span class="d-time">' + esc(a.size) + "</span></span></button>";
      }).join("") : '<div class="d-hit"><span class="h-t" style="color:var(--muted)">没有匹配</span></div>';
      h += "</div>";
      list.innerHTML = h;
      return;
    }

    var groups = {};
    (DATA.sessions || []).forEach(function (s) {
      var g = s.pinned ? d.groups[0] : s.day;
      (groups[g] = groups[g] || []).push(s);
    });
    list.innerHTML = d.groups.map(function (g) {
      var arr = groups[g];
      if (!arr || !arr.length) return "";
      return '<div class="d-group">' + esc(g) + "</div>" + arr.map(function (s) {
        var active = s.id === S.session;
        var name = S.sessionNames && S.sessionNames[s.id] ? S.sessionNames[s.id] : s.title;
        return '<button class="d-row" data-act="open-session" data-arg="' + s.id + '"' +
          ' data-active="' + (active ? 1 : 0) + '" data-rename="' + s.id + '"' +
          ' data-name="' + esc(s.title) + '">' +
          '<span class="d-ico">' + icon(s.artifacts ? "archive" : "doc") + "</span>" +
          '<span class="d-body"><span class="d-name">' +
          (s.pinned ? '<span class="pin">' + icon("pin") + "</span>" : "") +
          esc(name) + "</span>" +
          '<span class="d-sub">' + esc(s.preview || "") + "</span></span>" +
          '<span class="d-right">' +
          (s.artifacts ? '<span class="d-count">' + s.artifacts + "</span>" : "") +
          '<span class="d-time">' + esc(s.time) + "</span></span></button>";
      }).join("");
    }).join("");
  }

  function hl(text, q) {
    var t = esc(text);
    if (!q) return t;
    var i = t.toLowerCase().indexOf(esc(q).toLowerCase());
    if (i < 0) return t;
    return t.slice(0, i) + "<mark>" + t.slice(i, i + q.length) + "</mark>" + t.slice(i + q.length);
  }

  /* ── 绑定同步（无重绘，保住输入焦点与滚动位置） ─────────────── */
  function syncBound() {
    $$("[data-bind]").forEach(function (el) {
      var path = el.getAttribute("data-bind");
      var kind = el.getAttribute("data-kind");
      var v = get(path);
      if (kind === "toggle") {
        el.setAttribute("data-on", v ? 1 : 0);
      } else if (kind === "seg") {
        el.setAttribute("data-sel", String(v) === el.getAttribute("data-val") ? 1 : 0);
      } else if (kind === "slider") {
        if (document.activeElement !== el) el.value = v;
        var lab = $('[data-slv="' + path + '"]');
        if (lab) lab.textContent = v + (el.getAttribute("data-unit") || "");
      } else if (kind === "field") {
        if (document.activeElement !== el) el.value = v == null ? "" : v;
      }
    });
    $$("[data-title-for]").forEach(function (el) {
      var id = el.getAttribute("data-title-for");
      if (id && S.names && S.names[id]) el.textContent = S.names[id];
    });
  }

  /* ── 路由 ────────────────────────────────────────────────────── */
  function nav(page) {
    if (!page) return;
    var def = SPEC.screens[page];
    if (!def) { toast("页面不存在：" + page); return; }
    if (def.sheet && !S.ui.sheet) {
      S.ui.sheet = page; S.ui.sheetStack = [];
      document.documentElement.setAttribute("data-sheet", "open");
      renderSheet(); renderDrawer(); emit("navigate", { page: page, layer: "sheet" });
      return;
    }
    if (S.ui.sheet) {
      if (S.ui.sheetStack[S.ui.sheetStack.length - 1] === page) return;
      S.ui.sheetStack.push(page);
      renderSheet(); emit("navigate", { page: page, layer: "sheet" });
      return;
    }
    S.ui.stack.push(S.ui.page);
    S.ui.page = page;
    renderMain(); renderDrawer();
    emit("navigate", { page: page, layer: "main" });
  }

  function back() {
    if (S.ui.sheet) {
      if (S.ui.sheetStack.length) { S.ui.sheetStack.pop(); renderSheet(); }
      else closeSheet();
      return;
    }
    if (S.ui.stack.length) {
      S.ui.page = S.ui.stack.pop();
      renderMain(); renderDrawer();
      emit("navigate", { page: S.ui.page, layer: "main" });
    }
  }

  function closeSheet() {
    S.ui.sheet = null; S.ui.sheetStack = [];
    document.documentElement.removeAttribute("data-sheet");
    renderSheet();
    emit("navigate", { page: null, layer: "sheet" });
  }

  function openDrawer() {
    S.ui.drawer = true;
    document.documentElement.setAttribute("data-drawer", "open");
    var sc = $("#drawerScrim"); if (sc) sc.classList.add("on");
    emit("overlay", { drawer: true, page: false });
  }

  function closeDrawer() {
    S.ui.drawer = false;
    document.documentElement.removeAttribute("data-drawer");
    var sc = $("#drawerScrim"); if (sc) sc.classList.remove("on");
    emit("overlay", { drawer: false, page: !!S.ui.page });
  }

  function openSession(id) {
    var s = (DATA.sessions || []).filter(function (x) { return x.id === id; })[0];
    if (!s) return;
    S.session = id;
    S.prefs.model = s.model || S.prefs.model;
    S.ui.page = "home"; S.ui.stack = [];
    closeDrawer(); recompute(); renderMain(); renderDrawer();
    emit("switchSession", { id: id });
  }

  /* ── 提示 ────────────────────────────────────────────────────── */
  var toastTimer = null;
  function toast(msg) {
    var el = $("#toast");
    if (!el) return;
    el.textContent = msg;
    el.classList.add("on");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.classList.remove("on"); }, 1600);
  }

  /* ── 长按改名 ────────────────────────────────────────────────── */
  var pressTimer = null, pressTarget = null, longPressed = false;

  function beginPress(el) {
    pressTarget = el; longPressed = false;
    pressTimer = setTimeout(function () {
      longPressed = true;
      openRename(el);
    }, 520);
  }
  function endPress() { clearTimeout(pressTimer); }

  function openRename(el) {
    var id = el.getAttribute("data-rename") || el.getAttribute("data-id");
    if (!id) return;
    var def = el.getAttribute("data-name") || "";
    var layer = $("#dialogLayer");
    S.names = S.names || {};
    layer.innerHTML = '<div class="dialog"><h4>重命名</h4>' +
      '<div class="dg-sub">原名：' + esc(def) + "</div>" +
      '<input id="renameInput" value="' + esc(S.names[id] || "") + '" placeholder="' + esc(def) + '">' +
      '<div class="dg-actions">' +
      '<button class="danger" data-act="rename-reset" data-id="' + esc(id) + '">恢复原名</button>' +
      '<button data-act="closeDialog">取消</button>' +
      '<button class="primary" data-act="rename-save" data-id="' + esc(id) + '">保存</button>' +
      "</div></div>";
    layer.classList.add("on");
    var inp = $("#renameInput");
    if (inp) { inp.focus(); inp.select(); }
  }

  function saveRename(id) {
    var inp = $("#renameInput");
    var v = inp ? inp.value.trim() : "";
    S.names = S.names || {};
    if (v) S.names[id] = v; else delete S.names[id];
    closeDialog();
    renderDrawer(); renderMain();
    if (S.ui.sheet) renderSheet();
    toast(v ? "已改名为 " + v : "已恢复原名");
    emit("rename", { id: id, name: v });
  }

  function closeDialog() {
    $("#dialogLayer").classList.remove("on");
    $("#dialogLayer").innerHTML = "";
  }

  /* ── 命令 ────────────────────────────────────────────────────── */
  function cmd(name, arg) {
    switch (name) {
      case "send": sendMessage(); return;
      case "new-chat":
        DATA.messages = [];
        S.ui.page = "home"; S.ui.stack = [];
        closeDrawer(); renderMain(); toast("新任务"); break;
      case "attach": toast("附件：原生层接管文件选择"); break;
      case "voice": toast("语音输入：原生层接管麦克风"); break;
      case "more": toast("更多操作"); break;
      case "nav": nav(arg); break;
      case "save": toast("已保存"); emit("save", { page: S.ui.page }); break;
      case "confirm": openConfirm(arg); break;
      case "action": toast("已执行：" + arg); emit("action", { action: arg }); break;
      default: toast(name); emit("action", { action: name });
    }
  }

  function openConfirm(kind) {
    var map = {
      "del-provider": "删除这个服务商？", "clear-memory": "清空全部记忆？",
      "clear-logs": "清空日志？", "rootfs-reset": "重置根文件系统？这会丢掉沙箱里的一切。",
      "restore": "从备份恢复？当前数据会被覆盖。", "unmount": "卸载这个挂载点？",
      "github-logout": "退出 GitHub 登录？"
    };
    var layer = $("#dialogLayer");
    layer.innerHTML = '<div class="dialog"><h4>' + esc(map[kind] || "确认操作？") + "</h4>" +
      '<div class="dg-sub">这个操作由原生层最终执行</div>' +
      '<div class="dg-actions"><button data-act="closeDialog">取消</button>' +
      '<button class="danger" data-act="confirm-do" data-id="' + esc(kind) + '">确认</button></div></div>';
    layer.classList.add("on");
  }

  /* ── 事件委托 ────────────────────────────────────────────────── */
  document.addEventListener("click", function (e) {
    var el = e.target.closest("[data-act]");
    if (!el) return;
    var act = el.getAttribute("data-act");
    var arg = el.getAttribute("data-arg") || "";
    var x = el.getAttribute("data-x") || "";

    if (longPressed) { longPressed = false; return; }

    switch (act) {
      case "drawer": openDrawer(); break;
      case "nav": nav(arg); break;
      case "sheet": nav(arg); break;
      case "back": back(); break;
      case "sheetBack": back(); break;
      case "closeSheet": closeSheet(); break;
      case "closeDialog": closeDialog(); break;
      case "accent": S.prefs.accent = el.getAttribute("data-val"); applyPrefs(); recompute();
        $$(".swatch").forEach(function (s) { s.setAttribute("data-sel", S.prefs.accent === s.getAttribute("data-val") ? 1 : 0); });
        emit("prefs", { accent: S.prefs.accent }); break;
      case "seg": {
        var path = arg, v = el.getAttribute("data-val");
        set(path, v);
        var group = el.parentElement;
        $$("button", group).forEach(function (b) { b.setAttribute("data-sel", b === el ? 1 : 0); });
        applyPrefs(); recompute(); syncBound();
        if (path === "prefs.model") renderChat();
        emit("prefs", { path: path, value: v });
        break;
      }
      case "toggle": {
        var p = arg, nv = !get(p);
        set(p, nv);
        el.querySelector(".sw").setAttribute("data-on", nv ? 1 : 0);
        recompute(); syncBound();
        emit("prefs", { path: p, value: nv });
        break;
      }
      case "cmd": cmd(arg, x); break;
      case "open-session": openSession(arg); break;
      case "rename-save": saveRename(arg); break;
      case "rename-reset":
        S.names = S.names || {};
        delete S.names[arg];
        closeDialog(); renderDrawer(); renderMain();
        if (S.ui.sheet) renderSheet();
        toast("已恢复原名");
        emit("rename", { id: arg, name: "" });
        break;
      case "confirm-do": closeDialog(); toast("已确认：" + arg); emit("action", { action: arg, confirmed: true }); break;
    }
  });

  document.addEventListener("pointerdown", function (e) {
    var el = e.target.closest("[data-rename]");
    if (el) beginPress(el);
    var scrim = e.target.closest("#drawerScrim");
    if (scrim) closeDrawer();
  });
  document.addEventListener("pointerup", endPress);
  document.addEventListener("pointercancel", endPress);

  document.addEventListener("input", function (e) {
    var el = e.target;
    var act = el.getAttribute && el.getAttribute("data-act");
    if (act === "field") {
      set(el.getAttribute("data-arg"), el.value);
      emit("field", { path: el.getAttribute("data-arg"), value: el.value });
    } else if (act === "slide") {
      var v = Number(el.value);
      set(el.getAttribute("data-arg"), v);
      var lab = $('[data-slv="' + el.getAttribute("data-arg") + '"]');
      if (lab) lab.textContent = v + (el.getAttribute("data-unit") || "");
      var bg = S.prefs.bg;
      if (el.getAttribute("data-arg").indexOf("prefs.bg.") === 0) applyPrefs();
      emit("prefs", { path: el.getAttribute("data-arg"), value: v });
    }
  });

  /* ── 桌面端手势兜底：左边缘右滑开抽屉 ──────────────────────── */
  var edgeX = null;
  document.addEventListener("touchstart", function (e) {
    if (e.touches[0].clientX < 24) edgeX = e.touches[0].clientX;
  }, { passive: true });
  document.addEventListener("touchmove", function (e) {
    if (edgeX === null) return;
    var dx = e.touches[0].clientX - edgeX;
    if (dx > 52) { openDrawer(); edgeX = null; }
  }, { passive: true });
  document.addEventListener("touchend", function () { edgeX = null; }, { passive: true });

  /* ── 对外桥（Swift 从这里进出） ─────────────────────────────── */
  var HANDLER = null;
  function emit(type, payload) {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ms) {
      window.webkit.messageHandlers.ms.postMessage(Object.assign({ type: type }, payload || {}));
    } else if (window.__nativeLog) {
      console.log("[ui->native]", type, payload);
    }
  }

  window.__MS__ = {
    version: "1.0.0",
    setData: function (json) {
      var d = typeof json === "string" ? JSON.parse(json) : json;
      Object.keys(d).forEach(function (k) { DATA[k] = d[k]; });
      recompute(); renderMain(); renderDrawer(); if (S.ui.sheet) renderSheet();
      return true;
    },
    setPrefs: function (json) {
      var d = typeof json === "string" ? JSON.parse(json) : json;
      Object.keys(d).forEach(function (k) { S.prefs[k] = d[k]; });
      applyPrefs(); recompute(); syncBound();
      return true;
    },
    navigate: function (page) { nav(page); return S.ui.page; },
    back: function () { back(); return S.ui.page; },
    openDrawer: openDrawer,
    closeDrawer: closeDrawer,
    setTheme: function (mode) {
      S.prefs.theme = ({ light: "浅色", dark: "深色" })[mode] || "跟随系统";
      applyPrefs(); return S.prefs.theme;
    },
    setModel: function (m) { S.prefs.model = m; recompute(); renderChat(); return m; },
    state: function () { return JSON.parse(JSON.stringify(S)); },
    data: function () { return JSON.parse(JSON.stringify(DATA)); },
    ready: true
  };

  /* ── 启动 ────────────────────────────────────────────────────── */
  function boot() {
    var q = new URLSearchParams(location.search);
    var host = (q.get("host") === "app" || window.__MS_HOST__ === "app") ? "app" : "preview";
    document.body.setAttribute("data-host", host);

    // 预览/截图用：?motion=off&theme=dark&accent=紫&page=settings&drawer=1
    if (q.get("motion") === "off") S.prefs.reduceMotion = true;
    if (q.get("theme")) S.prefs.theme = q.get("theme") === "dark" ? "深色" : "浅色";
    if (q.get("accent")) S.prefs.accent = q.get("accent");
    if (q.get("size")) S.prefs.textSize = q.get("size");
    if (q.get("density")) S.prefs.density = q.get("density");
    var startSheet = null;
    if (q.get("page") && SPEC.screens[q.get("page")]) {
      if (SPEC.screens[q.get("page")].sheet) startSheet = q.get("page");
      else S.ui.page = q.get("page");
    }

    S.ui.stack = [];
    recompute(); applyPrefs();
    renderDrawer(); renderMain();
    if (startSheet) nav(startSheet);

    if (q.get("drawer") === "1") {
      openDrawer();
    } else if (host === "preview" && q.get("drawer") !== "0") {
      // 预览模式：把抽屉默认打开一次，让人一眼看到「联动」
      setTimeout(function () { openDrawer(); }, 380);
    }
    emit("ready", { version: window.__MS__.version, page: S.ui.page });
  }

  // 任何未捕获错误都画在屏幕上 —— 白屏是最难查的失败态
  window.addEventListener("error", function (e) {
    var box = document.createElement("pre");
    box.style.cssText = "position:fixed;left:0;right:0;bottom:0;z-index:9999;margin:0;" +
      "padding:12px;background:#7f1d1d;color:#fff;font:12px/1.5 monospace;white-space:pre-wrap";
    box.textContent = "模板渲染错误：\n" + (e.message || e.error) + "\n" +
      (e.filename || "") + ":" + (e.lineno || "");
    document.body.appendChild(box);
  });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
