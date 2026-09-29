import express from "express";
import { createHmac, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { WebSocket, WebSocketServer } from "ws";

const PORT = Number(process.env.PORT || 3000);
const HOST = process.env.HOST || "0.0.0.0";
const AUTH_TOKEN = process.env.CC_AUTH_TOKEN || "";
const TRANSLATE_API_URL = process.env.TRANSLATE_API_URL || "";
const OFFLINE_AFTER_MS = 20_000;
const CONSOLE_HISTORY_LIMIT = 200;
const HISTORY_LIMIT = 180;
const INVITE_LIFETIME_MS = 15 * 60 * 1000;
const BROWSER_SESSION_LIFETIME_MS = 7 * 24 * 60 * 60 * 1000;
const rootDirectory = dirname(fileURLToPath(import.meta.url));
const distDirectory = join(rootDirectory, "dist");
const plansFile = process.env.PLANS_FILE || join(rootDirectory, "plans.json");

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
  response.set("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS");
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
  plans: [],
  planSequence: 1,
};

const clients = new Set();
const roleClients = new Map([
  ["gateway", new Set()],
  ["reactor", new Set()],
  ["storage_node", new Set()],
  ["turbine", new Set()],
  ["terminal", new Set()],
  ["plans", new Set()],
]);
const GATEWAY_SERVICES = new Set(["reactor", "storage_node", "turbine", "terminal", "plans"]);
const storageSnapshots = new WeakMap();
const turbineUnits = new Map();
const dashboardHistory = [];
const pendingConsole = new Map();
const inviteCodes = new Map();
let pendingSafety = null;

function masterTokenMatches(candidate) {
  if (typeof candidate !== "string") return false;
  const supplied = Buffer.from(candidate);
  const expected = Buffer.from(AUTH_TOKEN);
  return supplied.length === expected.length && timingSafeEqual(supplied, expected);
}

function tokenMatches(candidate) {
  if (masterTokenMatches(candidate)) return true;
  if (typeof candidate !== "string") return false;
  const [prefix, expiresText, nonce, signature] = candidate.split(".");
  const expiresAt = Number(expiresText);
  if (prefix !== "session" || !Number.isFinite(expiresAt) || expiresAt <= Date.now()
    || !nonce || !signature) return false;
  const expected = createHmac("sha256", AUTH_TOKEN)
    .update(`${expiresText}.${nonce}`)
    .digest("base64url");
  const suppliedBuffer = Buffer.from(signature);
  const expectedBuffer = Buffer.from(expected);
  return suppliedBuffer.length === expectedBuffer.length
    && timingSafeEqual(suppliedBuffer, expectedBuffer);
}

function createBrowserSession(expiresAt) {
  const expiresText = String(expiresAt);
  const nonce = randomBytes(18).toString("base64url");
  const signature = createHmac("sha256", AUTH_TOKEN)
    .update(`${expiresText}.${nonce}`)
    .digest("base64url");
  return `session.${expiresText}.${nonce}.${signature}`;
}

function send(socket, payload) {
  if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(payload));
}

function loadPlans() {
  if (!existsSync(plansFile)) return;
  try {
    const parsed = JSON.parse(readFileSync(plansFile, "utf8"));
    const storedPlans = Array.isArray(parsed) ? parsed : parsed?.plans;
    if (Array.isArray(storedPlans)) {
      state.plans = storedPlans.slice(0, 100);
      const used = new Set();
      let nextNumber = 1;
      let changed = false;
      for (const plan of state.plans) {
        let number = Number(plan.number);
        if (!Number.isInteger(number) || number < 1 || used.has(number)) {
          while (used.has(nextNumber)) nextNumber += 1;
          number = nextNumber;
          plan.number = number;
          changed = true;
        }
        used.add(number);
        nextNumber = Math.max(nextNumber, number + 1);
      }
      state.planSequence = Math.max(nextNumber, Number(parsed?.nextNumber) || 1);
      if (changed) savePlans();
    }
  } catch (error) {
    console.error("Cannot read plans.json:", error);
  }
}

