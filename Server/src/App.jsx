import { useEffect, useMemo, useRef, useState } from "react";

const initialState = {
  matrix: { online: false, data: null },
  reactor: { online: false, data: null },
  turbines: [],
  storage: { online: false, connected: false, items: [] },
  computers: {},
  terminals: {},
  consoleHistory: [],
  lastCommand: null,
};

const iconPaths = {
  matrix: "M5 3h14v18H5zM8 6v12h8V6zm2 2h4v5h-4z",
  reactor: "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm0 3 2.3 4h-4.6L12 5zm-6 9 2.3-4 2.3 4H6zm6 5-2.3-4h4.6L12 19zm3.4-5 2.3-4L20 14h-4.6z",
  turbine: "M12 2a3 3 0 0 1 2.5 4.65l3.92-1.13 1.5 2.6-3 2.9A3 3 0 0 1 14 15.8L13 20h-3l-1-4.2A3 3 0 0 1 7.08 11l-3-2.88 1.5-2.6L9.5 6.65A3 3 0 0 1 12 2zm0 8a2 2 0 1 0 0 4 2 2 0 0 0 0-4z",
  storage: "M3 5l9-3 9 3v14l-9 3-9-3V5zm3 2v10l6 2 6-2V7l-6 2-6-2zm1-1 5 1.7L17 6l-5-1.7L7 6z",
  terminal: "M3 4h18v16H3V4zm2 2v12h14V6H5zm2 3 3 3-3 3-1.4-1.4L7.2 12 5.6 10.4 7 9zm4 5h5v2h-5v-2z",
  search: "M10 3a7 7 0 1 0 4.9 12l4.05 4.05 1.4-1.4-4.05-4.05A7 7 0 0 0 10 3zm0 2a5 5 0 1 1 0 10 5 5 0 0 1 0-10z",
};

function Icon({ name, size = 18 }) {
  return (
    <svg className="icon" width={size} height={size} viewBox="0 0 24 24" aria-hidden="true">
      <path d={iconPaths[name]} />
    </svg>
  );
}

function Indicator({ active, children }) {
  return <span className={`indicator ${active ? "online" : "offline"}`}><i />{children}</span>;
}

function Metric({ label, value, hint, tone = "default" }) {
  return (
    <article className={`metric ${tone}`}>
      <span>{label}</span>
      <strong>{value}</strong>
      {hint && <small>{hint}</small>}
    </article>
  );
}

function formatEnergy(value) {
  const number = Number(value || 0);
  const units = ["FE", "kFE", "MFE", "GFE", "TFE", "PFE"];
  let scaled = Math.abs(number);
  let unit = 0;
  while (scaled >= 1000 && unit < units.length - 1) {
    scaled /= 1000;
    unit += 1;
  }
  const sign = number < 0 ? "−" : "";
  return `${sign}${scaled.toLocaleString(undefined, { maximumFractionDigits: 2 })} ${units[unit]}`;
}

function formatRate(value) {
  return `${formatEnergy(value)}/t`;
}

function SectionHeading({ eyebrow, title, online, onlineText = "Online", offlineText = "Offline" }) {
  return (
    <div className="card-heading">
      <div><p className="eyebrow">{eyebrow}</p><h2>{title}</h2></div>
      {online != null && <Indicator active={online}>{online ? onlineText : offlineText}</Indicator>}
    </div>
  );
}

function MatrixPanel({ matrix }) {
  const data = matrix.data || {};
  const energy = Math.max(0, Math.min(100, Number(data.energyPercent || 0)));
  const net = Number(data.net || 0);

  return (
    <section className="page-grid matrix-page">
      <article className="hero-card wide-card">
        <SectionHeading
          eyebrow="MEKANISM ENERGY STORAGE"
          title={data.name || "inductionPort_0"}
          online={matrix.online}
          onlineText="Matrix online"
          offlineText="Matrix offline"
        />
        <div className="energy-display">
          <div><span>Stored energy</span><strong>{energy.toFixed(1)}%</strong></div>
          <p>{formatEnergy(data.storedEnergy)} of {formatEnergy(data.capacity)}</p>
        </div>
        <div className="energy-track"><span style={{ width: `${energy}%` }} /></div>
        <div className="metrics-row matrix-metrics">
          <Metric label="Input" value={formatRate(data.input)} tone="good" />
          <Metric label="Output" value={formatRate(data.output)} tone="warning" />
          <Metric
            label="Net flow"
            value={formatRate(net)}
            hint={net >= 0 ? "Charging" : "Discharging"}
            tone={net >= 0 ? "good" : "danger"}
          />
          <Metric label="Free capacity" value={formatEnergy(data.energyNeeded)} />
        </div>
      </article>
    </section>
  );
}

