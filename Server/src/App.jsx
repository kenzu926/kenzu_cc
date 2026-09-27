import { useEffect, useMemo, useRef, useState } from "react";

const initialState = {
  reactor: { online: false, data: null },
  storage: { online: false, connected: false, items: [] },
  lastCommand: null,
};

function Indicator({ active, children }) {
  return (
    <span className={`indicator ${active ? "online" : "offline"}`}>
      <i /> {children}
    </span>
  );
}

function Metric({ label, value, tone = "default" }) {
  return (
    <article className={`metric ${tone}`}>
      <span>{label}</span>
      <strong>{value}</strong>
    </article>
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

  const energy = Math.max(0, Math.min(100, Number(data.energyPercent || 0)));

  return (
    <section className="panel-grid">
      <div className="hero-card">
        <div className="card-heading">
          <div>
            <p className="eyebrow">ENERGY CORE</p>
            <h2>Induction Matrix</h2>
          </div>
          <Indicator active={reactor.online}>
            {reactor.online ? "Computer online" : "Computer offline"}
          </Indicator>
        </div>

        <div className="energy-value">{energy.toFixed(1)}%</div>
        <div className="energy-track"><span style={{ width: `${energy}%` }} /></div>

        <div className="metrics-row">
          <Metric
            label="Reactor"
            value={data.running ? "ONLINE" : "SCRAMMED"}
            tone={data.running ? "good" : "danger"}
          />
          <Metric label="Temperature" value={`${Number(data.temperature || 0).toFixed(0)} K`} />
          <Metric label="Damage" value={`${Number(data.damage || 0).toFixed(1)}%`} />
          <Metric label="Burn rate" value={`${Number(data.actualBurnRate || 0).toFixed(1)} mB/t`} />
        </div>
      </div>

      <div className="control-card">
        <div className="card-heading">
          <div>
            <p className="eyebrow">AUTOMATION</p>
            <h2>Reactor control</h2>
          </div>
        </div>

        <label>
          Start at
          <div className="number-field">
            <input
              type="number"
              min="0"
              max="99"
              value={startPercent}
              onChange={(event) => setStartPercent(Number(event.target.value))}
            />
            <span>%</span>
          </div>
        </label>

        <label>
          Stop at
          <div className="number-field">
            <input
              type="number"
              min="1"
              max="100"
              value={stopPercent}
              onChange={(event) => setStopPercent(Number(event.target.value))}
            />
            <span>%</span>
          </div>
        </label>

        <button
          className="button primary"
          disabled={!reactor.online}
          onClick={() => sendCommand("set_thresholds", { startPercent, stopPercent })}
        >
          Save thresholds
        </button>

        <div className="button-row">
          <button
            className="button success"
            disabled={!reactor.online || data.running}
            onClick={() => sendCommand("reactor_start")}
          >
            Start reactor
          </button>
          <button
            className="button danger"
            disabled={!reactor.online || !data.running}
            onClick={() => sendCommand("reactor_scram")}
          >
            SCRAM
          </button>
        </div>

        {commandResult && (
          <p className={`command-result ${commandResult.ok ? "ok" : "error"}`}>
            {commandResult.message}
          </p>
        )}
      </div>
    </section>
  );
}

function StoragePanel({ storage }) {
  const [query, setQuery] = useState("");
  const items = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase();
    return (storage.items || []).filter((item) => {
      if (!normalizedQuery) return true;
      return `${item.displayName || ""} ${item.name || ""}`
        .toLowerCase()
        .includes(normalizedQuery);
    });
  }, [query, storage.items]);

  const totalItems = useMemo(
    () => (storage.items || []).reduce((sum, item) => sum + Number(item.count || 0), 0),
    [storage.items],
  );

  return (
    <section className="storage-card">
      <div className="card-heading storage-heading">
        <div>
          <p className="eyebrow">APPLIED ENERGISTICS 2</p>
          <h2>ME Storage</h2>
        </div>
        <div className="status-stack">
          <Indicator active={storage.online}>
            {storage.online ? "Node online" : "Node offline"}
          </Indicator>
          <Indicator active={storage.connected}>
            {storage.connected ? "ME connected" : "ME disconnected"}
          </Indicator>
        </div>
      </div>

      <div className="storage-summary">
        <Metric label="Item types" value={(storage.items || []).length.toLocaleString()} />
        <Metric label="Total items" value={totalItems.toLocaleString()} />
        <div className="search-box">
          <span>⌕</span>
          <input
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Search item or ID..."
          />
        </div>
      </div>

      <div className="item-table">
        <div className="item-row table-header">
          <span>Item</span><span>Registry name</span><span>Count</span>
        </div>
        {items.map((item, index) => (
          <div className="item-row" key={`${item.name}-${item.fingerprint || index}`}>
            <strong>{item.displayName || item.name}</strong>
            <code>{item.name}</code>
            <span className="item-count">{Number(item.count || 0).toLocaleString()}</span>
          </div>
        ))}
        {items.length === 0 && (
          <div className="empty-state">No items to display</div>
        )}
      </div>
    </section>
  );
}

