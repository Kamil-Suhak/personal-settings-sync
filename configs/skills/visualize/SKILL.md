---
name: visualize
description: >-
  Code-planning and architecture-diagramming workflow skill building on generative_ui.
  Use when designing or explaining game systems, API structures, HTTP flows, databases,
  data pipelines, state machines, or user happy-paths—routing cleanly between inline Mermaid,
  D2-compiled SVG viewers, and interactive HTML/Canvas widgets while preserving plain-text
  .d2 or .mmd source files.
---

# Visualize: Architecture & System Diagramming

Turns game systems, APIs, HTTP flows, schemas, data pipelines, state machines, and user happy-paths into crisp visuals while keeping plain-text `.d2` or `.mmd` files as the editable source of truth.

This skill builds on Antigravity's built-in `generative_ui` skill:
- **`generative_ui`** governs HTML artifact creation, `<agent-embed>`, CSP rules, semantic theme variables, and compact inline sizing (`<= 450px`).
- **`visualize`** governs **when and how** to pick between inline Mermaid, D2 + the pan/zoom SVG viewer, and custom interactive HTML/Canvas widgets.

Read `generative_ui` whenever rendering HTML artifacts (Routes 2 and 3).

---

## Format Routing Decision Tree

Always choose the **simplest** tool that renders cleanly without label truncation or edge/box collisions:

1. **Inline Mermaid (Zero-Setup, Linear Flows)**
   - **Use when:** Linear or low-branching diagrams fit cleanly in chat without overlapping arrows:
     - Pipelines & happy-paths (`flowchart LR`)
     - Short HTTP / auth / RPC exchanges (`sequenceDiagram`)
     - Simple database schemas (`erDiagram`)
     - Compact OOP/type hierarchies (`classDiagram`)
     - Basic metric plots (`xychart-beta`)
   - **Formatting rules:**
     - Quote node labels containing parentheses, brackets, or special characters: `api["API Gateway (v2)"]` instead of `api[API Gateway (v2)]`.
     - Never put raw HTML tags (such as `<br/>` or `<b>`) inside labels.
     - Prefer `flowchart LR` (or `direction LR` inside `stateDiagram-v2`) when bidirectional transitions would cause top-down edge/box collisions.
   - **Source of truth (if persisting):** Save the `.mmd` source in `docs/diagrams/<name>.mmd` when documenting an architecture long-term.