function formatFluid(value) {
  const amount = Number(value || 0);
  if (amount >= 1_000_000) return `${(amount / 1_000_000).toFixed(2)} M mB`;
  if (amount >= 1_000) return `${(amount / 1_000).toFixed(2)} k mB`;
  return `${amount.toFixed(0)} mB`;
}

function TankGauge({ label, percent, amount, capacity, tone = "cyan" }) {
  const level = Math.max(0, Math.min(100, Number(percent || 0)));
  return (
    <article className={`tank-gauge ${tone}`}>
      <div className="tank-shell"><span style={{ height: `${level}%` }} /></div>
      <div className="tank-copy">
        <span>{label}</span>
        <strong>{level.toFixed(1)}%</strong>
        <small>{formatFluid(amount)} / {formatFluid(capacity)}</small>
      </div>
    </article>
  );
}

function LineChart({ title, points, field, unit, color, minimumMax = 1 }) {
  const values = points.map((point) => Number(point[field] || 0));
  const max = Math.max(minimumMax, ...values);
  const polyline = values.map((value, index) => {
    const x = values.length <= 1 ? 100 : (index / (values.length - 1)) * 100;
    const y = 58 - (Math.max(0, value) / max) * 52;
    return `${x.toFixed(2)},${y.toFixed(2)}`;
  }).join(" ");
  const current = values.at(-1) || 0;

  return (
    <article className="chart-card">
      <div><span>{title}</span><strong>{current.toFixed(1)} {unit}</strong></div>
      <svg viewBox="0 0 100 64" preserveAspectRatio="none" aria-label={`${title} history`}>
        <path d="M0 58H100M0 32H100M0 6H100" className="chart-grid-line" />
        {polyline && <polyline points={polyline} style={{ stroke: color }} />}
      </svg>
      <small>Последние {Math.max(1, points.length)} сек.</small>
    </article>
  );
}