export default function App() {
  const [accessToken, setAccessToken] = useState(
    () => window.localStorage.getItem("kenzu_cc_token") || "",
  );
  const [tokenDraft, setTokenDraft] = useState(accessToken);
  const [authError, setAuthError] = useState("");
  const [activeTab, setActiveTab] = useState("reactor");
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

      socket.addEventListener("open", () => {
        socket.send(JSON.stringify({ type: "hello", role: "browser", token: accessToken }));
      });

      socket.addEventListener("message", (event) => {
        const message = JSON.parse(event.data);
        if (message.type === "auth_error") {
          window.localStorage.removeItem("kenzu_cc_token");
          setAuthError(message.message || "Invalid access token");
          setAccessToken("");
          socket.close();
          return;
        }
        if (message.type === "state") {
          setServerOnline(true);
          setSystemState(message.state);
        }
        if (message.type === "reactor_state") {
          setSystemState((current) => ({ ...current, reactor: message.reactor }));
        }
        if (message.type === "storage_state") {
          setSystemState((current) => ({ ...current, storage: message.storage }));
        }
        if (message.type === "storage_status") {
          setSystemState((current) => ({
            ...current,
            storage: { ...current.storage, ...message.storage },
          }));
        }
        if (message.type === "command_result") setCommandResult(message);
      });

      socket.addEventListener("close", () => {
        setServerOnline(false);
        if (!disposed) reconnectTimer = window.setTimeout(connect, 2000);
      });
    }

    connect();
    return () => {
      disposed = true;
      window.clearTimeout(reconnectTimer);
      socketRef.current?.close();
    };
  }, [accessToken]);

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

  function sendCommand(action, values = {}) {
    setCommandResult(null);
    if (socketRef.current?.readyState !== WebSocket.OPEN) {
      setCommandResult({ ok: false, message: "Server connection is offline" });
      return;
    }
    socketRef.current.send(JSON.stringify({
      type: "command",
      requestId: `${Date.now()}`,
      action,
      ...values,
    }));
  }

  if (!accessToken) {
    return (
      <main className="auth-shell">
        <form className="auth-card" onSubmit={saveToken}>
          <div className="brand-mark">K</div>
          <p className="eyebrow">ATM9 OPERATIONS</p>
          <h1>Kenzu Control</h1>
          <p>Enter the same access token that is configured on the server.</p>
          <input
            type="password"
            value={tokenDraft}
            onChange={(event) => setTokenDraft(event.target.value)}
            placeholder="Access token"
            autoFocus
          />
          <button className="button primary" type="submit">Connect</button>
          {authError && <p className="command-result error">{authError}</p>}
        </form>
      </main>
    );
  }

  return (
    <main className="app-shell">
      <header>
        <div className="brand-mark">K</div>
        <div>
          <p className="eyebrow">ATM9 OPERATIONS</p>
          <h1>Kenzu Control</h1>
        </div>
        <Indicator active={serverOnline}>
          {serverOnline ? "Server connected" : "Server offline"}
        </Indicator>
        <button className="token-button" onClick={changeToken}>Change token</button>
      </header>

      <nav>
        <button className={activeTab === "reactor" ? "active" : ""} onClick={() => setActiveTab("reactor")}>Reactor</button>
        <button className={activeTab === "storage" ? "active" : ""} onClick={() => setActiveTab("storage")}>Storage</button>
      </nav>

      {activeTab === "reactor" ? (
        <ReactorPanel
          reactor={systemState.reactor}
          sendCommand={sendCommand}
          commandResult={commandResult}
        />
      ) : (
        <StoragePanel storage={systemState.storage} />
      )}
    </main>
  );
}
