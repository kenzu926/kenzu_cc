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
const HISTORY_LIMIT = 180;
const rootDirectory = dirname(fileURLToPath(import.meta.url));
const distDirectory = join(rootDirectory, "dist");

if (AUTH_TOKEN.length < 24) {
  console.error("CC_AUTH_TOKEN must contain at least 24 characters.");
  process.exit(1);
}

const app = express();
const server = createServer(app);
const websocketServer = new WebSocketServer({ server, path: "/ws" });

app.use(express.json({ limit: "64kb" }));
app.use((request, response, next) => {
  response.set("Access-Control-Allow-Origin", request.get("origin") || "*");
  response.set("Access-Control-Allow-Headers", "Authorization, Content-Type");
  response.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  if (request.method === "OPTIONS") return response.sendStatus(204);
  return next();
});

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
    metrics: { total: 0, used: 0, available: 0, cells: [] },
    updatedAt: null,
  },
  computers: {},
  terminals: {},
  consoleHistory: [],
  lastCommand: null,
};

const clients = new Set();
const roleClients = new Map([
  ["gateway", new Set()],
  ["reactor", new Set()],
  ["storage_node", new Set()],
  ["turbine", new Set()],
  ["terminal", new Set()],
]);
const GATEWAY_SERVICES = new Set(["reactor", "storage_node", "turbine", "terminal"]);
const storageSnapshots = new WeakMap();
const turbineUnits = new Map();
const dashboardHistory = [];
const pendingConsole = new Map();

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

function requestToken(request) {
  const authorization = request.get("authorization") || "";
  return authorization.startsWith("Bearer ") ? authorization.slice(7) : "";
}

function requireToken(request, response) {
  if (tokenMatches(requestToken(request))) return true;
  response.status(401).json({ error: "Unauthorized" });
  return false;
}

