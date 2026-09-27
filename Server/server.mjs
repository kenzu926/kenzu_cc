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
const OFFLINE_AFTER_MS = 10_000;
const rootDirectory = dirname(fileURLToPath(import.meta.url));
const distDirectory = join(rootDirectory, "dist");

const app = express();
const server = createServer(app);
const websocketServer = new WebSocketServer({ server, path: "/ws" });

const state = {
  reactor: {
    online: false,
    lastSeen: null,
    computerId: null,
    data: null,
  },
  storage: {
    online: false,
    lastSeen: null,
    computerId: null,
    connected: false,
    details: "Waiting for storage node",
    items: [],
    updatedAt: null,
  },
  lastCommand: null,
};

const clients = new Set();
const reactorClients = new Set();
const storageClients = new Set();
const storageSnapshots = new WeakMap();

if (AUTH_TOKEN.length < 24) {
  console.error("CC_AUTH_TOKEN must contain at least 24 characters.");
  process.exit(1);
}

function tokenMatches(candidate) {
  if (typeof candidate !== "string") return false;
  const supplied = Buffer.from(candidate);
  const expected = Buffer.from(AUTH_TOKEN);
  return supplied.length === expected.length && timingSafeEqual(supplied, expected);
}

function send(socket, payload) {
  if (socket.readyState !== WebSocket.OPEN) return;
  socket.send(JSON.stringify(payload));
}

function broadcastToBrowsers(payload) {
  for (const client of clients) {
    if (client.role === "browser") send(client, payload);
  }
}

function publicState() {
  return {
    reactor: state.reactor,
    storage: state.storage,
    lastCommand: state.lastCommand,
  };
}

function validateCommand(message) {
  const allowed = new Set(["reactor_start", "reactor_scram", "set_thresholds"]);
  if (!allowed.has(message.action)) return "Unknown command";

  if (message.action === "set_thresholds") {
    const start = Number(message.startPercent);
    const stop = Number(message.stopPercent);
    if (!Number.isInteger(start) || !Number.isInteger(stop)) {
      return "Thresholds must be whole numbers";
    }
    if (start < 0 || stop > 100 || start >= stop) {
      return "Thresholds must satisfy 0 <= start < stop <= 100";
    }
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

      socket.authenticated = true;
      socket.role = message.role;
      socket.computerId = message.computerId ?? null;

      if (socket.role === "reactor") reactorClients.add(socket);
      if (socket.role === "storage_node") storageClients.add(socket);
      if (socket.role === "browser") send(socket, { type: "state", state: publicState() });
      return;
    }

    if (!socket.authenticated) {
      socket.close(1008, "Authentication required");
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

    if (message.type === "storage_status" && socket.role === "storage_node") {
      state.storage.online = true;
      state.storage.lastSeen = Date.now();
      state.storage.computerId = socket.computerId;
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

    if (message.type === "storage_begin" && socket.role === "storage_node") {
      storageSnapshots.set(socket, {
        id: message.snapshotId,
        items: [],
      });
      return;
    }

    if (message.type === "storage_chunk" && socket.role === "storage_node") {
      const snapshot = storageSnapshots.get(socket);
      if (snapshot?.id === message.snapshotId && Array.isArray(message.items)) {
        snapshot.items.push(...message.items);
      }
      return;
    }

    if (message.type === "storage_end" && socket.role === "storage_node") {
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
      };

      let recipients = 0;
      for (const reactor of reactorClients) {
        if (reactor.readyState === WebSocket.OPEN) {
          send(reactor, command);
          recipients += 1;
        }
      }

      if (recipients === 0) {
        send(socket, {
          type: "command_result",
          ok: false,
          message: "Reactor computer is offline",
        });
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
    }
  });

  socket.on("close", () => {
    clients.delete(socket);
    reactorClients.delete(socket);
    storageClients.delete(socket);
    storageSnapshots.delete(socket);

    if (socket.role === "reactor" && reactorClients.size === 0) {
      state.reactor.online = false;
      broadcastToBrowsers({ type: "reactor_state", reactor: state.reactor });
    }
    if (socket.role === "storage_node" && storageClients.size === 0) {
      state.storage.online = false;
      broadcastToBrowsers({
        type: "storage_status",
        storage: { online: false, connected: state.storage.connected },
      });
    }
  });
});

setInterval(() => {
  const now = Date.now();
  if (state.reactor.online && now - state.reactor.lastSeen > OFFLINE_AFTER_MS) {
    state.reactor.online = false;
    broadcastToBrowsers({ type: "reactor_state", reactor: state.reactor });
  }
  if (state.storage.online && now - state.storage.lastSeen > OFFLINE_AFTER_MS) {
    state.storage.online = false;
    broadcastToBrowsers({
      type: "storage_status",
      storage: { online: false, connected: state.storage.connected },
    });
  }
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
  app.get("*", (_request, response) => {
    response.sendFile(join(distDirectory, "index.html"));
  });
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
