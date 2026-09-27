# Kenzu CC

ComputerCraft control system for an ATM9 base. It connects the Mekanism
reactor controller and the Applied Energistics storage node to a local React
dashboard through WebSockets.

## Repository structure

- `Program/` — Lua programs installed on both CC:Tweaked computers.
- `Server/` — Node.js WebSocket server and React dashboard.

## Start the dashboard server

```powershell
cd Server
npm install
npm run build
npm start
```

Open <http://localhost:3000>. For development, use `npm run dev` instead.

The server listens on all network interfaces. On this PC its current LAN URL
is `http://192.168.2.10:3000`, and the ComputerCraft WebSocket URL is
`ws://192.168.2.10:3000/ws`.

## Allow the local server in CC:Tweaked

CC:Tweaked blocks private IP addresses by default. In the world's
`serverconfig/computercraft-server.toml`, add an allow rule for the server IP
before the `$private` deny rule, then restart Minecraft/the server:

```toml
[[http.rules]]
    host = "192.168.2.10"
    action = "allow"
```

If Windows asks about Node.js network access, allow it on private networks.

## Install/update the CC programs

Commit and push `Program/` to GitHub first. Then run this command on both the
reactor computer and the ME computer:

```text
wget run https://raw.githubusercontent.com/kenzu926/kenzu_cc/refs/heads/main/Program/installer.lua ws://192.168.2.10:3000/ws
reboot
```

The same installer detects the computer's role automatically. The reactor
computer starts `reactor.lua`; the ME computer starts `me_node.lua`.

## Dashboard features

- Reactor energy, state, temperature, damage and burn rate.
- Start/stop thresholds with persistent settings.
- Safety-checked reactor start and immediate SCRAM.
- ME item list with search and live counts.
- Online/offline state for both CC computers and the ME network.

The dashboard currently has no authentication. Keep port 3000 restricted to
the trusted local network and do not expose it directly to the internet.
