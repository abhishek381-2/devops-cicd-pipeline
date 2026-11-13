/* ============================================================================
   devops-cicd-app - DevOps dashboard
   Vanilla JS. No framework, no CDN, no build step.
   Data comes from GET /api/dashboard (real data only - the backend reports
   "unavailable" instead of inventing numbers, and this script renders that
   state honestly).
   ========================================================================== */
(function () {
  "use strict";

  var REFRESH_MS = 30000;          // auto-refresh every 30 seconds
  var API = "/api/dashboard";

  /* ---------------------------------------------------------------- utils */
  function $(id) { return document.getElementById(id); }

  function esc(value) {
    if (value === null || value === undefined) { return ""; }
    return String(value)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }

  function setText(id, value) {
    var el = $(id);
    if (el) { el.textContent = value === null || value === undefined || value === "" ? "—" : String(value); }
  }

  function fmtDuration(seconds) {
    if (seconds === null || seconds === undefined || isNaN(seconds)) { return "—"; }
    var s = Math.floor(seconds);
    var d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600);
    var m = Math.floor((s % 3600) / 60), sec = s % 60;
    if (d > 0) { return d + "d " + h + "h"; }
    if (h > 0) { return h + "h " + m + "m"; }
    if (m > 0) { return m + "m " + sec + "s"; }
    return sec + "s";
  }

  function fmtClock(seconds) {
    if (seconds === null || seconds === undefined) { return "—"; }
    var h = Math.floor(seconds / 3600), m = Math.floor((seconds % 3600) / 60);
    var s = Math.floor(seconds % 60);
    return (h > 0 ? h + "h " : "") + m + "m " + s + "s";
  }

  function fmtBytes(mb) {
    if (mb === null || mb === undefined || isNaN(mb)) { return "—"; }
    if (mb >= 1024) { return (mb / 1024).toFixed(1) + " GB"; }
    return Math.round(mb) + " MB";
  }

  function fmtTime(iso) {
    if (!iso) { return "—"; }
    var d = new Date(iso);
    if (isNaN(d.getTime())) { return String(iso); }
    return d.toLocaleString([], {
      year: "numeric", month: "short", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit"
    });
  }

  function toneFor(status) {
    switch (String(status || "").toLowerCase()) {
      case "healthy": case "up": case "running": case "success": case "connected": return "ok";
      case "degraded": case "starting": case "pending": case "in_progress":
      case "rolled_back": case "warning": return "warn";
      case "unhealthy": case "down": case "failed": case "failure": case "stopped":
      case "rollback_failed": return "err";
      default: return "muted";
    }
  }

  /* Turn a machine value into a human label: "rolled_back" -> "Rolled back". */
  function pretty(value) {
    if (value === null || value === undefined || value === "") { return "—"; }
    var s = String(value).replace(/_/g, " ").trim();
    return s.charAt(0).toUpperCase() + s.slice(1);
  }

  function pill(text, tone) {
    return '<span class="pill pill--' + tone + '">' + esc(pretty(text)) + "</span>";
  }

  function setTone(el, tone) {
    if (!el) { return; }
    el.classList.remove("is-ok", "is-warn", "is-err", "is-info", "is-muted");
    el.classList.add("is-" + tone);
  }

  function unavailable(reason) {
    var map = {
      not_configured: "Not configured",
      no_logs: "No logs yet",
      permission_denied: "Permission denied",
      invalid_json: "Invalid data",
      stale: "Data is stale"
    };
    return map[reason] || "Unavailable";
  }

  /* --------------------------------------------------------------- charts */
  function donut(percent, label) {
    var p = Math.max(0, Math.min(100, Number(percent) || 0));
    var r = 54, c = 2 * Math.PI * r;
    var color = p >= 90 ? "var(--err)" : (p >= 75 ? "var(--warn)" : "var(--ok)");
    return '' +
      '<svg viewBox="0 0 140 140" role="img" aria-label="' + esc(label) + ' ' + p + ' percent">' +
      '<circle cx="70" cy="70" r="' + r + '" fill="none" stroke="var(--border-soft)" stroke-width="11"/>' +
      '<circle cx="70" cy="70" r="' + r + '" fill="none" stroke="' + color + '" stroke-width="11" ' +
      'stroke-linecap="round" stroke-dasharray="' + c + '" ' +
      'stroke-dashoffset="' + (c * (1 - p / 100)) + '" transform="rotate(-90 70 70)"/>' +
      '<text x="70" y="66" text-anchor="middle" fill="var(--text)" font-size="26" font-weight="650" ' +
      'font-family="var(--sans)">' + p.toFixed(0) + '%</text>' +
      '<text x="70" y="86" text-anchor="middle" fill="var(--text-faint)" font-size="11" ' +
      'font-family="var(--sans)">' + esc(label) + "</text>" +
      "</svg>";
  }

  function barChart(items) {
    if (!items || !items.length) {
      return '<p class="chart__empty">No deployment history available</p>';
    }
    var data = items.slice(0, 14).reverse();
    var w = 640, h = 170, pad = 26;
    var max = Math.max.apply(null, data.map(function (d) { return Number(d.duration_seconds) || 0; }));
    if (max <= 0) { max = 1; }
    var slot = (w - pad * 2) / data.length;
    var bw = Math.max(6, Math.min(34, slot * 0.6));
    var svg = '<svg viewBox="0 0 ' + w + " " + h + '" preserveAspectRatio="none">';
    for (var g = 0; g <= 3; g++) {
      var y = pad + (h - pad * 2) * (g / 3);
      svg += '<line class="grid-line" x1="' + pad + '" y1="' + y + '" x2="' + (w - pad) + '" y2="' + y + '"/>';
    }
    data.forEach(function (d, i) {
      var v = Number(d.duration_seconds) || 0;
      var bh = Math.max(2, (h - pad * 2) * (v / max));
      var x = pad + slot * i + (slot - bw) / 2;
      var y = h - pad - bh;
      var failed = String(d.status || "").toLowerCase() === "failed";
      svg += '<rect class="bar' + (failed ? " bar--fail" : "") + '" x="' + x.toFixed(1) + '" y="' + y.toFixed(1) +
        '" width="' + bw.toFixed(1) + '" height="' + bh.toFixed(1) + '" rx="3"><title>' +
        esc((d.tag || d.image || "deployment") + " - " + (d.status || "") + " - " + v + "s") + "</title></rect>";
      if (data.length <= 8) {
        svg += '<text class="axis-label" x="' + (x + bw / 2).toFixed(1) + '" y="' + (h - 8) + '" text-anchor="middle">' +
          esc((d.tag || "").replace(/^sha-/, "").slice(0, 7)) + "</text>";
      }
    });
    svg += "</svg>";
    return svg;
  }

  /* Horizontal usage bars - one row per mount point. Much easier to read
     than a stretched SVG when there are only a couple of filesystems. */
  function diskChart(disks) {
    if (!disks || !disks.length) {
      return '<p class="chart__empty">No disk metrics available</p>';
    }
    return '<div class="usage">' + disks.map(function (d) {
      var pct = Math.max(0, Math.min(100, Number(d.percent) || 0));
      var tone = pct >= 90 ? "err" : (pct >= 75 ? "warn" : "ok");
      var used = Number(d.used_gb) || 0;
      var total = Number(d.total_gb) || 0;
      return '<div class="usage__row">' +
        '<div class="usage__head">' +
          '<span class="usage__mount">' + esc(d.mount || "/") + "</span>" +
          '<span class="usage__value">' + used.toFixed(1) + " / " + total.toFixed(1) + " GB · " +
            pct.toFixed(0) + "%</span>" +
        "</div>" +
        '<div class="usage__track"><div class="usage__fill usage__fill--' + tone +
          '" style="width:' + pct + '%"></div></div>' +
        "</div>";
    }).join("") + "</div>";
  }

  /* -------------------------------------------------------------- renderers */
  function renderOverview(d) {
    var h = d.health || {};
    var healthTone = toneFor(h.status);
    setText("ovHealth", h.status === "healthy" ? "Running" : (h.status === "unhealthy" ? "Unhealthy" : (h.status || "—")));
    setTone($("ovHealth"), healthTone);
    setText("ovHealthHint", h.status === "healthy"
      ? "All dependencies reachable"
      : (h.checks && h.checks.database && h.checks.database.error ? h.checks.database.error : "check /health"));

    var db = (h.checks && h.checks.database) || {};
    setText("ovDb", db.status === "up" ? "Connected" : (db.status === "down" ? "Disconnected" : "—"));
    setTone($("ovDb"), toneFor(db.status));
    setText("ovDbHint", db.status === "up" ? "PostgreSQL · " + (db.latency_ms !== undefined ? db.latency_ms + " ms" : "") : "PostgreSQL");

    setText("ovVersion", "v" + (d.app.version || "—"));
    setText("ovVersionHint", (d.app.environment || "—") + " · up " + fmtDuration(d.app.uptime_seconds));

    setText("ovLatency", db.latency_ms !== undefined && db.latency_ms !== null ? db.latency_ms + " ms" : "—");
    setTone($("ovLatency"), db.latency_ms === undefined ? "muted" : "info");
    setText("ovLatencyHint", "round trip");

    var host = d.host || {};
    var containers = host.containers || [];
    var running = containers.filter(function (c) { return String(c.state || "").toLowerCase() === "running"; }).length;
    if (!host.available) {
      setText("ovContainers", unavailable(host.reason));
      setTone($("ovContainers"), "muted");
      setText("ovContainersHint", "Host metrics are not configured");
    } else if (!containers.length) {
      setText("ovContainers", "0");
      setTone($("ovContainers"), "warn");
      setText("ovContainersHint", host.docker_available ? "No containers found" : "Docker not reachable");
    } else {
      setText("ovContainers", running + " / " + containers.length);
      setTone($("ovContainers"), running === containers.length ? "ok" : "warn");
      setText("ovContainersHint", "Docker containers running");
    }

    var dep = d.deployments || {};
    setText("ovDeploy", dep.current_tag || (host.available ? "Unavailable" : "Unavailable"));
    setTone($("ovDeploy"), dep.current_tag ? "info" : "muted");
    setText("ovDeployHint", dep.current_tag ? "Currently deployed image" : "No deployment recorded");
  }

  function renderHealth(d) {
    var h = d.health || {};
    var db = (h.checks && h.checks.database) || {};
    setText("hzStatus", h.status || "—");
    setTone($("hzStatus"), toneFor(h.status));
    setText("hzDb", db.status === "up" ? "Connected" : (db.status === "down" ? "Disconnected" : "—"));
    setTone($("hzDb"), toneFor(db.status));
    setText("hzLatency", db.latency_ms !== undefined && db.latency_ms !== null ? db.latency_ms + " ms" : "—");
    setText("hzChecked", fmtTime(h.checked_at));
    setText("hzUptime", fmtDuration((d.app || {}).uptime_seconds));
    setText("hzUsers", (d.app || {}).user_count === null || (d.app || {}).user_count === undefined
      ? "Unavailable" : (d.app || {}).user_count);
    var raw = $("hzRaw");
    if (raw) { raw.textContent = JSON.stringify({ status: h.status, checks: h.checks }, null, 2); }
  }

  function renderPipeline(d) {
    var p = d.pipeline || {};
    if (!p.available) {
      setText("ciWorkflow", "—");
      setText("ciConclusion", unavailable(p.reason));
      setTone($("ciConclusion"), "muted");
      ["ciBranch", "ciCommit", "ciDuration", "ciCompleted"].forEach(function (id) { setText(id, "—"); });
      var stages = $("ciStages");
      if (stages) { stages.innerHTML = '<p class="chart__empty">Pipeline status is not configured yet</p>'; }
      var link = $("pipelineLink");
      if (link) { link.hidden = true; }
      return;
    }
    setText("ciWorkflow", p.workflow || "CI/CD Pipeline");
    setText("ciConclusion", pretty(p.conclusion || p.status));
    setTone($("ciConclusion"), toneFor(p.conclusion || p.status));
    setText("ciBranch", p.branch || "—");
    setText("ciCommit", p.commit ? String(p.commit).slice(0, 7) : "—");
    setText("ciDuration", fmtDuration(p.duration_seconds));
    setText("ciCompleted", fmtTime(p.completed_at));

    var link = $("pipelineLink");
    if (link) {
      if (p.run_url) { link.href = p.run_url; link.hidden = false; } else { link.hidden = true; }
    }
    var stages = $("ciStages");
    if (stages) {
      var list = p.stages || [];
      if (!list.length) {
        stages.innerHTML = '<p class="chart__empty">No per-stage detail reported</p>';
      } else {
        stages.innerHTML = list.map(function (s, i) {
          /* The conclusion is the outcome; `status` only says "completed". */
          var outcome = s.conclusion || s.status || "unknown";
          return '<div class="stage" data-status="' + esc(outcome) + '">' +
            '<span class="stage__num">' + (i + 1) + "</span>" +
            "<span>" + esc(s.name || s.stage || "stage") + "</span>" +
            pill(outcome, toneFor(outcome)) +
            "</div>";
        }).join("");
      }
    }
  }

  function renderDeployments(d) {
    var dep = d.deployments || {};
    setText("depCurrent", dep.current_image || unavailable(dep.reason));
    setText("depTag", dep.current_tag || "—");
    setText("depPrevious", dep.previous_tag || "—");

    var chart = $("deployChart");
    if (chart) { chart.innerHTML = barChart(dep.history || []); }

    var tbody = document.querySelector("#deployTable tbody");
    if (tbody) {
      var rows = dep.history || [];
      if (!rows.length) {
        tbody.innerHTML = '<tr><td class="empty" colspan="5">No deployment history recorded yet</td></tr>';
      } else {
        tbody.innerHTML = rows.map(function (r) {
          return "<tr>" +
            "<td>" + esc(fmtTime(r.timestamp)) + "</td>" +
            '<td class="mono">' + esc(r.tag || r.image || "—") + "</td>" +
            "<td>" + pill(r.status || "unknown", toneFor(r.status)) + "</td>" +
            "<td>" + esc(r.duration_seconds !== undefined ? fmtDuration(r.duration_seconds) : "—") + "</td>" +
            '<td class="mono">' + esc(r.commit ? String(r.commit).slice(0, 7) : "—") + "</td>" +
            "</tr>";
        }).join("");
      }
    }
  }

  function renderDocker(d) {
    var host = d.host || {};
    var tbody = document.querySelector("#dockerTable tbody");
    if (!tbody) { return; }
    var containers = host.containers || [];
    if (!host.available) {
      tbody.innerHTML = '<tr><td class="empty" colspan="5">' + esc(unavailable(host.reason)) +
        " — run scripts/collect-metrics.sh on the host</td></tr>";
      return;
    }
    if (!containers.length) {
      tbody.innerHTML = '<tr><td class="empty" colspan="5">No containers reported</td></tr>';
      return;
    }
    tbody.innerHTML = containers.map(function (c) {
      return "<tr>" +
        '<td class="mono">' + esc(c.name || "—") + "</td>" +
        '<td class="mono">' + esc(c.image || "—") + "</td>" +
        "<td>" + pill(c.state || "unknown", toneFor(c.state)) + "</td>" +
        "<td>" + (c.health ? pill(c.health, toneFor(c.health)) : pill("n/a", "muted")) + "</td>" +
        '<td class="mono">' + esc(c.status || "—") + "</td>" +
        "</tr>";
    }).join("");
  }

  function renderSecurity(d) {
    var s = d.security || {};
    var map = [["sevCritical", "critical"], ["sevHigh", "high"], ["sevMedium", "medium"], ["sevLow", "low"]];
    map.forEach(function (pair) {
      var el = $(pair[0]);
      if (!el) { return; }
      var v = s[pair[1]];
      var valueEl = el.querySelector(".card__value");
      if (valueEl) {
        valueEl.textContent = s.available && v !== null && v !== undefined ? String(v) : "—";
      }
      var tone = !s.available ? "muted"
        : (pair[1] === "critical" || pair[1] === "high") ? (Number(v) > 0 ? "err" : "ok")
        : (Number(v) > 0 ? "warn" : "ok");
      if (valueEl) { setTone(valueEl, tone); }
    });

    setText("secImage", s.scanned_image || (s.available ? "—" : unavailable(s.reason)));
    setText("secAt", s.scanned_at ? fmtTime(s.scanned_at) : "—");
    setText("secPolicy", s.policy || "—");
    setText("secResult", s.available
      ? ((Number(s.critical) + Number(s.high)) === 0 ? "Passed policy (0 Critical / 0 High)" : "Policy violation")
      : unavailable(s.reason));
    setTone($("secResult"), s.available
      ? ((Number(s.critical) + Number(s.high)) === 0 ? "ok" : "err")
      : "muted");

    var tbody = document.querySelector("#vulnTable tbody");
    if (tbody) {
      var vulns = s.vulnerabilities || [];
      if (!vulns.length) {
        tbody.innerHTML = '<tr><td class="empty" colspan="5">' +
          (s.available ? "No vulnerabilities reported" : unavailable(s.reason)) + "</td></tr>";
      } else {
        tbody.innerHTML = vulns.map(function (v) {
          return "<tr>" +
            "<td>" + pill(v.severity || "UNKNOWN", toneFor(v.severity === "CRITICAL" ? "failure" : v.severity === "HIGH" ? "err" : v.severity === "MEDIUM" ? "warn" : "muted")) + "</td>" +
            '<td class="mono">' + esc(v.vulnerability_id || "—") + "</td>" +
            '<td class="mono">' + esc(v.pkg_name || "—") + "</td>" +
            '<td class="mono">' + esc(v.installed_version || "—") + "</td>" +
            '<td class="mono">' + esc(v.fixed_version || "—") + "</td>" +
            "</tr>";
        }).join("");
      }
    }
  }

  function renderServer(d) {
    var host = d.host || {};
    if (!host.available) {
      $("gaugeCpu").innerHTML = '<p class="chart__empty">' + esc(unavailable(host.reason)) + "</p>";
      $("gaugeMem").innerHTML = '<p class="chart__empty">' + esc(unavailable(host.reason)) + "</p>";
      $("gaugeDisk").innerHTML = '<p class="chart__empty">' + esc(unavailable(host.reason)) + "</p>";
      setText("cpuMeta", "Run scripts/collect-metrics.sh on the host");
      setText("memMeta", "—");
      setText("diskMeta", "—");
    } else {
      var cpu = host.cpu || {};
      var mem = host.memory || {};
      var disks = host.disk || [];
      var root = disks.length ? disks[0] : null;

      $("gaugeCpu").innerHTML = donut(cpu.percent, "CPU");
      $("gaugeMem").innerHTML = donut(mem.percent, "Memory");
      $("gaugeDisk").innerHTML = root ? donut(root.percent, "Disk") : '<p class="chart__empty">No disk data</p>';

      setText("cpuMeta", (cpu.cores ? cpu.cores + " cores · " : "") + "load " + ((host.load_average || []).join(", ") || "—"));
      setText("memMeta", fmtBytes(mem.used_mb) + " / " + fmtBytes(mem.total_mb));
      setText("diskMeta", root ? (root.mount + " · " + fmtBytes(root.used_gb * 1024) + " / " + fmtBytes(root.total_gb * 1024)) : "—");
    }

    setText("hostName", host.hostname || "—");
    setText("hostOs", host.os || "—");
    setText("hostUptime", fmtDuration(host.uptime_seconds));
    setText("hostLoad", (host.load_average || []).join(", ") || "—");
    setText("hostCollected", host.collected_at ? fmtTime(host.collected_at) : "—");
    setText("hostFresh", host.available
      ? (host.stale ? "Stale (" + host.age_seconds + "s old)" : "Fresh (" + (host.age_seconds || 0) + "s ago)")
      : unavailable(host.reason));

    var chart = $("diskChart");
    if (chart) { chart.innerHTML = host.available ? diskChart(host.disk || []) : '<p class="chart__empty">No disk metrics available</p>'; }
  }

  function renderLogs(d) {
    var logs = d.logs || {};
    var view = $("logView");
    if (!view) { return; }
    if (!logs.available || !(logs.entries || []).length) {
      view.textContent = unavailable(logs.reason || "not_configured");
      return;
    }
    view.innerHTML = logs.entries.map(function (e) {
      var lvl = e.level || "";
      var cls = lvl ? ' class="lvl-' + esc(lvl) + '"' : "";
      var ts = e.timestamp ? esc(e.timestamp) : "";
      return "<span" + cls + ">" + esc(ts + " " + e.message) + "</span>";
    }).join("\n");
  }

  function renderChrome(d) {
    setText("envBadge", (d.app || {}).environment || "—");
    setText("versionBadge", "v" + ((d.app || {}).version || "—"));
    setText("topbarSub", "Live telemetry for " + ((d.app || {}).name || "the application"));
    setText("footText", ((d.app || {}).name || "app") + " · v" + ((d.app || {}).version || "—") + " · " + ((d.app || {}).environment || "—"));

    var dot = $("sidebarDot"), status = $("sidebarStatus");
    var tone = toneFor((d.health || {}).status);
    if (dot) {
      dot.className = "dot is-" + tone;
      dot.classList.add("is-pulse");
    }
    if (status) { status.textContent = (d.health || {}).status === "healthy" ? "Service healthy" : (d.health || {}).status || "Unknown"; }
  }

  /* ----------------------------------------------------------------- fetch */
  var inFlight = false;

  function refresh(manual) {
    if (inFlight) { return; }
    inFlight = true;
    var btn = $("refreshBtn");
    if (btn) { btn.classList.add("is-loading"); }

    fetch(API, { headers: { "Accept": "application/json" }, cache: "no-store" })
      .then(function (res) {
        if (!res.ok) { throw new Error("HTTP " + res.status); }
        return res.json();
      })
      .then(function (data) {
        renderChrome(data);
        renderOverview(data);
        renderHealth(data);
        renderPipeline(data);
        renderDeployments(data);
        renderDocker(data);
        renderSecurity(data);
        renderServer(data);
        renderLogs(data);
        setText("updatedAt", "Updated " + new Date().toLocaleTimeString());
      })
      .catch(function (err) {
        setText("updatedAt", "Update failed");
        var dot = $("sidebarDot"), status = $("sidebarStatus");
        if (dot) { dot.className = "dot is-err is-pulse"; }
        if (status) { status.textContent = "API unreachable"; }
        if (manual && window.console) { console.error("Dashboard refresh failed:", err); }
      })
      .finally(function () {
        inFlight = false;
        if (btn) { btn.classList.remove("is-loading"); }
      });
  }

  /* ------------------------------------------------------------------- nav */
  function setupNav() {
    var links = Array.prototype.slice.call(document.querySelectorAll(".navlink"));
    var sections = links
      .map(function (l) { return document.getElementById(l.getAttribute("data-target")); })
      .filter(Boolean);

    links.forEach(function (link) {
      link.addEventListener("click", function (ev) {
        ev.preventDefault();
        var target = document.getElementById(link.getAttribute("data-target"));
        if (target) { target.scrollIntoView({ behavior: "smooth", block: "start" }); }
        closeSidebar();
      });
    });

    var observer = "IntersectionObserver" in window
      ? new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) {
          if (!entry.isIntersecting) { return; }
          links.forEach(function (l) {
            l.classList.toggle("is-active", l.getAttribute("data-target") === entry.target.id);
          });
        });
      }, { rootMargin: "-72px 0px -70% 0px", threshold: 0 })
      : null;

    if (observer) {
      sections.forEach(function (s) { observer.observe(s); });
    }

    var toggle = $("sidebarToggle"), close = $("sidebarClose"), scrim = $("scrim");
    if (toggle) { toggle.addEventListener("click", openSidebar); }
    if (close) { close.addEventListener("click", closeSidebar); }
    if (scrim) { scrim.addEventListener("click", closeSidebar); }
    document.addEventListener("keydown", function (e) { if (e.key === "Escape") { closeSidebar(); } });
  }

  function openSidebar() {
    var sb = $("sidebar"), sc = $("scrim");
    if (sb) { sb.classList.add("is-open"); }
    if (sc) { sc.hidden = false; }
  }

  function closeSidebar() {
    var sb = $("sidebar"), sc = $("scrim");
    if (sb) { sb.classList.remove("is-open"); }
    if (sc) { sc.hidden = true; }
  }

  /* ------------------------------------------------------------------ init */
  document.addEventListener("DOMContentLoaded", function () {
    setupNav();
    var btn = $("refreshBtn");
    if (btn) { btn.addEventListener("click", function () { refresh(true); }); }
    refresh(false);
    window.setInterval(function () { refresh(false); }, REFRESH_MS);
  });
})();
