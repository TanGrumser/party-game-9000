---
description: Use Bun instead of Node.js, npm, pnpm, or vite.
globs: "*.ts, *.tsx, *.html, *.css, *.js, *.jsx, package.json"
alwaysApply: false
---

# Party Game 9000

A multiplayer auto-scroll billiard physics-based game built with Godot.

## Monorepo Structure

This is a monorepo containing:
- **`/godot`** - Godot game client
- **`/src/server`** - Bun WebSocket server for multiplayer coordination

## Game Overview

Players connect to lobbies and compete in a physics-based billiard game with auto-scrolling mechanics. One player acts as the authoritative host who computes the game state.

## Core Mechanics

### Lobby System
- Players connect via UI buttons in the Godot client
- Enter an existing **lobby ID** to join, or create a new lobby
- WebSocket connection established to the Bun server

### Multiplayer Architecture
- **Player-authoritative model**: One player (the host) computes physics and game state
- Host broadcasts **position and velocity** of all balls:
  - Every **100ms** (periodic sync)
  - Immediately when a player executes a **ball shot**
- Other players receive state updates and interpolate/reconcile locally

### Ball Shot Mechanic
- **Drag back to load**: Player drags their finger/cursor backward from their ball to charge the shot
- **Release to shoot**: Ball launches in the **opposite direction** of the drag
- Longer drag = more power
- Shot direction and power sent via WebSocket to all players

### Gameplay
- Auto-scrolling billiard physics
- Real-time synchronization via WebSocket

## Technical Architecture

- **Godot** for game client and physics simulation
- **Bun WebSocket server** for lobby management and message relay
- **Player-authoritative** host computes game state
- Host broadcasts ball positions/velocities to all connected players

## Development

- The Bun server runs with HMR - no need to restart manually
- Changes to server files are automatically picked up
- Godot project located in `/godot` directory

---

Default to using Bun instead of Node.js.

- Use `bun <file>` instead of `node <file>` or `ts-node <file>`
- Use `bun test` instead of `jest` or `vitest`
- Use `bun build <file.html|file.ts|file.css>` instead of `webpack` or `esbuild`
- Use `bun install` instead of `npm install` or `yarn install` or `pnpm install`
- Use `bun run <script>` instead of `npm run <script>` or `yarn run <script>` or `pnpm run <script>`
- Use `bunx <package> <command>` instead of `npx <package> <command>`
- Bun automatically loads .env, so don't use dotenv.

## APIs

- `Bun.serve()` supports WebSockets, HTTPS, and routes. Don't use `express`.
- `bun:sqlite` for SQLite. Don't use `better-sqlite3`.
- `Bun.redis` for Redis. Don't use `ioredis`.
- `Bun.sql` for Postgres. Don't use `pg` or `postgres.js`.
- `WebSocket` is built-in. Don't use `ws`.
- Prefer `Bun.file` over `node:fs`'s readFile/writeFile
- Bun.$`ls` instead of execa.

## Testing

Use `bun test` to run tests.

```ts#index.test.ts
import { test, expect } from "bun:test";

test("hello world", () => {
  expect(1).toBe(1);
});
```

## Frontend

Use HTML imports with `Bun.serve()`. Don't use `vite`. HTML imports fully support React, CSS, Tailwind.

Server:

```ts#index.ts
import index from "./index.html"

Bun.serve({
  routes: {
    "/": index,
    "/api/users/:id": {
      GET: (req) => {
        return new Response(JSON.stringify({ id: req.params.id }));
      },
    },
  },
  // optional websocket support
  websocket: {
    open: (ws) => {
      ws.send("Hello, world!");
    },
    message: (ws, message) => {
      ws.send(message);
    },
    close: (ws) => {
      // handle close
    }
  },
  development: {
    hmr: true,
    console: true,
  }
})
```

HTML files can import .tsx, .jsx or .js files directly and Bun's bundler will transpile & bundle automatically. `<link>` tags can point to stylesheets and Bun's CSS bundler will bundle.

```html#index.html
<html>
  <body>
    <h1>Hello, world!</h1>
    <script type="module" src="./frontend.tsx"></script>
  </body>
</html>
```

With the following `frontend.tsx`:

```tsx#frontend.tsx
import React from "react";
import { createRoot } from "react-dom/client";

// import .css files directly and it works
import './index.css';

const root = createRoot(document.body);

export default function Frontend() {
  return <h1>Hello, world!</h1>;
}

root.render(<Frontend />);
```

Then, run index.ts

```sh
bun --hot ./index.ts
```

For more information, read the Bun API docs in `node_modules/bun-types/docs/**.mdx`.