function ReactorPanel({ reactor, history, sendCommand, commandResult }) {
  const data = reactor.data || {};
  const [startPercent, setStartPercent] = useState(data.startPercent ?? 80);
  const [stopPercent, setStopPercent] = useState(data.stopPercent ?? 98);
  const [burnRate, setBurnRate] = useState(data.burnRate ?? 0);

  useEffect(() => {
    if (data.startPercent != null) setStartPercent(data.startPercent);
    if (data.stopPercent != null) setStopPercent(data.stopPercent);
    if (data.burnRate != null) setBurnRate(data.burnRate);
  }, [data.startPercent, data.stopPercent, data.burnRate]);

  return (
    <section className="page-grid">
      <article className="hero-card">
        <SectionHeading
          eyebrow="MEKANISM FISSION"
          title={data.name || "Fission Reactor"}
          online={reactor.online}
          onlineText="Controller online"
          offlineText="Controller offline"
        />
        <div className={`reactor-state ${data.running ? "running" : "stopped"}`}>
          <div className="reactor-orbit"><span /></div>
          <div><span>Reactor state</span><strong>{data.running ? "ACTIVE" : "SCRAMMED"}</strong></div>
        </div>
        <div className="metrics-row reactor-metrics">
          <Metric label="Temperature" value={`${Number(data.temperature || 0).toFixed(0)} K`} />
          <Metric label="Damage" value={`${Number(data.damage || 0).toFixed(2)}%`} tone={Number(data.damage) > 0 ? "danger" : "good"} />
          <Metric label="Burn rate" value={`${Number(data.actualBurnRate || 0).toFixed(2)} mB/t`} hint={`Max ${Number(data.maxBurnRate || 0).toFixed(1)}`} />
          <Metric label="Heating" value={`${Number(data.heatingRate || 0).toFixed(1)} mB/t`} />
        </div>
        <div className="tank-grid">
          <TankGauge label="Охлаждающая жидкость" percent={data.coolantPercent} amount={data.coolant} capacity={data.coolantCapacity} tone="cyan" />
          <TankGauge label="Топливо" percent={data.fuelPercent} amount={data.fuel} capacity={data.fuelCapacity} tone="lime" />
          <TankGauge label="Нагретая жидкость" percent={data.heatedCoolantPercent} amount={data.heatedCoolant} capacity={data.heatedCoolantCapacity} tone="orange" />
          <TankGauge label="Ядерные отходы" percent={data.wastePercent} amount={data.waste} capacity={data.wasteCapacity} tone="waste" />
        </div>
        <div className="chart-grid">
          <LineChart title="Температура" points={history} field="temperature" unit="K" color="#ff8a65" minimumMax={1200} />
          <LineChart title="Скорость нагрева" points={history} field="heatingRate" unit="mB/t" color="#ffd166" minimumMax={1} />
        </div>
      </article>

      <aside className="control-card">
        <SectionHeading eyebrow="AUTOMATION" title="Reactor control" />
        <label>Start at<div className="number-field"><input type="number" min="0" max="99" value={startPercent} onChange={(event) => setStartPercent(Number(event.target.value))} /><span>%</span></div></label>
        <label>Stop at<div className="number-field"><input type="number" min="1" max="100" value={stopPercent} onChange={(event) => setStopPercent(Number(event.target.value))} /><span>%</span></div></label>
        <button className="button primary" disabled={!reactor.online} onClick={() => sendCommand("set_thresholds", { startPercent, stopPercent })}>Save thresholds</button>
        <label>Лимит сгорания<div className="number-field"><input type="number" min="0" max={Number(data.maxBurnRate || 0)} step="0.1" value={burnRate} onChange={(event) => setBurnRate(Number(event.target.value))} /><span>mB/t</span></div></label>
        <input className="burn-slider" type="range" min="0" max={Math.max(0.1, Number(data.maxBurnRate || 0))} step="0.1" value={Math.min(burnRate, Math.max(0.1, Number(data.maxBurnRate || 0)))} onChange={(event) => setBurnRate(Number(event.target.value))} />
        <button className="button primary" disabled={!reactor.online || burnRate < 0 || burnRate > Number(data.maxBurnRate || 0)} onClick={() => sendCommand("set_burn_rate", { burnRate })}>Применить лимит</button>
        <div className="button-row">
          <button className="button success" disabled={!reactor.online || data.running} onClick={() => sendCommand("reactor_start")}>Start</button>
          <button className="button danger" disabled={!reactor.online || !data.running} onClick={() => sendCommand("reactor_scram")}>SCRAM</button>
        </div>
        <div className="safety-note">Local threshold control remains active when the website is offline.</div>
        {commandResult && <p className={`command-result ${commandResult.ok ? "ok" : "error"}`}>{commandResult.message}</p>}
      </aside>
    </section>
  );
}

function TurbinesPanel({ turbines }) {
  if (!turbines.length) {
    return (
      <section className="empty-module">
        <div className="module-icon"><Icon name="turbine" size={34} /></div>
        <p className="eyebrow">INFRASTRUCTURE READY</p>
        <h2>Turbine monitoring</h2>
        <p>Connect one or more Mekanism turbine valves to a CC computer. Every <code>turbineValue_*</code> peripheral will be discovered automatically.</p>
      </section>
    );
  }

  return (
    <section className="turbine-grid">
      {turbines.map((unit, index) => {
        const data = unit.data || {};
        return (
          <article className="hero-card" key={`${unit.computerId}-${data.peripheral || index}`}>
            <SectionHeading eyebrow="MEKANISM TURBINE" title={data.peripheral || `Turbine ${index + 1}`} online={unit.online} />
            <div className="metrics-row">
              <Metric label="Production" value={formatRate(data.production)} tone="good" />
              <Metric label="Flow" value={`${Number(data.flowRate || 0).toFixed(1)} mB/t`} />
              <Metric label="Steam" value={`${Number(data.steamPercent || 0).toFixed(1)}%`} />
              <Metric label="Internal energy" value={`${Number(data.energyPercent || 0).toFixed(1)}%`} />
            </div>
          </article>
        );
      })}
    </section>
  );
}

