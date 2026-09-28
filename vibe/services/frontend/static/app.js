/* VIBE player */
(() => {
  const $ = (s) => document.querySelector(s);
  const grid = $("#grid"), empty = $("#empty"), audio = $("#audio"), player = $("#player");
  const wave = $("#wave"), tCur = $("#t-cur"), tDur = $("#t-dur"), quality = $("#quality");

  const state = { tracks: [], filter: "", q: "", current: null, hls: null, playing: false };

  // ---------- utils ----------
  const fmt = (s) => { s = Math.max(0, Math.floor(s || 0)); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; };
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const hue = (id) => { let h = 0; for (const c of id) h = (h * 31 + c.charCodeAt(0)) % 360; return h; };
  // Paleta acotada a la identidad: naranja, rosa, violeta y cian (pares de matices que combinan)
  const PALETTE = [[28, 335], [335, 275], [275, 200], [350, 25], [300, 210], [15, 300]];
  const coverStyle = (id) => {
    const [a, b] = PALETTE[hue(id) % PALETTE.length];
    const angle = 110 + (hue(id) % 60);
    return `background: linear-gradient(${angle}deg, hsl(${a} 95% 60%), hsl(${b} 90% 55%))`;
  };
  const initials = (t) => t.title.split(/\s+/).slice(0, 2).map((w) => w[0]).join("").toUpperCase();
  let toastTimer;
  const toast = (msg, err = false) => {
    const el = $("#toast"); el.textContent = msg; el.className = "toast" + (err ? " err" : ""); el.hidden = false;
    clearTimeout(toastTimer); toastTimer = setTimeout(() => (el.hidden = true), 3200);
  };

  // ---------- catálogo ----------
  async function loadTracks() {
    const p = new URLSearchParams();
    if (state.q) p.set("q", state.q);
    if (state.filter) p.set("status", state.filter);
    try {
      const res = await fetch(`/api/tracks?${p}`);
      state.tracks = await res.json();
      render();
    } catch (e) { console.warn("tracks", e); }
  }

  async function loadStats() {
    try {
      const s = await (await fetch("/api/stats")).json();
      document.querySelectorAll("#stats [data-k]").forEach((el) => (el.textContent = s[el.dataset.k]));
    } catch (e) { /* silencio */ }
  }

  function render() {
    grid.innerHTML = "";
    empty.hidden = state.tracks.length > 0;
    for (const t of state.tracks) {
      const card = document.createElement("article");
      card.className = "card" + (state.current?.id === t.id ? " is-playing" : "");
      card.dataset.id = t.id;
      const ready = t.status === "ready";
      const badge = ready ? "" : `<span class="badge badge-${t.status}">${t.status === "processing" ? '<i class="spin"></i>' : ""}${{ pending: "en cola", processing: "procesando", failed: "falló" }[t.status]}</span>`;
      card.innerHTML = `
        <button class="card-del" title="Eliminar" aria-label="Eliminar"><svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6 6 18"/></svg></button>
        <div class="card-cover" style="${coverStyle(t.id)}">${esc(initials(t))}
          ${ready ? `<button class="card-play" aria-label="Reproducir"><svg viewBox="0 0 24 24"><path d="M7 4l14 8-14 8z"/></svg></button>` : ""}
        </div>
        <div class="card-body">
          <div class="card-title" title="${esc(t.title)}">${esc(t.title)}</div>
          <div class="card-sub">${esc(t.artist)} · ${esc(t.album)}</div>
          <div class="card-foot"><span class="mono">${ready ? fmt(t.duration_sec) : ""}</span>${badge}</div>
        </div>`;
      if (ready) card.querySelector(".card-cover").addEventListener("click", () => play(t));
      card.querySelector(".card-del").addEventListener("click", async (ev) => {
        ev.stopPropagation();
        if (!confirm(`¿Eliminar "${t.title}"?`)) return;
        await fetch(`/api/tracks/${t.id}`, { method: "DELETE" });
        toast("Eliminada");
        loadTracks();
      });
      grid.appendChild(card);
    }
  }

  // ---------- reproducción ----------
  function readyList() { return state.tracks.filter((t) => t.status === "ready"); }

  function play(track) {
    if (state.current?.id === track.id) { togglePlay(); return; }
    state.current = track;
    $("#p-title").textContent = track.title;
    $("#p-artist").textContent = `${track.artist} · ${track.album}`;
    const cover = $("#p-cover"); cover.textContent = initials(track); cover.style = coverStyle(track.id);
    drawWave(track.waveform || []);
    tDur.textContent = fmt(track.duration_sec);
    quality.innerHTML = `<option value="-1">Auto</option>`;

    if (state.hls) { state.hls.destroy(); state.hls = null; }
    const src = track.stream_url;
    if (window.Hls && Hls.isSupported()) {
      const hls = new Hls({ maxBufferLength: 30 });
      state.hls = hls;
      hls.loadSource(src);
      hls.attachMedia(audio);
      hls.on(Hls.Events.MANIFEST_PARSED, (_, data) => {
        data.levels.forEach((lv, i) => {
          const o = document.createElement("option");
          o.value = i; o.textContent = lv.name || `${Math.round(lv.bitrate / 1000)} kbps`;
          quality.appendChild(o);
        });
        audio.play().catch(() => {});
      });
      hls.on(Hls.Events.ERROR, (_, d) => { if (d.fatal) { toast("Error de streaming, reintentando", true); hls.startLoad(); } });
    } else {
      audio.src = src; // Safari: HLS nativo
      audio.play().catch(() => {});
    }
    render();
  }

  function togglePlay() {
    if (!state.current) { const first = readyList()[0]; if (first) play(first); return; }
    audio.paused ? audio.play() : audio.pause();
  }
  function step(dir) {
    const list = readyList(); if (!list.length) return;
    const i = list.findIndex((t) => t.id === state.current?.id);
    play(list[(i + dir + list.length) % list.length]);
  }

  audio.addEventListener("play", () => { player.classList.add("is-playing"); $("#btn-play").title = "Pausar"; });
  audio.addEventListener("pause", () => { player.classList.remove("is-playing"); $("#btn-play").title = "Reproducir"; });
  audio.addEventListener("ended", () => step(1));
  audio.addEventListener("timeupdate", () => {
    tCur.textContent = fmt(audio.currentTime);
    if (audio.duration && isFinite(audio.duration)) tDur.textContent = fmt(audio.duration);
    updateWave(audio.duration ? audio.currentTime / audio.duration : 0);
  });
  audio.volume = 0.9;

  $("#btn-play").addEventListener("click", togglePlay);
  $("#btn-prev").addEventListener("click", () => step(-1));
  $("#btn-next").addEventListener("click", () => step(1));
  $("#volume").addEventListener("input", (e) => (audio.volume = +e.target.value));
  quality.addEventListener("change", (e) => { if (state.hls) state.hls.currentLevel = +e.target.value; });
  document.addEventListener("keydown", (e) => {
    if (e.target.matches("input, select, textarea")) return;
    if (e.code === "Space") { e.preventDefault(); togglePlay(); }
    if (e.code === "ArrowRight") audio.currentTime += 5;
    if (e.code === "ArrowLeft") audio.currentTime -= 5;
  });

  // ---------- waveform ----------
  let bars = [];
  function drawWave(peaks) {
    wave.innerHTML = "";
    const pts = peaks.length ? peaks : Array.from({ length: 120 }, () => 0.15);
    bars = pts.map((p) => {
      const b = document.createElement("i");
      b.style.transform = `scaleY(${Math.max(0.08, p)})`;
      wave.appendChild(b);
      return b;
    });
  }
  function updateWave(ratio) {
    const head = Math.floor(ratio * bars.length);
    bars.forEach((b, i) => { b.classList.toggle("on", i < head); b.classList.toggle("head", i === head); });
  }
  wave.addEventListener("click", (e) => {
    if (!audio.duration) return;
    const r = wave.getBoundingClientRect();
    audio.currentTime = ((e.clientX - r.left) / r.width) * audio.duration;
  });
  drawWave([]);

  // ---------- búsqueda / filtros ----------
  let searchTimer;
  $("#search").addEventListener("input", (e) => { clearTimeout(searchTimer); searchTimer = setTimeout(() => { state.q = e.target.value.trim(); loadTracks(); }, 250); });
  document.querySelectorAll(".chip").forEach((c) => c.addEventListener("click", () => {
    document.querySelectorAll(".chip").forEach((x) => x.classList.remove("is-active"));
    c.classList.add("is-active"); state.filter = c.dataset.filter; loadTracks();
  }));

  // ---------- subida ----------
  const modal = $("#modal"), fileInput = $("#file"), drop = $("#drop"), dropText = $("#drop-text");
  const openModal = () => { modal.hidden = false; };
  const closeModal = () => { modal.hidden = true; $("#form-upload").reset(); dropText.textContent = "Arrastra tus archivos aquí o haz clic para elegir"; $("#progress").hidden = true; };
  $("#btn-upload").addEventListener("click", openModal);
  $("#btn-close").addEventListener("click", closeModal);
  modal.addEventListener("click", (e) => { if (e.target === modal) closeModal(); });
  fileInput.addEventListener("change", () => { const n = fileInput.files.length; dropText.textContent = n === 1 ? fileInput.files[0].name : `${n} archivos seleccionados`; });
  ["dragenter", "dragover"].forEach((ev) => drop.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.add("is-over"); }));
  ["dragleave", "drop"].forEach((ev) => drop.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.remove("is-over"); }));
  drop.addEventListener("drop", (e) => { fileInput.files = e.dataTransfer.files; fileInput.dispatchEvent(new Event("change")); });

  function uploadOne(file, artist, album, onProgress) {
    return new Promise((resolve, reject) => {
      const fd = new FormData();
      fd.append("file", file); fd.append("title", file.name.replace(/\.[^.]+$/, ""));
      if (artist) fd.append("artist", artist); if (album) fd.append("album", album);
      const xhr = new XMLHttpRequest();
      xhr.open("POST", "/api/upload");
      xhr.upload.onprogress = (e) => e.lengthComputable && onProgress(e.loaded / e.total);
      xhr.onload = () => (xhr.status < 300 ? resolve() : reject(new Error(JSON.parse(xhr.responseText || "{}").detail || xhr.statusText)));
      xhr.onerror = () => reject(new Error("Error de red"));
      xhr.send(fd);
    });
  }

  $("#form-upload").addEventListener("submit", async (e) => {
    e.preventDefault();
    const files = [...fileInput.files];
    if (!files.length) { toast("Elige al menos un archivo", true); return; }
    const artist = e.target.artist.value.trim(), album = e.target.album.value.trim();
    const btn = $("#btn-send"), prog = $("#progress"), bar = $("#bar"), txt = $("#progress-text");
    btn.disabled = true; prog.hidden = false;
    let ok = 0;
    for (let i = 0; i < files.length; i++) {
      txt.textContent = `${i + 1}/${files.length} · ${files[i].name}`;
      try {
        await uploadOne(files[i], artist, album, (r) => (bar.style.width = `${((i + r) / files.length) * 100}%`));
        ok++;
      } catch (err) { toast(`${files[i].name}: ${err.message}`, true); }
    }
    btn.disabled = false;
    toast(`${ok} archivo(s) en cola de transcodificación`);
    closeModal();
    loadTracks(); loadStats();
  });

  // ---------- arranque ----------
  loadTracks(); loadStats();
  setInterval(loadTracks, 4000);
  setInterval(loadStats, 2500);
})();