function savePlans() {
  const temporaryFile = `${plansFile}.tmp`;
  writeFileSync(temporaryFile, `${JSON.stringify({
    nextNumber: state.planSequence,
    plans: state.plans,
  }, null, 2)}\n`, "utf8");
  renameSync(temporaryFile, plansFile);
}

async function translatePlan(text) {
  if (!/[А-Яа-яЁё]/.test(text)) return text;
  const endpoint = TRANSLATE_API_URL
    ? TRANSLATE_API_URL.replace("{text}", encodeURIComponent(text))
    : "https://translate.googleapis.com/translate_a/single"
      + `?client=gtx&sl=ru&tl=en&dt=t&q=${encodeURIComponent(text)}`;
  const response = await fetch(endpoint, { signal: AbortSignal.timeout(8_000) });
  if (!response.ok) throw new Error(`Translation HTTP ${response.status}`);
  const payload = await response.json();
  const translated = typeof payload?.translatedText === "string"
    ? payload.translatedText.trim()
    : Array.isArray(payload?.[0])
    ? payload[0].map((part) => String(part?.[0] || "")).join("").trim()
    : "";
  if (!translated) throw new Error("Translator returned an empty result");
  return translated;
}

function plansPayload() {
  return {
    type: "plans_update",
    plans: state.plans.map((plan) => ({
      id: plan.id,
      number: plan.number,
      text: String(plan.englishText || "Translation pending")
        .normalize("NFKD")
        .replace(/[‘’]/g, "'")
        .replace(/[“”]/g, "\"")
        .replace(/[–—]/g, "-")
        .replace(/[^\x20-\x7E]/g, ""),
      done: plan.done === true,
      translationPending: plan.translationPending === true,
    })),
    updatedAt: Date.now(),
  };
}

function nextPlanNumber() {
  const number = state.planSequence;
  state.planSequence += 1;
  return number;
}

function findPlan(identifier) {
  const value = String(identifier || "").trim();
  return state.plans.find((plan) => plan.id === value || String(plan.number) === value);
}

async function createPlan(russianText) {
  const plan = {
    id: randomUUID(),
    number: nextPlanNumber(),
    russianText,
    englishText: "Translation pending",
    translationPending: true,
    done: false,
    createdAt: Date.now(),
  };
  try {
    plan.englishText = await translatePlan(russianText);
    plan.translationPending = false;
  } catch (error) {
    console.error("Plan translation failed:", error);
  }
  state.plans.push(plan);
  savePlans();
  publishPlans();
  return plan;
}

function setPlanCompleted(identifier, done) {
  const plan = findPlan(identifier);
  if (!plan) return null;
  plan.done = done;
  plan.completedAt = done ? Date.now() : null;
  savePlans();
  publishPlans();
  return plan;
}

function removePlan(identifier) {
  const plan = findPlan(identifier);
  if (!plan) return null;
  state.plans = state.plans.filter((candidate) => candidate !== plan);
  savePlans();
  publishPlans();
  return plan;
}

function publishPlans() {
  const payload = plansPayload();
  sendToRole("plans", payload);
  broadcastToBrowsers({ type: "plans_update", plans: state.plans, updatedAt: Date.now() });
}

async function retryPendingTranslations() {
  const pending = state.plans.filter((plan) => plan.translationPending === true);
  let changed = false;
  for (const plan of pending) {
    try {
      plan.englishText = await translatePlan(plan.russianText);
      plan.translationPending = false;
      changed = true;
    } catch {}
  }
  if (changed) {
    savePlans();
    publishPlans();
  }
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
    plans: state.plans,
  };
}

loadPlans();

function requestToken(request) {
  const authorization = request.get("authorization") || "";
  return authorization.startsWith("Bearer ") ? authorization.slice(7) : "";
}

function requireToken(request, response) {
  if (tokenMatches(requestToken(request))) return true;
  response.status(401).json({ error: "Unauthorized" });
  return false;
}

function requireMasterToken(request, response) {
  if (masterTokenMatches(requestToken(request))) return true;
  response.status(403).json({ error: "Only the panel owner can create invitations" });
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
  if (pendingSafety && pendingSafety.expires <= Date.now()) pendingSafety = null;
  const safety = pendingSafety
    ? { ...(reactor.safety || {}), ...pendingSafety.values }
    : (reactor.safety || {});

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
    plans: state.plans,
    history: dashboardHistory,
  };
}

