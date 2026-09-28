import express from "express";
import { timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { WebSocket, WebSocketServer } from "ws";

const PORT = Number(process.env.PORT || 3000);
const HOST = process.env.HOST || "0.0.0.0";
const AUTH_TOKEN = process.env.CC_AUTH_TOKEN || "";
const OFFLINE_AFTER_MS = 20_000;
const CONSOLE_HISTORY_LIMIT = 200;
const rootDirectory = dirname(fileURLToPath(import.meta.url));
const distDirectory = join(rootDirectory, "dist");

if (AUTH_TOKEN.length < 24) {
  console.error("CC_AUTH_TOKEN must contain at least 24 characters.");
  process.exit(1);
}

const app = express();
const server = createServer(app);
const websocketServer = new WebSocketServer({ server, path: "/ws" });

const state = {
  matrix: { online: false, lastSeen: null, computerId: null, data: null },
  reactor: { online: false, lastSeen: null, computerId: null, data: null },
  turbines: [],
  storage: {
    online: false,
    lastSeen: null,
    computerId: null,
    connected: false,
    details: "Waiting for storage node",
    items: [],
    updatedAt: null,
  },
  computers: {},
  terminals: {},
  consoleHistory: [],
  lastCommand: null,
};

const clients = new Set();
const roleClients = new Map([
  ["reactor", new Set()],
  ["storage_node", new Set()],
  ["turbine", new Set()],
  ["terminal", new Set()],
]);
const storageSnapshots = new WeakMap();
const turbineUnits = new Map();

function tokenMatches(candidate) {
  if (typeof candidate !== "string") return false;
  const supplied = Buffer.from(candidate);
  const expected = Buffer.from(AUTH_TOKEN);
  return supplied.length === expected.length && timingSafeEqual(supplied, expected);
}

function send(socket, payload) {
  if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(payload));
}

function broadcastToBrowsers(payload) {
  for (const client of clients) {
    if (client.role === "browser") send(client, payload);
  }
}

function publicState() {
  return {
    matrix: state.matrix,
    reactor: state.reactor,
    turbines: state.turbines,
    storage: state.storage,
    computers: state.computers,
    terminals: state.terminals,
    consoleHistory: state.consoleHistory,
    lastCommand: state.lastCommand,
  };
}

function computerKey(role, computerId) {
  return `${role}:${computerId ?? "unknown"}`;
}

function touchComputer(socket) {
  if (!socket.role || socket.role === "browser" || socket.role === "unknown") return;
  const key = computerKey(socket.role, socket.computerId);
  state.computers[key] = {
    role: socket.role,
    computerId: socket.computerId,
    label: socket.label || null,
    online: true,
    lastSeen: Date.now(),
  };
}

function broadcastComputers() {
  broadcastToBrowsers({ type: "computers_state", computers: state.computers });
}

function validateCommand(message) {
  const allowed = new Set(["reactor_start", "reactor_scram", "set_thresholds", "set_burn_rate"]);
  if (!allowed.has(message.action)) return "Unknown command";
  if (message.action === "set_burn_rate") {
    const burnRate = Number(message.burnRate);
    if (!Number.isFinite(burnRate) || burnRate < 0 || burnRate > 1_000_000) {
      return "Burn rate must be a positive number";
    }
    return null;
  }
  if (message.action !== "set_thresholds") return null;

  const start = Number(message.startPercent);
  const stop = Number(message.stopPercent);
  if (!Number.isInteger(start) || !Number.isInteger(stop)) {
    return "Thresholds must be whole numbers";
  }
  if (start < 0 || stop > 100 || start >= stop) {
    return "Thresholds must satisfy 0 <= start < stop <= 100";
  }
  return null;
}

function sendToRole(role, payload) {
  let recipients = 0;
  for (const socket of roleClients.get(role) || []) {
    if (socket.readyState === WebSocket.OPEN) {
      send(socket, payload);
      recipients += 1;
    }
  }
  return recipients;
}