2. **D2 → SVG → Pan/Zoom HTML Viewer (Complex & Nested Systems)**
   - **Use when:** Mermaid becomes cramped or tangled:
     - Multi-layer architectures & service boundaries
     - Nested containers (e.g., `Game Backend -> Combat Loop`)
     - SQL tables / ERDs shown alongside services or queues
     - State machines with bidirectional edges and dense cross-links
   - **D2 Layout, Sizing & Syntax Guidelines (Hit First Pass Cleanly):**
     - **Topology → Direction:** Use `direction: right` for linear pipelines; use **`direction: down`** at root (with `direction: right` on sibling groups) for fan-out systems (`1 core -> 2+ symmetrical targets`) so arrows flow downward without wide horizontal routing gutters.
     - **Node & Edge Budget:** Aim for **<= 15–20 leaf nodes** and **<= 15 cross-container edges** per diagram (split larger systems into focused views). Avoid fanning 4+ parallel labeled arrows between the same containers—group shared actions into one container-level arrow so ELK doesn't stretch intermediate gaps.
     - **Fit-View Sizing:** Target an aspect ratio of **1.3:1 to 1.8:1** and keep the SVG's long edge ideally **<= 3500px** (wrap labels to **<= 3 lines, ~35–40 chars/line**) so the default `Fit` zoom inside the `360px` stage is readable before zooming.
     - **Escaping `$`:** Escape literal `$` as `\$` inside double-quoted D2 strings (`"\$HOME"`, `"\$DOCUMENTS"`) because unescaped `$` triggers D2 variable substitution errors.
   - **Workflow:**
     1. **Write `.d2` source of truth:** Save to the project's `docs/diagrams/<name>.d2` if persistent architecture documentation, or to the conversation `<Artifact Directory Path>/scratch/<name>.d2` if exploratory.
     2. **Compile & strip fonts in one step:** Run [`scripts/prepare-d2-svg.ps1`](./scripts/prepare-d2-svg.ps1) (resolves `d2` on `PATH` or `C:\Program Files\D2\d2.exe`, compiles with `--pad 24`, strips `<?xml?>` + embedded `@font-face` WOFF blobs, and prints `WxH`, aspect ratio, and size):
        ```powershell
        pwsh -NoProfile -File "<skill-dir>\scripts\prepare-d2-svg.ps1" "<source>.d2" "<out>.svg" -Layout elk
        ```
        Omit `-Layout elk` for simpler graphs where dagre is preferred; use `-Layout elk` when crisp 90° orthogonal routing is needed.
     3. **Fallback if `d2` is unavailable (exit code `2`):** Fall back cleanly to Mermaid `flowchart LR` (splitting into focused sub-diagrams if needed) or build a clean hand-crafted `<svg>` and inject it into the HTML viewer below.
     4. **Wrap in the pan/zoom viewer & embed:**
        - Read `<out>.svg` and [`resources/viewer-template.html`](./resources/viewer-template.html).
        - Replace `{{TITLE}}` with a concise diagram title and `{{SVG}}` with the stripped `<svg>...</svg>` markup.
        - Write the resulting self-contained `.html` file to `<Artifact Directory Path>/<name>.html` using `write_file` with `ArtifactMetadata: { UserFacing: true, RequestFeedback: false, Summary: "..." }`.
        - Embed inline in your response using:
          ```html
          <agent-embed src="file:///<artifact_path>/<name>.html"></agent-embed>
          ```

3. **Interactive HTML/Canvas Widgets (Quantitative & Dynamic)**
   - **Use when:** Static diagrams cannot answer the user's question—e.g., live game-balance/damage curves, economy/Drop-rate simulators, latency/throughput calculators, or clickable state-machine steppers.
   - **Rules (from `generative_ui`):**
     - Self-contained HTML loading **only** `https://www.gstatic.com/antigravity/web/dev/tailwindcss.min.js` (all other external CDNs are blocked by CSP).
     - Flush inline styling: `<body class="bg-transparent text-[var(--foreground)] p-0 m-0">` using Antigravity CSS variables (`--card`, `--card-border`, `--foreground`, `--muted-foreground`, `--primary`, etc.) rather than hardcoded light/dark Tailwind color utilities or `:root` overrides.
     - Keep inline widgets `<= 450px` tall and **never** use `100vh`, `min-h-screen`, `h-screen`, or `height: 100%` on top-level containers.
     - Embed inline with `<agent-embed src="file:///<artifact_path>/<name>.html"></agent-embed>`, or omit `<agent-embed>` and link the `.html` artifact for standalone side-pane exploration if it exceeds `450px`.

---

## Pan/Zoom Viewer Specs (`resources/viewer-template.html`)

- **Size:** `<= 430px` total height (`360px` interactive `#stage` + `42px` header bar).
- **Controls:** Title, `Drag to pan · Scroll to zoom` hint, live zoom percentage (`100%`), `-`, `+`, and `Fit` buttons.
- **Engine:** Auto-fits on load and resize; pointer-capture drag-to-pan and cursor-centered wheel zoom (`0.1x`–`3x`) driven by GPU-accelerated `transform: translate3d(tx, ty, 0) scale(scale)` (`transform-origin: 0 0`, `will-change: transform`).
- **One Dark Pro D2 Theme:** `#282C34` stage with `#stage .d2-svg` CSS overrides for dark containers (`#21252B`, `#2C313C`, `#323842`, `#3E4451`), primary/secondary text (`#ABB2BF`, `#828997`), `#61AFEF` accents/arrows/SQL columns, `#E5C07B` constraints (`PK`/`FK`), high-contrast SQL headers, and `ui-sans-serif, system-ui, sans-serif` font overrides.