function ItemIcon({ item }) {
  const [source, setSource] = useState(0);
  const [namespace = "?", path = "item"] = String(item.name || "").split(":");
  const urls = namespace === "minecraft" ? [
    `https://mcasset.cloud/1.20.1/assets/minecraft/textures/item/${path}.png`,
    `https://mcasset.cloud/1.20.1/assets/minecraft/textures/block/${path}.png`,
  ] : [];
  const hue = [...namespace].reduce((sum, character) => sum + character.charCodeAt(0), 0) % 360;

  return (
    <div className="item-icon" style={{ "--item-hue": hue }}>
      {source < urls.length ? (
        <img src={urls[source]} alt="" loading="lazy" onError={() => setSource((current) => current + 1)} />
      ) : (
        <span>{namespace.slice(0, 2).toUpperCase()}</span>
      )}
    </div>
  );
}

function StoragePanel({ storage }) {
  const [query, setQuery] = useState("");
  const filteredItems = useMemo(() => {
    const normalized = query.trim().toLowerCase();
    return (storage.items || []).filter((item) => !normalized || `${item.displayName || ""} ${item.name || ""}`.toLowerCase().includes(normalized));
  }, [query, storage.items]);
  const visibleItems = filteredItems.slice(0, 600);
  const totalItems = useMemo(() => (storage.items || []).reduce((sum, item) => sum + Number(item.count || 0), 0), [storage.items]);

  return (
    <section className="storage-card">
      <SectionHeading eyebrow="APPLIED ENERGISTICS 2" title="ME Storage" online={storage.online && storage.connected} onlineText="Network online" offlineText="Network offline" />
      <div className="storage-toolbar">
        <div className="storage-stats"><Metric label="Item types" value={(storage.items || []).length.toLocaleString()} /><Metric label="Total items" value={totalItems.toLocaleString()} /></div>
        <div className="search-box"><Icon name="search" /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search items or registry names" /></div>
      </div>
      {storage.details && <p className="storage-details">{storage.details}</p>}
      <div className="item-grid">
        {visibleItems.map((item, index) => (
          <article className="item-card" key={`${item.name}-${item.fingerprint || index}`}>
            <ItemIcon item={item} />
            <div className="item-copy"><strong title={item.displayName || item.name}>{item.displayName || item.name}</strong><code title={item.name}>{item.name}</code></div>
            <span className="item-count">{Number(item.count || 0).toLocaleString()}</span>
          </article>
        ))}
      </div>
      {filteredItems.length > visibleItems.length && <p className="result-note">Showing first {visibleItems.length.toLocaleString()} of {filteredItems.length.toLocaleString()} results.</p>}
      {visibleItems.length === 0 && <div className="empty-state">No matching items</div>}
    </section>
  );
}

const defaultPalette = [
  "#f0f0f0", "#f2b233", "#e57fd8", "#99b2f2", "#dede6c", "#7fcc19", "#f2b2cc", "#4c4c4c",
  "#999999", "#4c99b2", "#b266e5", "#3366cc", "#7f664c", "#57a64e", "#cc4c4c", "#111111",
];

const browserKeyNames = {
  Enter: "enter", Backspace: "backspace", Tab: "tab", Escape: "escape", Delete: "delete", Insert: "insert",
  ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right", Home: "home", End: "end",
  PageUp: "pageUp", PageDown: "pageDown", " ": "space", "-": "minus", "=": "equals", "[": "leftBracket",
  "]": "rightBracket", ";": "semicolon", "'": "apostrophe", "`": "grave", "\\": "backslash", ",": "comma",
  ".": "period", "/": "slash",
};
const digitKeyNames = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"];