function routeTerminalInput(browser, message) {
  const target = String(message.target ?? "");
  const allowedEvents = new Set([
    "key", "key_up", "char", "paste", "terminate",
    "mouse_click", "mouse_up", "mouse_drag", "mouse_scroll",
  ]);
  if (!target || !allowedEvents.has(message.event)) {
    send(browser, { type: "terminal_error", message: "Invalid terminal input" });
    return;
  }

  const payload = {
    type: "terminal_input",
    event: message.event,
    key: typeof message.key === "string" ? message.key.slice(0, 32) : undefined,
    value: typeof message.value === "string" ? message.value.slice(0, 4096) : undefined,
    held: message.held === true,
    button: Number(message.button),
    x: Number(message.x),
    y: Number(message.y),
  };
  let recipients = 0;
  for (const terminalSocket of roleClients.get("terminal") || []) {
    if (String(terminalSocket.computerId) === target) {
      send(terminalSocket, payload);
      recipients += 1;
    }
  }
  if (recipients === 0) recipients = sendToRole("reactor", { ...payload, target });
  if (recipients === 0) send(browser, { type: "terminal_error", message: "Terminal is offline" });
}

function routeConsoleCommand(browser, message) {
  const command = String(message.command || "").trim();
  const target = String(message.target || "");
  if (!command || command.length > 256) {
    send(browser, { type: "console_output", ok: false, target, output: "Invalid command" });
    return;
  }

  const payload = {
    type: "console_command",
    requestId: message.requestId || `${Date.now()}`,
    target,
    command,
  };

  let recipients = 0;
  if (target === "storage_node") {
    recipients = sendToRole("storage_node", payload);
    if (recipients === 0) recipients = sendToRole("reactor", payload);
  } else if (roleClients.has(target)) {
    recipients = sendToRole(target, payload);
  } else {
    for (const socket of clients) {
      if (socket.role !== "browser" && String(socket.computerId) === target) {
        send(socket, payload);
        recipients += 1;
      }
    }
  }

  if (recipients === 0) {
    send(browser, {
      type: "console_output",
      requestId: payload.requestId,
      target,
      ok: false,
      output: "Target computer is offline",
      at: Date.now(),
    });
  }
}

