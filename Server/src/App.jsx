import { useEffect, useMemo, useRef, useState } from "react";

const initialState = {
  matrix: { online: false, data: null },
  reactor: { online: false, data: null },
  turbines: [],
  storage: { online: false, connected: false, items: [] },
  computers: {},
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

function ReactorPanel({ reactor, sendCommand, commandResult }) {
  const data = reactor.data || {};
  const [startPercent, setStartPercent] = useState(data.startPercent ?? 80);
  const [stopPercent, setStopPercent] = useState(data.stopPercent ?? 98);

  useEffect(() => {
    if (data.startPercent != null) setStartPercent(data.startPercent);
    if (data.stopPercent != null) setStopPercent(data.stopPercent);
  }, [data.startPercent, data.stopPercent]);

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
          <Metric label="Coolant" value={`${Number(data.coolantPercent || 0).toFixed(1)}%`} />
          <Metric label="Heated coolant" value={`${Number(data.heatedCoolantPercent || 0).toFixed(1)}%`} />
          <Metric label="Fuel" value={`${Number(data.fuelPercent || 0).toFixed(1)}%`} />
          <Metric label="Waste" value={`${Number(data.wastePercent || 0).toFixed(1)}%`} tone={Number(data.wastePercent) > 80 ? "danger" : "default"} />
        </div>
      </article>

      <aside className="control-card">
        <SectionHeading eyebrow="AUTOMATION" title="Reactor control" />
        <label>Start at<div className="number-field"><input type="number" min="0" max="99" value={startPercent} onChange={(event) => setStartPercent(Number(event.target.value))} /><span>%</span></div></label>
        <label>Stop at<div className="number-field"><input type="number" min="1" max="100" value={stopPercent} onChange={(event) => setStopPercent(Number(event.target.value))} /><span>%</span></div></label>
        <button className="button primary" disabled={!reactor.online} onClick={() => sendCommand("set_thresholds", { startPercent, stopPercent })}>Save thresholds</button>
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
        <p>Connect a Mekanism turbine valve to a CC computer. The installer already includes <code>turbine.lua</code>, and this page will populate automatically.</p>
      </section>
    );
  }

  return (
    <section className="turbine-grid">
      {turbines.map((unit, index) => {
        const data = unit.data || {};
        return (
          <article className="hero-card" key={`${unit.computerId}-${index}`}>
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

function ConsolePanel({ computers, storage, history, sendConsoleCommand }) {
  const [target, setTarget] = useState("reactor");
  const [command, setCommand] = useState("status");
  const [localHistory, setLocalHistory] = useState(history || []);
  const bottomRef = useRef(null);

  useEffect(() => setLocalHistory(history || []), [history]);
  useEffect(() => bottomRef.current?.scrollIntoView({ behavior: "smooth" }), [localHistory]);

  const targets = useMemo(() => {
    const result = new Map();
    for (const computer of Object.values(computers || {})) result.set(computer.role, computer);
    if (storage.online && !result.has("storage_node")) result.set("storage_node", { role: "storage_node", computerId: storage.computerId, online: true, label: "Rednet relay" });
    return [...result.values()];
  }, [computers, storage]);

  function submit(event) {
    event.preventDefault();
    const value = command.trim();
    if (!value) return;
    if (value === "clear") {
      setLocalHistory([]);
      setCommand("");
      return;
    }
    setLocalHistory((current) => [...current, { target, output: `> ${value}`, ok: true, at: Date.now(), local: true }]);
    sendConsoleCommand(target, value);
    setCommand("");
  }

  return (
    <section className="console-layout">
      <aside className="computer-list">
        <p className="eyebrow">CONNECTED COMPUTERS</p>
        {targets.map((computer) => (
          <button key={`${computer.role}-${computer.computerId}`} className={target === computer.role ? "selected" : ""} onClick={() => setTarget(computer.role)}>
            <span className="computer-icon"><Icon name="terminal" /></span>
            <span><strong>{computer.label || computer.role}</strong><small>ID {computer.computerId ?? "relay"}</small></span>
            <i className={computer.online ? "online" : ""} />
          </button>
        ))}
        {!targets.length && <p className="muted">No CC computers online</p>}
      </aside>
      <div className="terminal-card">
        <div className="terminal-title"><span>KENZU REMOTE DIAGNOSTICS</span><span>{target}</span></div>
        <div className="terminal-output">
          {localHistory.filter((entry) => entry.target === target).map((entry, index) => (
            <pre className={entry.ok ? "" : "failed"} key={`${entry.at}-${index}`}>{entry.output}</pre>
          ))}
          <div ref={bottomRef} />
        </div>
        <form className="terminal-input" onSubmit={submit}><span>$</span><input value={command} onChange={(event) => setCommand(event.target.value)} placeholder="help, status, peripherals, methods <name>" autoComplete="off" /><button type="submit">Run</button></form>
        <p className="terminal-help">Only safe diagnostic commands are accepted. Use <code>clear</code> to clear this view.</p>
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
        if (message.type === "reactor_state") setSystemState((current) => ({ ...current, reactor: message.reactor }));
        if (message.type === "turbines_state") setSystemState((current) => ({ ...current, turbines: message.turbines }));
        if (message.type === "storage_state") setSystemState((current) => ({ ...current, storage: message.storage }));
        if (message.type === "storage_status") setSystemState((current) => ({ ...current, storage: { ...current.storage, ...message.storage } }));
        if (message.type === "computers_state") setSystemState((current) => ({ ...current, computers: message.computers }));
        if (message.type === "system_status") setSystemState((current) => ({
          ...current,
          matrix: message.matrix,
          reactor: message.reactor,
          turbines: message.turbines,
          computers: message.computers,
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
  if (activeTab === "reactor") content = <ReactorPanel reactor={systemState.reactor} sendCommand={sendCommand} commandResult={commandResult} />;
  if (activeTab === "turbine") content = <TurbinesPanel turbines={systemState.turbines || []} />;
  if (activeTab === "storage") content = <StoragePanel storage={systemState.storage} />;
  if (activeTab === "terminal") content = <ConsolePanel computers={systemState.computers} storage={systemState.storage} history={systemState.consoleHistory} sendConsoleCommand={sendConsoleCommand} />;

  return (
    <main className="app-shell">
      <header><div className="brand-mark">K</div><div><p className="eyebrow">ATM9 OPERATIONS</p><h1>Kenzu Control</h1></div><Indicator active={serverOnline}>{serverOnline ? "Server connected" : "Server offline"}</Indicator><button className="token-button" onClick={changeToken}>Change token</button></header>
      <nav>{tabs.map(([id, label]) => <button key={id} className={activeTab === id ? "active" : ""} onClick={() => setActiveTab(id)}><Icon name={id} />{label}</button>)}</nav>
      {content}
    </main>
  );
}