function browserKeyName(event) {
  if (browserKeyNames[event.key]) return browserKeyNames[event.key];
  if (/^[a-z]$/i.test(event.key)) return event.key.toLowerCase();
  if (/^[0-9]$/.test(event.key)) return digitKeyNames[Number(event.key)];
  if (/^F([1-9]|1[0-2])$/.test(event.key)) return event.key.toLowerCase();
  if (event.key === "Control") return event.location === 2 ? "rightCtrl" : "leftCtrl";
  if (event.key === "Shift") return event.location === 2 ? "rightShift" : "leftShift";
  if (event.key === "Alt") return event.location === 2 ? "rightAlt" : "leftAlt";
  return null;
}

function paletteColor(palette, code) {
  const index = Number.parseInt(code || "f", 16);
  const rgb = palette?.[index];
  return Array.isArray(rgb) ? `rgb(${rgb[0]}, ${rgb[1]}, ${rgb[2]})` : defaultPalette[index] || defaultPalette[15];
}

function TerminalScreen({ terminal, sendTerminalInput }) {
  const pressed = useRef(new Set());
  const screenRef = useRef(null);

  function send(event, values = {}) {
    if (terminal?.online) sendTerminalInput(terminal.computerId, event, values);
  }

  function onKeyDown(event) {
    if (!terminal?.online) return;
    // Let the browser emit a ClipboardEvent. Preventing Ctrl+V here stops the
    // paste handler below from receiving the clipboard text.
    if ((event.ctrlKey || event.metaKey) && event.code === "KeyV") return;
    const key = browserKeyName(event);
    const printable = event.key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey;
    if (key && !printable && !pressed.current.has(event.code)) {
      pressed.current.add(event.code);
      send("key", { key, held: event.repeat });
    }
    if (printable) send("char", { value: event.key });
    if (key || event.key.length === 1) event.preventDefault();
  }

  function onKeyUp(event) {
    if ((event.ctrlKey || event.metaKey) && event.code === "KeyV") return;
    const key = browserKeyName(event);
    pressed.current.delete(event.code);
    const printable = event.key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey;
    if (key && !printable) {
      send("key_up", { key });
      event.preventDefault();
    }
  }

  function mousePosition(event) {
    const bounds = screenRef.current.getBoundingClientRect();
    return {
      x: Math.max(1, Math.min(terminal.width, Math.floor(((event.clientX - bounds.left) / bounds.width) * terminal.width) + 1)),
      y: Math.max(1, Math.min(terminal.height, Math.floor(((event.clientY - bounds.top) / bounds.height) * terminal.height) + 1)),
    };
  }

  function mouseButton(event) {
    return event.button === 2 ? 2 : event.button === 1 ? 3 : 1;
  }

  return (
    <div
      ref={screenRef}
      className="craftos-screen"
      style={{ "--term-columns": terminal?.width || 51, "--term-rows": terminal?.height || 19 }}
      tabIndex={0}
      onKeyDown={onKeyDown}
      onKeyUp={onKeyUp}
      onPaste={(event) => { send("paste", { value: event.clipboardData.getData("text") }); event.preventDefault(); }}
      onMouseDown={(event) => { screenRef.current.focus(); send("mouse_click", { button: mouseButton(event), ...mousePosition(event) }); event.preventDefault(); }}
      onMouseUp={(event) => { send("mouse_up", { button: mouseButton(event), ...mousePosition(event) }); event.preventDefault(); }}
      onMouseMove={(event) => { if (event.buttons) send("mouse_drag", { button: event.buttons & 2 ? 2 : 1, ...mousePosition(event) }); }}
      onWheel={(event) => { send("mouse_scroll", { button: event.deltaY > 0 ? 1 : -1, ...mousePosition(event) }); event.preventDefault(); }}
      onContextMenu={(event) => event.preventDefault()}
    >
      {(terminal?.lines || []).map((line, y) => (
        <div className="craftos-row" key={y}>
          {[...(line.text || "")].map((character, x) => {
            const cursor = terminal.cursorBlink && terminal.cursorX === x + 1 && terminal.cursorY === y + 1;
            return <span key={x} className={cursor ? "craftos-cursor" : ""} style={{ color: paletteColor(terminal.palette, line.fg?.[x]), backgroundColor: paletteColor(terminal.palette, line.bg?.[x]) }}>{character}</span>;
          })}
        </div>
      ))}
      {!terminal && <div className="terminal-placeholder">Удалённые терминалы пока не подключены</div>}
    </div>
  );
}