websocketServer.on("connection", (socket) => {
  socket.role = "unknown";
  socket.authenticated = false;
  clients.add(socket);

  socket.on("message", (rawMessage) => {
    let message;
    try {
      message = JSON.parse(rawMessage.toString());
    } catch {
      send(socket, { type: "error", message: "Invalid JSON" });
      return;
    }

    if (message.type === "hello") {
      if (!tokenMatches(message.token)) {
        send(socket, { type: "auth_error", message: "Invalid access token" });
        socket.close(1008, "Invalid access token");
        return;
      }

      if (socket.authenticated) roleClients.get(socket.role)?.delete(socket);
      socket.authenticated = true;
      socket.role = String(message.role || "unknown");
      socket.computerId = message.computerId ?? null;
      socket.label = message.label ?? null;
      roleClients.get(socket.role)?.add(socket);
      touchComputer(socket);

      if (socket.role === "browser") send(socket, { type: "state", state: publicState() });
      else broadcastComputers();
      return;
    }

    if (!socket.authenticated) {
      socket.close(1008, "Authentication required");
      return;
    }

    touchComputer(socket);

    if (message.type === "ping") {
      send(socket, { type: "pong", sentAt: message.sentAt ?? null, serverAt: Date.now() });
      return;
    }

    if (message.type === "matrix_status" && socket.role === "reactor") {
      state.matrix = {
        online: true,
        lastSeen: Date.now(),
        computerId: socket.computerId,
        data: message.data,
      };
      broadcastToBrowsers({ type: "matrix_state", matrix: state.matrix });
      return;
    }

    if (message.type === "reactor_status" && socket.role === "reactor") {
      state.reactor = {
        online: true,
        lastSeen: Date.now(),
        computerId: socket.computerId,
        data: message.data,
      };
      broadcastToBrowsers({ type: "reactor_state", reactor: state.reactor });
      return;
    }

    if (message.type === "terminal_frame" && (socket.role === "terminal" || socket.role === "reactor")) {
      const sourceComputerId = message.computerId ?? socket.computerId;
      const key = String(sourceComputerId ?? "unknown");
      const lines = Array.isArray(message.lines) ? message.lines.slice(0, 80).map((line) => ({
        text: String(line?.text || "").slice(0, 200),
        fg: String(line?.fg || "").slice(0, 200),
        bg: String(line?.bg || "").slice(0, 200),
      })) : [];
      state.terminals[key] = {
        online: true,
        lastSeen: Date.now(),
        computerId: sourceComputerId,
        label: message.label || socket.label || null,
        width: Math.max(1, Math.min(200, Number(message.width) || 51)),
        height: Math.max(1, Math.min(80, Number(message.height) || 19)),
        cursorX: Number(message.cursorX) || 1,
        cursorY: Number(message.cursorY) || 1,
        cursorBlink: message.cursorBlink === true,
        palette: Array.isArray(message.palette) ? message.palette.slice(0, 16) : null,
        lines,
      };
      broadcastToBrowsers({ type: "terminal_frame", terminal: state.terminals[key] });
      return;
    }

    if (message.type === "turbine_status" && socket.role === "turbine") {
      const key = computerKey(socket.role, socket.computerId);
      turbineUnits.set(key, {
        online: true,
        lastSeen: Date.now(),
        computerId: socket.computerId,
        data: message.data,
      });
      state.turbines = [...turbineUnits.values()];
      broadcastToBrowsers({ type: "turbines_state", turbines: state.turbines });
      return;
    }

    const isStorageSource = socket.role === "storage_node" || socket.role === "reactor";
    if (message.type === "storage_status" && isStorageSource) {
      state.storage.online = true;
      state.storage.lastSeen = Date.now();
      state.storage.computerId = message.computerId ?? socket.computerId;
      state.storage.connected = message.connected === true;
      state.storage.details = message.details || "";
      broadcastToBrowsers({
        type: "storage_status",
        storage: {
          online: state.storage.online,
          lastSeen: state.storage.lastSeen,
          computerId: state.storage.computerId,
          connected: state.storage.connected,
          details: state.storage.details,
        },
      });
      return;
    }

    if (message.type === "storage_begin" && isStorageSource) {
      storageSnapshots.set(socket, { id: message.snapshotId, items: [] });
      return;
    }

    if (message.type === "storage_chunk" && isStorageSource) {
      const snapshot = storageSnapshots.get(socket);
      if (snapshot?.id === message.snapshotId && Array.isArray(message.items)) {
        snapshot.items.push(...message.items);
      }
      return;
    }

    if (message.type === "storage_end" && isStorageSource) {
      const snapshot = storageSnapshots.get(socket);
      if (snapshot?.id !== message.snapshotId) return;
      state.storage.items = snapshot.items;
      state.storage.updatedAt = Date.now();
      state.storage.online = true;
      state.storage.lastSeen = Date.now();
      storageSnapshots.delete(socket);
      broadcastToBrowsers({ type: "storage_state", storage: state.storage });
      return;
    }

    if (message.type === "command" && socket.role === "browser") {
      const error = validateCommand(message);
      if (error) {
        send(socket, { type: "command_result", ok: false, message: error });
        return;
      }

      const command = {
        type: "command",
        requestId: message.requestId || `${Date.now()}`,
        action: message.action,
        startPercent: message.startPercent,
        stopPercent: message.stopPercent,
        burnRate: message.burnRate,
      };
      if (sendToRole("reactor", command) === 0) {
        send(socket, { type: "command_result", ok: false, message: "Reactor computer is offline" });
      }
      return;
    }

    if (message.type === "command_result" && socket.role === "reactor") {
      state.lastCommand = {
        ok: message.ok === true,
        message: message.message || "",
        requestId: message.requestId || null,
        at: Date.now(),
      };
      broadcastToBrowsers({ type: "command_result", ...state.lastCommand });
      return;
    }

    if (message.type === "console_command" && socket.role === "browser") {
      routeConsoleCommand(socket, message);
      return;
    }

    if (message.type === "terminal_input" && socket.role === "browser") {
      routeTerminalInput(socket, message);
      return;
    }

    if (message.type === "console_output" && socket.role !== "browser") {
      const output = {
        type: "console_output",
        requestId: message.requestId || null,
        target: message.target || socket.role,
        computerId: message.computerId ?? socket.computerId,
        ok: message.ok === true,
        output: String(message.output || ""),
        at: Date.now(),
      };
      state.consoleHistory.push(output);
      if (state.consoleHistory.length > CONSOLE_HISTORY_LIMIT) state.consoleHistory.shift();
      broadcastToBrowsers(output);
    }
  });

  socket.on("close", () => {
    clients.delete(socket);
    roleClients.get(socket.role)?.delete(socket);
    storageSnapshots.delete(socket);

    if (socket.role !== "browser" && socket.role !== "unknown") {
      const key = computerKey(socket.role, socket.computerId);
      const replacement = [...(roleClients.get(socket.role) || [])]
        .some((candidate) => candidate.computerId === socket.computerId);
      if (!replacement && state.computers[key]) state.computers[key].online = false;
      if (socket.role === "terminal" && !replacement && state.terminals[String(socket.computerId)]) {
        state.terminals[String(socket.computerId)].online = false;
        broadcastToBrowsers({ type: "terminal_frame", terminal: state.terminals[String(socket.computerId)] });
      }
      broadcastComputers();
    }
  });
});