function dispatchReactorCommand(command) {
  const error = validateCommand(command);
  if (error) return { ok: false, status: 400, error };
  const requestId = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  if (sendToRole("reactor", { type: "command", requestId, ...command }) === 0) {
    return { ok: false, status: 503, error: "Reactor computer is offline" };
  }
  return { ok: true, status: 202, requestId };
}

function safetyMatches(actual, expected) {
  if (!actual || !expected) return false;
  return actual.energyEnabled === expected.energyEnabled
    && actual.steamEnabled === expected.steamEnabled
    && actual.waterEnabled === expected.waterEnabled
    && actual.fuelEnabled === expected.fuelEnabled
    && numeric(actual.energyStartPercent) === expected.energyStartPercent
    && numeric(actual.energyStopPercent) === expected.energyStopPercent
    && numeric(actual.steamStopPercent) === expected.steamStopPercent
    && numeric(actual.waterStopPercent) === expected.waterStopPercent
    && numeric(actual.fuelStopPercent) === expected.fuelStopPercent;
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
    const energyStart = Number(message.energyStartPercent);
    const energyStop = Number(message.energyStopPercent);
    const steam = Number(message.steamStopPercent);
    const water = Number(message.waterStopPercent);
    const fuel = Number(message.fuelStopPercent);
    if (!Number.isInteger(energyStart) || !Number.isInteger(energyStop)
      || energyStart < 0 || energyStop > 100 || energyStart >= energyStop
      || !Number.isInteger(steam) || steam < 1 || steam > 100
      || !Number.isInteger(water) || water < 0 || water > 99
      || !Number.isInteger(fuel) || fuel < 0 || fuel > 99) {
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

function packChatLines(lines, maximumLength = 220, maximumMessages = 8) {
  const messages = [];
  let current = "";
  for (const line of lines) {
    const candidate = current ? `${current} | ${line}` : line;
    if (candidate.length <= maximumLength) {
      current = candidate;
    } else {
      if (current) messages.push(current);
      current = line.slice(0, maximumLength);
      if (messages.length >= maximumMessages) break;
    }
  }
  if (current && messages.length < maximumMessages) messages.push(current);
  if (messages.length >= maximumMessages && lines.length > maximumMessages) {
    messages[maximumMessages - 1] = `${messages[maximumMessages - 1]} | Остальные планы смотрите на сайте`;
  }
  return messages;
}

// Chat Box strings normally pass through ComputerCraft's terminal character
// encoding. Keep the wire payload ASCII-only and let Minecraft's JSON parser
// decode Unicode escapes instead. This works even on AP versions where the
// utf8Support argument is missing or unreliable.
function formattedChatMessage(text) {
  return JSON.stringify({ text: String(text) }).replace(
    /[^\x20-\x7E]/g,
    (character) => `\\u${character.charCodeAt(0).toString(16).padStart(4, "0")}`,
  );
}

function decodeCodepoints(values) {
  if (!Array.isArray(values) || values.length === 0 || values.length > 240) return "";
  const codepoints = values.map(Number);
  if (codepoints.some((value) => !Number.isInteger(value)
    || value < 0 || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff))) return "";
  return String.fromCodePoint(...codepoints);
}

async function handlePlansCommand(message) {
  const action = String(message.action || "help").toLowerCase();
  if (action === "help") {
    return [
      ".plan add <название> — добавить",
      ".plan list — показать список",
      ".plan complete <id> — выполнить",
      ".plan delete <id> — удалить",
    ];
  }
  if (action === "list") {
    if (state.plans.length === 0) return ["Список планов пуст"];
    const ordered = [...state.plans].sort((left, right) => Number(left.number) - Number(right.number));
    return packChatLines(ordered.map((plan) => (
      `#${plan.number} ${plan.done ? "[готово]" : "[в работе]"} ${plan.russianText}`
    )));
  }
  if (action === "add") {
    const text = (message.textCodepoints !== undefined
      ? decodeCodepoints(message.textCodepoints)
      : String(message.text || "")).trim();
    if (!text || text.length > 240) return ["Название должно содержать от 1 до 240 символов"];
    if (state.plans.length >= 100) return ["Список ограничен 100 задачами"];
    const plan = await createPlan(text);
    return [`Добавлен план #${plan.number}: ${plan.russianText}`];
  }
  if (action === "complete") {
    const plan = setPlanCompleted(message.id, true);
    return [plan
      ? `План #${plan.number} отмечен выполненным: ${plan.russianText}`
      : `План #${String(message.id || "?")} не найден`];
  }
  if (action === "delete") {
    const plan = removePlan(message.id);
    return [plan
      ? `План #${plan.number} удалён: ${plan.russianText}`
      : `План #${String(message.id || "?")} не найден`];
  }
  return ["Неизвестная команда. Используйте .plan help"];
}

websocketServer.on("connection", (socket) => {
  socket.role = "unknown";
  socket.authenticated = false;
  socket.services = new Set();
  clients.add(socket);

  socket.on("message", async (rawMessage) => {
    let message;
    try {
      message = JSON.parse(rawMessage.toString());
    } catch {
      send(socket, { type: "error", message: "Invalid JSON" });
      return;
    }

    if (message.type === "hello") {
      const requestedRole = String(message.role || "unknown");
      const authenticated = requestedRole === "browser"
        ? tokenMatches(message.token)
        : masterTokenMatches(message.token);
      if (!authenticated) {
        send(socket, { type: "auth_error", message: "Invalid access token" });
        socket.close(1008, "Invalid access token");
        return;
      }

      if (socket.authenticated) roleClients.get(socket.role)?.delete(socket);
      socket.authenticated = true;
      socket.role = requestedRole;
      socket.computerId = message.computerId ?? null;
      socket.label = message.label ?? null;
      roleClients.get(socket.role)?.add(socket);
      touchComputer(socket);
      touchRoleState(socket);

      if (socket.role === "browser") send(socket, { type: "state", state: publicState() });
      else {
        if (socket.role === "plans") send(socket, plansPayload());
        broadcastComputers();
      }
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
      if (socket.services.has("plans")) send(socket, { ...plansPayload(), targetService: "plans" });
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

    if (message.type === "plans_command" && effectiveRole === "plans") {
      let messages;
      try {
        messages = await handlePlansCommand(message);
      } catch (error) {
        console.error("Chat plan command failed:", error);
        messages = ["Не удалось выполнить команду. Попробуйте ещё раз"];
      }
      send(socket, {
        type: "plans_result",
        requestId: message.requestId || null,
        username: String(message.username || ""),
        messages,
        formattedMessages: messages.map(formattedChatMessage),
        targetService: "plans",
      });
      return;
    }

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
      if (pendingSafety && safetyMatches(message.data?.safety, pendingSafety.values)) {
        pendingSafety = null;
      }
      broadcastToBrowsers({ type: "reactor_state", reactor: state.reactor });
      return;
    }

    if (message.type === "terminal_frame" && (effectiveRole === "terminal" || effectiveRole === "reactor")) {
      const sourceComputerId = message.computerId ?? socket.computerId;
      const key = String(sourceComputerId ?? "unknown");
      const previous = state.terminals[key];
      const sessionId = String(message.sessionId || "legacy");
      const sequence = Math.max(0, Number(message.sequence) || 0);
      if (sequence > 0 && previous?.sessionId === sessionId
        && sequence <= (previous.sequence || 0)) return;
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
        terminalRole: String(message.terminalRole || "computer"),
        sessionId,
        sequence,
        sentAt: Number(message.sentAt) || Date.now(),
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
        energyStartPercent: message.energyStartPercent,
        energyStopPercent: message.energyStopPercent,
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
      if (pendingSafety?.requestId === state.lastCommand.requestId && !state.lastCommand.ok) {
        pendingSafety = null;
      }
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
  for (const [code, expiresAt] of inviteCodes) {
    if (expiresAt <= now) inviteCodes.delete(code);
  }
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

setInterval(() => void retryPendingTranslations(), 60_000);

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
    const ranges = {
      energy: [1, 100],
      steam: [1, 100],
      water: [0, 99],
      fuel: [0, 99],
    };
    const [minimum, maximum] = ranges[key];
    const requestedThreshold = Number(value.threshold);
    if (!Number.isFinite(requestedThreshold)) {
      return response.status(400).json({ error: "Safety threshold must be a number" });
    }
    snapshot.safety[key] = {
      enabled: value.enabled === true,
      threshold: Math.round(Math.max(minimum, Math.min(maximum, requestedThreshold))),
    };
    const energyStopPercent = Math.round(snapshot.safety.energy.threshold);
    const configuredStart = numeric(state.reactor.data?.safety?.energyStartPercent, 80);
    result = dispatchReactorCommand({
      action: "set_safety",
      energyEnabled: snapshot.safety.energy.enabled,
      steamEnabled: snapshot.safety.steam.enabled,
      waterEnabled: snapshot.safety.water.enabled,
      fuelEnabled: snapshot.safety.fuel.enabled,
      energyStartPercent: Math.max(
        0,
        Math.min(energyStopPercent - 1, Math.round(configuredStart)),
      ),
      energyStopPercent,
      steamStopPercent: Math.round(snapshot.safety.steam.threshold),
      waterStopPercent: Math.round(snapshot.safety.water.threshold),
      fuelStopPercent: Math.round(snapshot.safety.fuel.threshold),
    });
    if (result.ok) {
      pendingSafety = {
        requestId: result.requestId,
        expires: Date.now() + 20_000,
        values: {
          energyEnabled: snapshot.safety.energy.enabled,
          steamEnabled: snapshot.safety.steam.enabled,
          waterEnabled: snapshot.safety.water.enabled,
          fuelEnabled: snapshot.safety.fuel.enabled,
          energyStartPercent: Math.max(
            0,
            Math.min(energyStopPercent - 1, Math.round(configuredStart)),
          ),
          energyStopPercent,
          steamStopPercent: Math.round(snapshot.safety.steam.threshold),
          waterStopPercent: Math.round(snapshot.safety.water.threshold),
          fuelStopPercent: Math.round(snapshot.safety.fuel.threshold),
        },
      };
    }
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
app.get("/plans", (request, response) => {
  if (!requireToken(request, response)) return;
  return response.json({ plans: state.plans });
});
app.post("/plans", async (request, response) => {
  if (!requireToken(request, response)) return;
  const russianText = String(request.body?.text || "").trim();
  if (!russianText || russianText.length > 240) {
    return response.status(400).json({ error: "План должен содержать от 1 до 240 символов" });
  }
  if (state.plans.length >= 100) {
    return response.status(409).json({ error: "Список ограничен 100 задачами" });
  }

  const plan = await createPlan(russianText);
  return response.status(201).json({ plan });
});
app.patch("/plans/:id", (request, response) => {
  if (!requireToken(request, response)) return;
  if (typeof request.body?.done !== "boolean") {
    return response.status(400).json({ error: "Поле done должно быть логическим" });
  }
  const plan = setPlanCompleted(request.params.id, request.body.done);
  if (!plan) return response.status(404).json({ error: "План не найден" });
  return response.json({ plan });
});
app.delete("/plans/:id", (request, response) => {
  if (!requireToken(request, response)) return;
  const plan = removePlan(request.params.id);
  if (!plan) return response.status(404).json({ error: "План не найден" });
  return response.json({ plan });
});
app.get("/health", (_request, response) => response.json({ ok: true }));
app.post("/invite", (request, response) => {
  if (!requireMasterToken(request, response)) return;
  const code = randomBytes(24).toString("base64url");
  const expiresAt = Date.now() + INVITE_LIFETIME_MS;
  inviteCodes.set(code, expiresAt);
  return response.status(201).json({ code, expiresAt });
});
app.post("/invite/redeem", (request, response) => {
  const code = String(request.body?.code || "");
  const inviteExpiresAt = inviteCodes.get(code);
  if (!inviteExpiresAt || inviteExpiresAt <= Date.now()) {
    inviteCodes.delete(code);
    return response.status(410).json({ error: "Invitation is invalid or expired" });
  }

  inviteCodes.delete(code);
  const expiresAt = Date.now() + BROWSER_SESSION_LIFETIME_MS;
  const sessionToken = createBrowserSession(expiresAt);
  return response.json({ token: sessionToken, expiresAt });
});

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