function ConsolePanel({ terminals, sendTerminalInput }) {
  const terminalList = useMemo(() => Object.values(terminals || {}).sort((a, b) => Number(a.computerId) - Number(b.computerId)), [terminals]);
  const [target, setTarget] = useState(null);
  useEffect(() => {
    if (!terminalList.length) setTarget(null);
    else if (!terminalList.some((terminal) => String(terminal.computerId) === String(target))) setTarget(String(terminalList[0].computerId));
  }, [terminalList, target]);
  const terminal = terminalList.find((entry) => String(entry.computerId) === String(target));

  return (
    <section className="console-layout">
      <aside className="computer-list">
        <p className="eyebrow">CRAFTOS TERMINALS</p>
        {terminalList.map((entry) => (
          <button key={entry.computerId} className={String(target) === String(entry.computerId) ? "selected" : ""} onClick={() => setTarget(String(entry.computerId))}>
            <span className="computer-icon"><Icon name="terminal" /></span>
            <span><strong>{entry.label || `Computer ${entry.computerId}`}</strong><small>ID {entry.computerId}</small></span>
            <i className={entry.online ? "online" : ""} />
          </button>
        ))}
        {!terminalList.length && <p className="muted">Нет подключённых терминалов</p>}
      </aside>
      <div className="terminal-card craftos-card">
        <div className="terminal-title"><span>CRAFTOS REMOTE TERMINAL</span><span>{terminal ? `COMPUTER ${terminal.computerId}` : "OFFLINE"}</span></div>
        <div className="craftos-stage"><TerminalScreen terminal={terminal} sendTerminalInput={sendTerminalInput} /></div>
        <div className="terminal-actions">
          <span>Кликните по экрану и печатайте. Работают клавиши, вставка и мышь.</span>
          <button className="button danger" disabled={!terminal?.online} onClick={() => sendTerminalInput(terminal.computerId, "terminate")}>Terminate</button>
        </div>
      </div>
    </section>
  );
}

const tabs = [
  ["matrix", "Matrix"],
  ["reactor", "Reactor"],
  ["turbine", "Turbines"],
  ["storage", "Storage"],
  ["terminal", "Consoles"],
];