function numeric(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function dashboardSnapshot() {
  const reactor = state.reactor.data || {};
  const matrix = state.matrix.data || {};
  const onlineTurbines = state.turbines.filter((entry) => entry.online && entry.data);
  const turbineSum = (field) => onlineTurbines.reduce(
    (total, entry) => total + numeric(entry.data?.[field]),
    0,
  );
  const storageMetrics = state.storage.metrics || {};
  const cells = Array.isArray(storageMetrics.cells) ? storageMetrics.cells : [];
  const safety = reactor.safety || {};

  return {
    online: {
      reactor: state.reactor.online,
      matrix: state.matrix.online,
      turbines: onlineTurbines.length,
      storage: state.storage.online && state.storage.connected,
    },
    reactor: {
      active: Boolean(reactor.running),
      water: numeric(reactor.coolantPercent),
      fuel: numeric(reactor.fuelPercent),
      heated: numeric(reactor.heatedCoolantPercent),
      waste: numeric(reactor.wastePercent),
      heating: numeric(reactor.heatingRate),
      temperature: numeric(reactor.temperature),
      damage: numeric(reactor.damage),
      burnRate: numeric(reactor.burnRate),
      actualBurnRate: numeric(reactor.actualBurnRate),
      maxBurnRate: Math.max(0.1, numeric(reactor.maxBurnRate, 100)),
    },
    matrix: {
      energy: numeric(matrix.storedEnergy) / 1e12,
      capacity: Math.max(0.000001, numeric(matrix.capacity, 1) / 1e12),
      input: numeric(matrix.input),
      output: numeric(matrix.output),
    },
    turbines: {
      generation: turbineSum("production") / 1e6,
      flow: turbineSum("flowRate"),
      maxFlow: turbineSum("maxFlowRate"),
      steam: turbineSum("steam"),
      steamCapacity: Math.max(1, turbineSum("steamCapacity")),
      count: onlineTurbines.length,
      units: onlineTurbines.map((entry, index) => ({
        name: String(entry.data?.peripheral || `Турбина ${index + 1}`),
        generation: numeric(entry.data?.production) / 1e6,
        flow: numeric(entry.data?.flowRate),
        maxFlow: numeric(entry.data?.maxFlowRate),
        steam: numeric(entry.data?.steam),
        steamCapacity: Math.max(1, numeric(entry.data?.steamCapacity, 1)),
      })),
    },
    storage: {
      used: numeric(storageMetrics.used),
      capacity: Math.max(1, numeric(storageMetrics.total, 1)),
      cells: cells.map((cell, index) => ({
        name: String(cell.item || cell.name || `Ячейка ${index + 1}`),
        used: numeric(cell.usedBytes ?? cell.used),
        capacity: Math.max(1, numeric(cell.totalBytes ?? cell.capacity, 1)),
        usedKnown: cell.usedKnown === true
          || cell.usedBytes !== undefined
          || cell.used !== undefined,
      })),
      items: state.storage.items.map((item) => ({
        name: String(item.displayName || item.name || "unknown"),
        id: String(item.name || item.fingerprint || "unknown"),
        count: numeric(item.count ?? item.amount),
      })),
    },
    safety: {
      energy: {
        enabled: safety.energyEnabled !== false,
        threshold: numeric(safety.energyStopPercent, reactor.stopPercent || 98),
      },
      steam: {
        enabled: safety.steamEnabled !== false,
        threshold: numeric(safety.steamStopPercent, 90),
      },
      water: {
        enabled: safety.waterEnabled !== false,
        threshold: numeric(safety.waterStopPercent, 10),
      },
      fuel: {
        enabled: safety.fuelEnabled === true,
        threshold: numeric(safety.fuelStopPercent, 5),
      },
    },
    terminals: state.terminals,
    history: dashboardHistory,
  };
}

function dispatchReactorCommand(command) {
  const error = validateCommand(command);
  if (error) return { ok: false, status: 400, error };
  if (sendToRole("reactor", { type: "command", requestId: `${Date.now()}`, ...command }) === 0) {
    return { ok: false, status: 503, error: "Reactor computer is offline" };
  }
  return { ok: true, status: 202 };
}

function computerKey(role, computerId) {
  return `${role}:${computerId ?? "unknown"}`;
}

function touchComputer(socket, role = socket.role) {
  if (!role || role === "browser" || role === "unknown" || role === "gateway") return;
  const key = computerKey(role, socket.computerId);
  state.computers[key] = {
    role,
    computerId: socket.computerId,
    label: socket.label || null,
    online: true,
    lastSeen: Date.now(),
  };
}

function touchRoleState(socket, role = socket.role) {
  const now = Date.now();
  if (role === "reactor") {
    state.matrix.online = true;
    state.matrix.lastSeen = now;
    state.matrix.computerId = socket.computerId;
    state.reactor.online = true;
    state.reactor.lastSeen = now;
    state.reactor.computerId = socket.computerId;
  } else if (role === "storage_node") {
    state.storage.online = true;
    state.storage.lastSeen = now;
    state.storage.computerId = socket.computerId;
  }
}

function broadcastComputers() {
  broadcastToBrowsers({ type: "computers_state", computers: state.computers });
}

function validateCommand(message) {
  const allowed = new Set(["reactor_start", "reactor_scram", "set_thresholds", "set_burn_rate", "set_safety"]);
  if (!allowed.has(message.action)) return "Unknown command";
  if (message.action === "set_burn_rate") {
    const burnRate = Number(message.burnRate);
    if (!Number.isFinite(burnRate) || burnRate < 0 || burnRate > 1_000_000) {
      return "Burn rate must be a positive number";
    }
    return null;
  }
  if (message.action === "set_safety") {
    const steam = Number(message.steamStopPercent);
    const water = Number(message.waterStopPercent);
    const fuel = Number(message.fuelStopPercent);
    if (!Number.isFinite(steam) || steam < 1 || steam > 100
      || !Number.isFinite(water) || water < 0 || water > 99
      || !Number.isFinite(fuel) || fuel < 0 || fuel > 99) {
      return "Safety thresholds are invalid";
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
  for (const socket of roleClients.get("gateway") || []) {
    if (socket.readyState === WebSocket.OPEN && socket.services?.has(role)) {
      send(socket, { ...payload, targetService: role });
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
  for (const gateway of roleClients.get("gateway") || []) {
    if (String(gateway.computerId) === target && gateway.services?.has("terminal")) {
      send(gateway, { ...payload, targetService: "terminal" });
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
        send(socket, socket.role === "gateway"
          ? { ...payload, targetService: "*" }
          : payload);
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
  socket.services = new Set();
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
      touchRoleState(socket);

      if (socket.role === "browser") send(socket, { type: "state", state: publicState() });
      else broadcastComputers();
      return;
    }

    if (!socket.authenticated) {
      socket.close(1008, "Authentication required");
      return;
    }

    if (message.type === "ping") {
      send(socket, { type: "pong", sentAt: message.sentAt ?? null, serverAt: Date.now() });
      return;
    }

    if (message.type === "service_announce" && socket.role === "gateway") {
      const nextServices = new Set(
        (Array.isArray(message.services) ? message.services : [])
          .map(String)
          .filter((service) => GATEWAY_SERVICES.has(service)),
      );
      for (const oldService of socket.services) {
        if (!nextServices.has(oldService)) {
          const oldComputer = state.computers[computerKey(oldService, socket.computerId)];
          if (oldComputer) oldComputer.online = false;
        }
      }
      socket.services = nextServices;
      for (const service of socket.services) touchComputer(socket, service);
      broadcastComputers();
      return;
    }

    const effectiveRole = socket.role === "gateway" ? String(message.service || "") : socket.role;
    if (socket.role === "gateway" && !GATEWAY_SERVICES.has(effectiveRole)) {
      send(socket, { type: "error", message: "Invalid or missing gateway service" });
      return;
    }
    if (socket.role === "gateway" && !socket.services.has(effectiveRole)) {
      socket.services.add(effectiveRole);
      broadcastComputers();
    }
    touchComputer(socket, effectiveRole);
    touchRoleState(socket, effectiveRole);

    if (message.type === "matrix_status" && effectiveRole === "reactor") {
      state.matrix = {
        online: true,
        lastSeen: Date.now(),
        computerId: socket.computerId,
        data: message.data,
      };
      broadcastToBrowsers({ type: "matrix_state", matrix: state.matrix });
      return;
    }

    if (message.type === "reactor_status" && effectiveRole === "reactor") {
      state.reactor = {
        online: true,
        lastSeen: Date.now(),
        computerId: socket.computerId,
        data: message.data,
      };
      broadcastToBrowsers({ type: "reactor_state", reactor: state.reactor });
      return;
    }

    if (message.type === "terminal_frame" && (effectiveRole === "terminal" || effectiveRole === "reactor")) {
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

    const isTurbineSource = effectiveRole === "turbine" || effectiveRole === "terminal";
    if (message.type === "turbines_status" && isTurbineSource) {
      const prefix = `turbine:${socket.computerId}:`;
      for (const key of turbineUnits.keys()) {
        if (key.startsWith(prefix)) turbineUnits.delete(key);
      }

      const turbines = Array.isArray(message.turbines) ? message.turbines.slice(0, 128) : [];
      turbines.forEach((data, index) => {
        if (!data || typeof data !== "object") return;
        const peripheral = String(data.peripheral || `turbine_${index}`).slice(0, 100);
        turbineUnits.set(`${prefix}${peripheral}`, {
          online: true,
          lastSeen: Date.now(),
          computerId: socket.computerId,
          sourceRole: effectiveRole,
          data: { ...data, peripheral },
        });
      });
      state.turbines = [...turbineUnits.values()];
      broadcastToBrowsers({ type: "turbines_state", turbines: state.turbines });
      return;
    }

    // Compatibility with computers which have not received the new updater yet.
    if (message.type === "turbine_status" && effectiveRole === "turbine") {
      const peripheral = String(message.data?.peripheral || "turbine").slice(0, 100);
      const key = `${computerKey(socket.role, socket.computerId)}:${peripheral}`;
      turbineUnits.set(key, {
        online: true,
        lastSeen: Date.now(),
        computerId: socket.computerId,
        sourceRole: effectiveRole,
        data: { ...message.data, peripheral },
      });
      state.turbines = [...turbineUnits.values()];
      broadcastToBrowsers({ type: "turbines_state", turbines: state.turbines });
      return;
    }

    const isStorageSource = effectiveRole === "storage_node" || effectiveRole === "reactor";
    if (message.type === "storage_status" && isStorageSource) {
      state.storage.online = true;
      state.storage.lastSeen = Date.now();
      state.storage.computerId = message.computerId ?? socket.computerId;
      state.storage.connected = message.connected === true;
      state.storage.details = message.details || "";
      if (message.metrics && typeof message.metrics === "object") {
        state.storage.metrics = message.metrics;
      }
      broadcastToBrowsers({
        type: "storage_status",
        storage: {
          online: state.storage.online,
          lastSeen: state.storage.lastSeen,
          computerId: state.storage.computerId,
          connected: state.storage.connected,
          details: state.storage.details,
          metrics: state.storage.metrics,
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
        energyEnabled: message.energyEnabled,
        steamEnabled: message.steamEnabled,
        waterEnabled: message.waterEnabled,
        fuelEnabled: message.fuelEnabled,
        steamStopPercent: message.steamStopPercent,
        waterStopPercent: message.waterStopPercent,
        fuelStopPercent: message.fuelStopPercent,
      };
      if (sendToRole("reactor", command) === 0) {
        send(socket, { type: "command_result", ok: false, message: "Reactor computer is offline" });
      }
      return;
    }

    if (message.type === "command_result" && effectiveRole === "reactor") {
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

    if (message.type === "console_output" && effectiveRole !== "browser") {
      const output = {
        type: "console_output",
        requestId: message.requestId || null,
        target: message.target || effectiveRole,
        computerId: message.computerId ?? socket.computerId,
        ok: message.ok === true,
        output: String(message.output || ""),
        at: Date.now(),
      };
      const pending = pendingConsole.get(String(output.requestId));
      if (pending) {
        pendingConsole.delete(String(output.requestId));
        pending(output);
      }
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
      const services = socket.role === "gateway" ? [...socket.services] : [socket.role];
      let turbinesChanged = false;

      for (const service of services) {
        const directReplacement = [...(roleClients.get(service) || [])]
          .some((candidate) => candidate.computerId === socket.computerId);
        const gatewayReplacement = [...(roleClients.get("gateway") || [])]
          .some((candidate) => candidate.computerId === socket.computerId
            && candidate.services?.has(service));
        const replacement = directReplacement || gatewayReplacement;
        if (replacement) continue;

        const key = computerKey(service, socket.computerId);
        if (state.computers[key]) state.computers[key].online = false;
        if (service === "reactor") {
          state.matrix.online = false;
          state.reactor.online = false;
        }
        if (service === "storage_node") state.storage.online = false;
        if (service === "turbine" || service === "terminal") {
          for (const unit of turbineUnits.values()) {
            if (unit.computerId === socket.computerId && unit.sourceRole === service) {
              unit.online = false;
              turbinesChanged = true;
            }
          }
        }
        if (service === "terminal" && state.terminals[String(socket.computerId)]) {
          state.terminals[String(socket.computerId)].online = false;
          broadcastToBrowsers({
            type: "terminal_frame",
            terminal: state.terminals[String(socket.computerId)],
          });
        }
      }

      if (turbinesChanged) {
        state.turbines = [...turbineUnits.values()];
        broadcastToBrowsers({ type: "turbines_state", turbines: state.turbines });
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
  const sample = dashboardSnapshot();
  dashboardHistory.push({
    time: new Date().toLocaleTimeString("ru-RU", {
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    }),
    temperature: sample.reactor.temperature,
    generation: sample.turbines.generation,
  });
  if (dashboardHistory.length > HISTORY_LIMIT) dashboardHistory.shift();
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
      metrics: state.storage.metrics,
    },
  });
}, 2_000);

app.get("/api/state", (request, response) => {
  if (!requireToken(request, response)) return;
  return response.json(publicState());
});
app.get("/snapshot", (request, response) => {
  if (!requireToken(request, response)) return;
  return response.json(dashboardSnapshot());
});
app.post("/command", (request, response) => {
  if (!requireToken(request, response)) return;
  const type = String(request.body?.type || "");
  const value = request.body?.value;
  let result;

  if (type === "reactor.activate") {
    result = dispatchReactorCommand({ action: "reactor_start" });
  } else if (type === "reactor.scram") {
    result = dispatchReactorCommand({ action: "reactor_scram" });
  } else if (type === "reactor.setBurnRate") {
    result = dispatchReactorCommand({ action: "set_burn_rate", burnRate: Number(value) });
  } else if (type === "safety.set" && value && typeof value === "object") {
    const snapshot = dashboardSnapshot();
    const key = String(value.key || "");
    if (!Object.hasOwn(snapshot.safety, key)) {
      return response.status(400).json({ error: "Unknown safety channel" });
    }
    snapshot.safety[key] = {
      enabled: value.enabled === true,
      threshold: Math.max(0, Math.min(100, Number(value.threshold))),
    };
    const safetyResult = dispatchReactorCommand({
      action: "set_safety",
      energyEnabled: snapshot.safety.energy.enabled,
      steamEnabled: snapshot.safety.steam.enabled,
      waterEnabled: snapshot.safety.water.enabled,
      fuelEnabled: snapshot.safety.fuel.enabled,
      steamStopPercent: snapshot.safety.steam.threshold,
      waterStopPercent: snapshot.safety.water.threshold,
      fuelStopPercent: snapshot.safety.fuel.threshold,
    });
    if (!safetyResult.ok) result = safetyResult;
    else if (key === "energy") {
      const configuredStart = numeric(state.reactor.data?.safety?.energyStartPercent, 80);
      const stopPercent = Math.max(1, Math.round(snapshot.safety.energy.threshold));
      result = dispatchReactorCommand({
        action: "set_thresholds",
        startPercent: Math.min(stopPercent - 1, Math.round(configuredStart)),
        stopPercent,
      });
    } else result = safetyResult;
  } else {
    result = { ok: false, status: 400, error: "Unknown command" };
  }

  return response.status(result.status).json(
    result.ok ? { ok: true } : { ok: false, error: result.error },
  );
});
app.post("/terminal", async (request, response) => {
  if (!requireToken(request, response)) return;
  const input = String(request.body?.input || "").trim();
  if (!input || input.length > 256) {
    return response.status(400).json({ error: "Invalid command" });
  }
  const target = String(request.body?.target || "reactor");
  if (target !== "reactor" && target !== "storage_node") {
    return response.status(400).json({ error: "Invalid terminal target" });
  }
  const requestId = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const payload = {
    type: "console_command",
    requestId,
    target,
    command: input,
  };
  let recipients = sendToRole(target, payload);
  if (recipients === 0 && target === "storage_node") {
    recipients = sendToRole("reactor", payload);
  }
  if (recipients === 0) {
    return response.status(503).json({ output: `${target} computer is offline` });
  }
  const output = await new Promise((resolve) => {
    const timeout = setTimeout(() => {
      pendingConsole.delete(requestId);
      resolve({ output: "Команда отправлена, ответ не получен" });
    }, 3_000);
    pendingConsole.set(requestId, (message) => {
      clearTimeout(timeout);
      resolve(message);
    });
  });
  return response.json(output);
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
