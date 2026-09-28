import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { WebSocket } from "ws";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const port = 31992;
const token = "terminal-test-token-24-chars";
const child = spawn(process.execPath, [join(root, "server.mjs")], {
  cwd: root,
  env: { ...process.env, PORT: String(port), HOST: "127.0.0.1", CC_AUTH_TOKEN: token },
  stdio: "ignore",
});
const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
const waitForServer = async () => {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/health`);
      if (response.ok) return;
    } catch {
      // The child process is still starting.
    }
    await delay(100);
  }
  throw new Error("Test server did not become ready");
};
const connect = (role, computerId, firstType) => new Promise((resolve, reject) => {
  const socket = new WebSocket(`ws://127.0.0.1:${port}/ws`);
  socket.once("open", () => {
    const first = firstType ? next(socket, firstType) : undefined;
    socket.send(JSON.stringify({ type: "hello", role, computerId, token }));
    resolve({ socket, first });
  });
  socket.once("error", reject);
});
const next = (socket, type) => new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error(`Missing ${type}`)), 2_000);
  const listener = (raw) => {
    const message = JSON.parse(raw.toString());
    if (message.type !== type) return;
    clearTimeout(timeout);
    socket.off("message", listener);
    resolve(message);
  };
  socket.on("message", listener);
});

let terminal;
let browser;
try {
  await waitForServer();
  ({ socket: terminal } = await connect("terminal", 7));
  terminal.send(JSON.stringify({
    type: "terminal_frame",
    computerId: 7,
    terminalRole: "reactor",
    sessionId: "7:test",
    sequence: 1,
    width: 3,
    height: 1,
    cursorX: 2,
    cursorY: 1,
    cursorBlink: true,
    lines: [{ text: "abc", fg: "000", bg: "fff" }],
  }));
  await delay(50);
  const browserConnection = await connect("browser", undefined, "state");
  browser = browserConnection.socket;
  const state = await browserConnection.first;
  assert.equal(state.state.terminals["7"].lines[0].text, "abc");
  assert.equal(state.state.terminals["7"].terminalRole, "reactor");

  const incoming = next(terminal, "terminal_input");
  browser.send(JSON.stringify({ type: "terminal_input", target: "7", event: "paste", value: "update" }));
  const input = await incoming;
  assert.equal(input.value, "update");
  console.log("Terminal frames and input stay synchronized.");
} finally {
  terminal?.close();
  browser?.close();
  child.kill();
}