export default function App() {
  const [accessToken, setAccessToken] = useState(() => window.localStorage.getItem("kenzu_cc_token") || "");
  const [tokenDraft, setTokenDraft] = useState(accessToken);
  const [authError, setAuthError] = useState("");
  const [activeTab, setActiveTab] = useState("matrix");
  const [systemState, setSystemState] = useState(initialState);
  const [serverOnline, setServerOnline] = useState(false);
  const [commandResult, setCommandResult] = useState(null);
  const [reactorHistory, setReactorHistory] = useState([]);
  const socketRef = useRef(null);

  useEffect(() => {
    if (!accessToken) return undefined;
    let reconnectTimer;
    let disposed = false;

    function connect() {
      const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
      const socket = new WebSocket(`${protocol}//${window.location.host}/ws`);
      socketRef.current = socket;
      socket.addEventListener("open", () => socket.send(JSON.stringify({ type: "hello", role: "browser", token: accessToken })));
      socket.addEventListener("message", (event) => {
        const message = JSON.parse(event.data);
        if (message.type === "auth_error") {
          window.localStorage.removeItem("kenzu_cc_token");
          setAuthError(message.message || "Invalid access token");
          setAccessToken("");
          socket.close();
          return;
        }
        if (message.type === "state") { setServerOnline(true); setSystemState(message.state); }
        if (message.type === "matrix_state") setSystemState((current) => ({ ...current, matrix: message.matrix }));
        if (message.type === "reactor_state") {
          setSystemState((current) => ({ ...current, reactor: message.reactor }));
          if (message.reactor?.data) setReactorHistory((current) => [...current, {
            at: Date.now(),
            temperature: Number(message.reactor.data.temperature || 0),
            heatingRate: Number(message.reactor.data.heatingRate || 0),
          }].slice(-180));
        }
        if (message.type === "turbines_state") setSystemState((current) => ({ ...current, turbines: message.turbines }));
        if (message.type === "storage_state") setSystemState((current) => ({ ...current, storage: message.storage }));
        if (message.type === "storage_status") setSystemState((current) => ({ ...current, storage: { ...current.storage, ...message.storage } }));
        if (message.type === "computers_state") setSystemState((current) => ({ ...current, computers: message.computers }));
        if (message.type === "terminal_frame") setSystemState((current) => ({
          ...current,
          terminals: { ...current.terminals, [String(message.terminal.computerId)]: message.terminal },
        }));
        if (message.type === "system_status") setSystemState((current) => ({
          ...current,
          matrix: message.matrix,
          reactor: message.reactor,
          turbines: message.turbines,
          computers: message.computers,
          terminals: message.terminals || current.terminals,
          storage: { ...current.storage, ...message.storage },
        }));
        if (message.type === "console_output") setSystemState((current) => ({ ...current, consoleHistory: [...(current.consoleHistory || []), message].slice(-200) }));
        if (message.type === "command_result") setCommandResult(message);
      });
      socket.addEventListener("close", () => {
        setServerOnline(false);
        if (!disposed) reconnectTimer = window.setTimeout(connect, 2000);
      });
    }

    connect();
    return () => { disposed = true; window.clearTimeout(reconnectTimer); socketRef.current?.close(); };
  }, [accessToken]);

  function send(payload) {
    if (socketRef.current?.readyState !== WebSocket.OPEN) return false;
    socketRef.current.send(JSON.stringify(payload));
    return true;
  }

  function sendCommand(action, values = {}) {
    setCommandResult(null);
    if (!send({ type: "command", requestId: `${Date.now()}`, action, ...values })) setCommandResult({ ok: false, message: "Server connection is offline" });
  }

  function sendConsoleCommand(target, command) {
    send({ type: "console_command", requestId: `${Date.now()}`, target, command });
  }

  function sendTerminalInput(target, event, values = {}) {
    send({ type: "terminal_input", target: String(target), event, ...values });
  }

  function saveToken(event) {
    event.preventDefault();
    const token = tokenDraft.trim();
    if (!token) return;
    window.localStorage.setItem("kenzu_cc_token", token);
    setAuthError("");
    setAccessToken(token);
  }

  function changeToken() {
    socketRef.current?.close();
    window.localStorage.removeItem("kenzu_cc_token");
    setAccessToken("");
    setServerOnline(false);
  }

  if (!accessToken) {
    return <main className="auth-shell"><form className="auth-card" onSubmit={saveToken}><div className="brand-mark">K</div><p className="eyebrow">ATM9 OPERATIONS</p><h1>Kenzu Control</h1><p>Enter the access token configured on the server.</p><input type="password" value={tokenDraft} onChange={(event) => setTokenDraft(event.target.value)} placeholder="Access token" autoFocus /><button className="button primary" type="submit">Connect</button>{authError && <p className="command-result error">{authError}</p>}</form></main>;
  }

  let content;
  if (activeTab === "matrix") content = <MatrixPanel matrix={systemState.matrix} />;
  if (activeTab === "reactor") content = <ReactorPanel reactor={systemState.reactor} history={reactorHistory} sendCommand={sendCommand} commandResult={commandResult} />;
  if (activeTab === "turbine") content = <TurbinesPanel turbines={systemState.turbines || []} />;
  if (activeTab === "storage") content = <StoragePanel storage={systemState.storage} />;
  if (activeTab === "terminal") content = <ConsolePanel terminals={systemState.terminals} sendTerminalInput={sendTerminalInput} />;

  return (
    <main className="app-shell">
      <header><div className="brand-mark">K</div><div><p className="eyebrow">ATM9 OPERATIONS</p><h1>Kenzu Control</h1></div><Indicator active={serverOnline}>{serverOnline ? "Server connected" : "Server offline"}</Indicator><button className="token-button" onClick={changeToken}>Change token</button></header>
      <nav>{tabs.map(([id, label]) => <button key={id} className={activeTab === id ? "active" : ""} onClick={() => setActiveTab(id)}><Icon name={id} />{label}</button>)}</nav>
      {content}
    </main>
  );
}
