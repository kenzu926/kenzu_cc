import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { unlink } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { WebSocket } from "ws";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const port = 31995;
const translationPort = 31996;
const token = "plans-test-token-with-24-characters";
const plansFile = join(tmpdir(), `kenzu-plans-${process.pid}.json`);
const base = `http://127.0.0.1:${port}`;

const translationServer = createServer((_request, response) => {
  response.setHeader("Content-Type", "application/json");
  response.end(JSON.stringify({ translatedText: "Build a second turbine" }));
});
await new Promise((resolve) => translationServer.listen(translationPort, "127.0.0.1", resolve));

const child = spawn(process.execPath, [join(root, "server.mjs")], {
  cwd: root,
  env: {
    ...process.env,
    PORT: String(port),
    HOST: "127.0.0.1",
    CC_AUTH_TOKEN: token,
    PLANS_FILE: plansFile,
    TRANSLATE_API_URL: `http://127.0.0.1:${translationPort}/?text={text}`,
  },
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

const nextPlans = (socket) => nextMessage(socket, "plans_update");

let socket;
try {
  await waitForServer();
  socket = new WebSocket(`ws://127.0.0.1:${port}/ws`);
  await new Promise((resolve, reject) => {
    socket.once("open", resolve);
    socket.once("error", reject);
  });
  const initial = nextPlans(socket);
  socket.send(JSON.stringify({ type: "hello", role: "plans", computerId: 7, token }));
  assert.deepEqual((await initial).plans, []);

  const incomingCreate = nextPlans(socket);
  const createdResponse = await fetch(`${base}/plans`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ text: "Построить вторую турбину" }),
  });
  assert.equal(createdResponse.status, 201);
  const { plan } = await createdResponse.json();
  assert.equal(plan.russianText, "Построить вторую турбину");
  assert.equal(plan.englishText, "Build a second turbine");
  assert.equal(plan.number, 1);
  assert.equal((await incomingCreate).plans[0].text, "Build a second turbine");

  const incomingComplete = nextPlans(socket);
  const completed = await fetch(`${base}/plans/${plan.id}`, {
    method: "PATCH",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ done: true }),
  });
  assert.equal(completed.status, 200);
  assert.equal((await incomingComplete).plans[0].done, true);

  const incomingDelete = nextPlans(socket);
  const deleted = await fetch(`${base}/plans/${plan.id}`, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${token}` },
  });
  assert.equal(deleted.status, 200);
  assert.deepEqual((await incomingDelete).plans, []);

  const chatUpdate = nextPlans(socket);
  const chatResult = nextMessage(socket, "plans_result");
  socket.send(JSON.stringify({
    type: "plans_command",
    action: "add",
    text: "Построить вторую турбину",
    username: "Kenzu",
    requestId: "chat-add",
  }));
  const addedFromChat = await chatUpdate;
  assert.equal(addedFromChat.plans[0].number, 2);
  assert.equal(addedFromChat.plans[0].text, "Build a second turbine");
  const addResult = await chatResult;
  assert.equal(addResult.username, "Kenzu");
  assert.match(addResult.messages[0], /#2/);
  assert.equal(addResult.formattedMessages.length, addResult.messages.length);
  assert.match(addResult.formattedMessages[0], /\\u[0-9a-f]{4}/i);
  assert.doesNotMatch(addResult.formattedMessages[0], /[^\x20-\x7e]/);
  assert.equal(JSON.parse(addResult.formattedMessages[0]).text, addResult.messages[0]);

  const completeUpdate = nextPlans(socket);
  const completeResult = nextMessage(socket, "plans_result");
  socket.send(JSON.stringify({
    type: "plans_command",
    action: "complete",
    id: 2,
    username: "Kenzu",
    requestId: "chat-complete",
  }));
  assert.equal((await completeUpdate).plans[0].done, true);
  assert.match((await completeResult).messages[0], /выполненным/);
  console.log("Plans translation, persistence, and monitor delivery test passed");
} finally {
  socket?.close();
  child.kill();
  await new Promise((resolve) => translationServer.close(resolve));
  await unlink(plansFile).catch(() => {});
  await unlink(`${plansFile}.tmp`).catch(() => {});
}
