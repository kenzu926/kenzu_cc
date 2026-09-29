import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { WebSocket } from "ws";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const port = 31993;
const masterToken = "invite-test-master-token-123456";
const base = `http://127.0.0.1:${port}`;
const child = spawn(process.execPath, [join(root, "server.mjs")], {
  cwd: root,
  env: { ...process.env, PORT: String(port), HOST: "127.0.0.1", CC_AUTH_TOKEN: masterToken },
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

function websocketHello(role, token) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(`ws://127.0.0.1:${port}/ws`);
    const timeout = setTimeout(() => {
      socket.terminate();
      reject(new Error(`No WebSocket response for ${role}`));
    }, 2_000);
    socket.once("error", reject);
    socket.once("open", () => socket.send(JSON.stringify({ type: "hello", role, token })));
    socket.once("message", (raw) => {
      clearTimeout(timeout);
      const message = JSON.parse(raw.toString());
      socket.close();
      resolve(message);
    });
  });
}

try {
  await waitForServer();

  const created = await fetch(`${base}/invite`, {
    method: "POST",
    headers: { Authorization: `Bearer ${masterToken}` },
  });
  assert.equal(created.status, 201);
  const invitation = await created.json();
  assert.equal(typeof invitation.code, "string");
  assert.ok(invitation.code.length >= 24);

  const redeemed = await fetch(`${base}/invite/redeem`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ code: invitation.code }),
  });
  assert.equal(redeemed.status, 200);
  const session = await redeemed.json();
  assert.equal(typeof session.token, "string");

  const reused = await fetch(`${base}/invite/redeem`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ code: invitation.code }),
  });
  assert.equal(reused.status, 410);

  const snapshot = await fetch(`${base}/snapshot`, {
    headers: { Authorization: `Bearer ${session.token}` },
  });
  assert.equal(snapshot.status, 200);

  const delegatedInvite = await fetch(`${base}/invite`, {
    method: "POST",
    headers: { Authorization: `Bearer ${session.token}` },
  });
  assert.equal(delegatedInvite.status, 403);

  assert.equal((await websocketHello("browser", session.token)).type, "state");
  assert.equal((await websocketHello("gateway", session.token)).type, "auth_error");
  console.log("Invite flow test passed");
} finally {
  child.kill();
}