setInterval(() => {
  const now = Date.now();
  for (const computer of Object.values(state.computers)) {
    if (computer.online && now - computer.lastSeen > OFFLINE_AFTER_MS) computer.online = false;
  }
  for (const terminal of Object.values(state.terminals)) {
    if (terminal.online && now - terminal.lastSeen > OFFLINE_AFTER_MS) terminal.online = false;
  }
  if (state.matrix.online && now - state.matrix.lastSeen > OFFLINE_AFTER_MS) state.matrix.online = false;
  if (state.reactor.online && now - state.reactor.lastSeen > OFFLINE_AFTER_MS) state.reactor.online = false;
  if (state.storage.online && now - state.storage.lastSeen > OFFLINE_AFTER_MS) state.storage.online = false;
  for (const unit of turbineUnits.values()) {
    if (unit.online && now - unit.lastSeen > OFFLINE_AFTER_MS) unit.online = false;
  }
  state.turbines = [...turbineUnits.values()];
  broadcastToBrowsers({
    type: "system_status",
    matrix: state.matrix,
    reactor: state.reactor,
    turbines: state.turbines,
    computers: state.computers,
    terminals: state.terminals,
    storage: {
      online: state.storage.online,
      connected: state.storage.connected,
      lastSeen: state.storage.lastSeen,
      computerId: state.storage.computerId,
      details: state.storage.details,
      updatedAt: state.storage.updatedAt,
    },
  });
}, 2_000);

app.get("/api/state", (request, response) => {
  const authorization = request.get("authorization") || "";
  const token = authorization.startsWith("Bearer ") ? authorization.slice(7) : "";
  if (!tokenMatches(token)) return response.status(401).json({ error: "Unauthorized" });
  return response.json(publicState());
});
app.get("/health", (_request, response) => response.json({ ok: true }));

if (existsSync(join(distDirectory, "index.html"))) {
  app.use(express.static(distDirectory));
  app.get("*", (_request, response) => response.sendFile(join(distDirectory, "index.html")));
} else {
  app.get("/", (_request, response) => {
    response.type("text").send("Dashboard is not built. Run: npm run build");
  });
}

server.listen(PORT, HOST, () => {
  console.log(`Listening on all interfaces: ${HOST}:${PORT}`);
  console.log(`Kenzu CC server: http://localhost:${PORT}`);
  console.log(`ComputerCraft WebSocket: ws://<YOUR-PUBLIC-IP>:${PORT}/ws`);
});
