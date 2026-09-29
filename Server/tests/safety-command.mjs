import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { WebSocket } from "ws";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const port = 31991;
const token = "test-token-with-24-characters";
const base = `http://127.0.0.1:${port}`;
const child = spawn(process.execPath, [join(root, "server.mjs")], {
  cwd: root,
  env: { ...process.env, PORT: String(port), HOST: "127.0.0.1", CC_AUTH_TOKEN: token },
  stdio: ["ignore", "pipe", "pipe"],
});

const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function waitForServer() {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    try {
      const response = await fetch(`${base}/health`);
      if (response.ok) return;
    } catch {}
    await delay(100);
  }
  throw new Error("Test server did not start");
}

function nextCommand(socket) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("Command was not delivered")), 2_000);
    const listener = (raw) => {
      const message = JSON.parse(raw.toString());
      if (message.type !== "command") return;
      clearTimeout(timeout);
      socket.off("message", listener);
      resolve(message);
    };
    socket.on("message", listener);
  });
}

function nextMessage(socket, type) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error(`${type} was not delivered`)), 2_000);
    const listener = (raw) => {
      const message = JSON.parse(raw.toString());
      if (message.type !== type) return;
      clearTimeout(timeout);
      socket.off("message", listener);
      resolve(message);
    };
    socket.on("message", listener);
  });
}

function reactorStatus(safety) {
  return { type: "reactor_status", data: { running: true, stopPercent: safety.energyStopPercent, safety } };
}

let socket;
let plansSocket;
try {
  await waitForServer();
  socket = new WebSocket(`ws://127.0.0.1:${port}/ws`);
  await new Promise((resolve, reject) => {
    socket.once("open", resolve);
    socket.once("error", reject);
  });
  socket.send(JSON.stringify({ type: "hello", role: "reactor", computerId: 1, token }));

  plansSocket = new WebSocket(`ws://127.0.0.1:${port}/ws`);
  await new Promise((resolve, reject) => {
    plansSocket.once("open", resolve);
    plansSocket.once("error", reject);
  });
  plansSocket.send(JSON.stringify({ type: "hello", role: "plans", computerId: 2, token }));
  await delay(50);

  let safety = {
    energyEnabled: true,
    steamEnabled: true,
    waterEnabled: true,
    fuelEnabled: true,
    energyStartPercent: 80,
    energyStopPercent: 98,
    steamStopPercent: 95,
    waterStopPercent: 10,
    fuelStopPercent: 5,
    temperatureStop: 1100,
    damageStopPercent: 0,
    wasteStopPercent: 90,
  };
  socket.send(JSON.stringify(reactorStatus(safety)));
  await delay(100);

  const changes = [
    ["energy", 92],
    ["steam", 88],
    ["water", 17],
    ["fuel", 12],
    ["temperature", 1050],
    ["damage", 2],
    ["waste", 80],
  ];
  for (const [key, threshold] of changes) {
    const incoming = nextCommand(socket);
    const response = await fetch(`${base}/command`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ type: "safety.set", value: { key, enabled: true, threshold } }),
    });
    assert.equal(response.status, 202);
    const command = await incoming;
    assert.equal(command.action, "set_safety");
    const commandFields = {
      energy: "energyStopPercent",
      steam: "steamStopPercent",
      water: "waterStopPercent",
      fuel: "fuelStopPercent",
      temperature: "temperatureStop",
      damage: "damageStopPercent",
      waste: "wasteStopPercent",
    };
    assert.equal(command[commandFields[key]], threshold);
    safety = {
      energyEnabled: command.energyEnabled,
      steamEnabled: command.steamEnabled,
      waterEnabled: command.waterEnabled,
      fuelEnabled: command.fuelEnabled,
      energyStartPercent: command.energyStartPercent,
      energyStopPercent: command.energyStopPercent,
      steamStopPercent: command.steamStopPercent,
      waterStopPercent: command.waterStopPercent,
      fuelStopPercent: command.fuelStopPercent,
      temperatureStop: command.temperatureStop,
      damageStopPercent: command.damageStopPercent,
      wasteStopPercent: command.wasteStopPercent,
    };
    socket.send(JSON.stringify(reactorStatus(safety)));
    await delay(25);
  }

  const snapshot = await fetch(`${base}/snapshot`, {
    headers: { Authorization: `Bearer ${token}` },
  }).then((response) => response.json());
  assert.equal(snapshot.safety.energy.threshold, 92);
  assert.equal(snapshot.safety.steam.threshold, 88);
  assert.equal(snapshot.safety.water.threshold, 17);
  assert.equal(snapshot.safety.fuel.threshold, 12);
  assert.equal(snapshot.safety.temperature.threshold, 1050);
  assert.equal(snapshot.safety.temperature.enabled, true);
  assert.equal(snapshot.safety.damage.threshold, 2);
  assert.equal(snapshot.safety.damage.enabled, true);
  assert.equal(snapshot.safety.waste.threshold, 80);
  assert.equal(snapshot.safety.waste.enabled, true);

  const warningDelivery = nextMessage(plansSocket, "safety_chat");
  socket.send(JSON.stringify({
    type: "safety_alert",
    channel: "energy",
    stage: "warning",
    value: 80,
    threshold: 90,
  }));
  const warning = await warningDelivery;
  assert.match(warning.messages[0], /80%/);
  assert.match(warning.messages[0], /90%/);
  assert.equal(JSON.parse(warning.formattedMessages[0]).text, warning.messages[0]);
  assert.doesNotMatch(warning.formattedMessages[0], /[^\x20-\x7e]/);

  const triggerDelivery = nextMessage(plansSocket, "safety_chat");
  socket.send(JSON.stringify({
    type: "safety_alert",
    channel: "temperature",
    stage: "triggered",
    value: 1100,
    threshold: 1100,
  }));
  const trigger = await triggerDelivery;
  assert.match(trigger.messages[0], /SCRAM/);
  assert.match(trigger.messages[0], /1100 K/);
  console.log("All safety settings and chat alerts are delivered and retained.");
} finally {
  socket?.close();
  plansSocket?.close();
  child.kill();
}
