/// iso's own live-view page (docs/design/computer-use-live-view.md §5),
/// embedded in the binary. It holds no secret and loads nothing from
/// elsewhere: the token arrives in the URL fragment, which the browser
/// sends to no server, and is dropped from the address bar once read.
/// Decoding uses WebCodecs, so nothing is installed.
package enum LiveViewPage {
  package static let html = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>iso live view</title>
    <link rel="stylesheet" href="/viewer.css">
    </head>
    <body>
    <header>
      <strong>iso live view</strong>
      <span id="status">connecting</span>
      <button id="control" type="button" disabled>Take control</button>
    </header>
    <main><canvas id="screen" width="1920" height="1200" tabindex="0"></canvas></main>
    <script src="/viewer.js"></script>
    </body>
    </html>
    """

  package static let style = """
    :root { color-scheme: light dark; --bg: #f4f4f5; --fg: #18181b; --bar: #e4e4e7; --accent: #b91c1c; }
    @media (prefers-color-scheme: dark) {
      :root { --bg: #09090b; --fg: #f4f4f5; --bar: #27272a; --accent: #f87171; }
    }
    html, body { margin: 0; height: 100%; background: var(--bg); color: var(--fg);
      font: 14px -apple-system, system-ui, sans-serif; }
    header { display: flex; gap: 16px; align-items: center; padding: 8px 16px; background: var(--bar); }
    #status { flex: 1; opacity: 0.8; }
    body.controlling #status { color: var(--accent); opacity: 1; font-weight: 600; }
    main { display: flex; justify-content: center; padding: 8px; }
    canvas { max-width: 100%; max-height: calc(100vh - 64px); height: auto; background: #000; outline: none; }
    body.controlling canvas { cursor: none; box-shadow: 0 0 0 2px var(--accent); }
    """

  package static let script = """
    "use strict";
    (() => {
      const token = location.hash.slice(1);
      history.replaceState(null, "", location.pathname);
      const canvas = document.getElementById("screen");
      const ctx = canvas.getContext("2d");
      const status = document.getElementById("status");
      const button = document.getElementById("control");
      let controlling = false;
      let keyed = false;
      const down = new Set();
      const say = (s) => { status.textContent = s; };
      if (!("VideoDecoder" in window)) { say("this browser has no WebCodecs VideoDecoder"); return; }
      const decoder = new VideoDecoder({
        output: (frame) => { ctx.drawImage(frame, 0, 0, canvas.width, canvas.height); frame.close(); },
        error: (e) => say("decoder: " + e.message),
      });
      decoder.configure({ codec: "avc1.42E033", optimizeForLatency: true });
      const ws = new WebSocket("ws://" + location.host + "/ws");
      ws.binaryType = "arraybuffer";
      const send = (o) => { if (ws.readyState === 1) ws.send(JSON.stringify(o)); };
      ws.onopen = () => { send({ type: "auth", token }); say("view only"); button.disabled = false; };
      ws.onclose = () => { say("disconnected"); button.disabled = true; setControlling(false); };
      ws.onmessage = (e) => {
        if (typeof e.data === "string") {
          const m = JSON.parse(e.data);
          if (m.type === "state") {
            setControlling(m.controlling);
            if (!m.controlling) say(m.otherControls ? "view only (another viewer has control)" : "view only");
          } else if (m.type === "error") {
            say(m.message);
          }
          return;
        }
        const b = new Uint8Array(e.data);
        if (b[0] !== 1) return;
        const key = (b[1] & 1) === 1;
        if (!keyed && !key) return;
        keyed = true;
        let t = 0;
        for (let i = 2; i < 10; i++) t = t * 256 + b[i];
        decoder.decode(new EncodedVideoChunk({ type: key ? "key" : "delta", timestamp: t, data: b.subarray(10) }));
      };
      function setControlling(on) {
        controlling = on;
        document.body.classList.toggle("controlling", on);
        button.textContent = on ? "Release" : "Take control";
        if (on) { say("you have control"); canvas.focus(); }
        if (!on) { down.clear(); pressed.clear(); move = wheel = null; }
      }
      button.onclick = () => send({ type: "control", action: controlling ? "release" : "take" });
      const point = (e) => {
        const r = canvas.getBoundingClientRect();
        const x = Math.min(canvas.width - 1, Math.max(0, (e.clientX - r.left) / r.width * canvas.width));
        const y = Math.min(canvas.height - 1, Math.max(0, (e.clientY - r.top) / r.height * canvas.height));
        return { x, y };
      };
      const buttons = ["left", "middle", "right"];
      const pressed = new Set();
      const isModifier = (code) => /^(Shift|Control|Alt|Meta)(Left|Right)$/.test(code);
      const clamp = (v) => Math.max(-10000, Math.min(10000, v));
      // Moves and scrolls are coalesced to one of each per 20 ms: a 120 Hz
      // display would otherwise outrun the owner's message budget.
      let move = null, wheel = null, timer = null;
      let last = { x: 0, y: 0 };
      const flush = () => {
        if (timer !== null) { clearTimeout(timer); timer = null; }
        if (move) send({ type: "pointer", kind: "move", ...move });
        if (wheel && (wheel.dx || wheel.dy)) send({ type: "scroll", ...wheel });
        move = wheel = null;
      };
      const schedule = () => { if (timer === null) timer = setTimeout(flush, 20); };
      // Mouse moves and releases are heard on the window: a drag that leaves
      // the canvas still moves, and its button is still released.
      window.addEventListener("mousemove", (e) => {
        if (!controlling || (e.target !== canvas && pressed.size === 0)) return;
        move = last = point(e);
        schedule();
      });
      canvas.addEventListener("mousedown", (e) => {
        const b = buttons[e.button];
        if (!controlling || !b) return;
        e.preventDefault();
        flush();
        pressed.add(b);
        last = point(e);
        send({ type: "pointer", kind: "down", button: b, ...last });
      });
      window.addEventListener("mouseup", (e) => {
        const b = buttons[e.button];
        if (!controlling || !b || !pressed.delete(b)) return;
        e.preventDefault();
        flush();
        last = point(e);
        send({ type: "pointer", kind: "up", button: b, ...last });
      });
      canvas.addEventListener("contextmenu", (e) => e.preventDefault());
      canvas.addEventListener("wheel", (e) => {
        if (!controlling) return;
        e.preventDefault();
        wheel = {
          dx: clamp((wheel ? wheel.dx : 0) - Math.round(e.deltaX)),
          dy: clamp((wheel ? wheel.dy : 0) - Math.round(e.deltaY)),
          ...point(e),
        };
        schedule();
      }, { passive: false });
      const keyUp = (code) => { if (down.delete(code)) send({ type: "key", kind: "up", code }); };
      const key = (kind) => (e) => {
        if (!controlling || e.repeat) return;
        // Command-V pastes: the browser's paste event types the text.
        if (e.metaKey && e.code === "KeyV") return;
        e.preventDefault();
        if (kind === "up") {
          keyUp(e.code);
          // Keys already down when Command went down get no keyup either.
          if (e.code === "MetaLeft" || e.code === "MetaRight") {
            for (const c of [...down]) if (!isModifier(c)) keyUp(c);
          }
          return;
        }
        send({ type: "key", kind: "down", code: e.code });
        // macOS browsers send no keyup for a key pressed while Command is
        // held: let go of it now, or it stays down in the guest.
        if (e.metaKey && !isModifier(e.code)) send({ type: "key", kind: "up", code: e.code });
        else down.add(e.code);
      };
      canvas.addEventListener("keydown", key("down"));
      canvas.addEventListener("keyup", key("up"));
      document.addEventListener("paste", (e) => {
        if (!controlling) return;
        e.preventDefault();
        for (const c of ["MetaLeft", "MetaRight"]) keyUp(c);
        const text = (e.clipboardData.getData("text/plain") || "").replace(/\\r\\n?/g, "\\n")
          .replace(/[^\\x20-\\x7e\\n\\t]/g, "").slice(0, 4096);
        if (text) send({ type: "text", text });
      });
      window.addEventListener("blur", () => {
        flush();
        for (const c of [...down]) keyUp(c);
        for (const b of pressed) send({ type: "pointer", kind: "up", button: b, ...last });
        pressed.clear();
      });
    })();
    """
}
