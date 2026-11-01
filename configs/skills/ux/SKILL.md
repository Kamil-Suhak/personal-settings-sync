---
name: ux
description: >-
  Comprehensive UI/UX design, visual craft, and anti-AI-slop audit protocol. Activates
  automatically during non-trivial UI design, component creation, and page restructuring,
  or when explicitly invoked via /ux. Spawns an autonomous UX Auditor subagent to
  critique visual hierarchy, spatial rhythm, affordance, and cohesion, eradicating
  generic AI UI patterns before finalizing.
---

# UX & Visual Craft Protocol (`/ux`)

AI models frequently produce "generic AI slop" when designing user interfaces: cluttered layouts plastered with bubbly rounded pills, patronizing helper text, robotic conversational copy, and Frankenstein structures that look like a collage of sequential patches rather than a cohesive product.

The `/ux` protocol enforces intentional design craftsmanship, holistic problem-solving, and an autonomous **UX Auditor Subagent Loop** to ensure interfaces are sharp, clean, purposeful, and visually mature.

---

## 1. The Core Philosophy: Eliminating Generic AI Slop

### Rule 1: The Anti-Glue Rule for UI (Rethink the Container)
When an action, control, or state is ambiguous, **never patch it by slapping helper text, tooltips, or subtext underneath it**.
- **Bad Instinct**: Adding *"Click here to view your active workspace"* beneath a vague icon button.
- **Craft Solution**: Redesign the parent container. Give the button a self-evident label, reposition it next to relevant context, use a segmented control, or elevate the section typography so the action is unmistakably obvious.

### Rule 2: Ban Pill & Bubble Overload
AI interfaces drown in rounded-full badges and bubbly bordered containers around every piece of metadata, tag, and status.
- **Bad Instinct**: Wrapping status, categories, dates, and counts each in their own colored, pill-shaped bubble with high-contrast borders.
- **Craft Solution**: Rely on typographic hierarchy, subtle muted text colors, spatial grouping, or clean delimiter dots (`•`). Reserve pills exclusively for actionable interactive filters or critical state badges.

### Rule 3: Eliminate Conversational Babble & Meta Copy
UIs are tools, not chatbots. Stop narrating what the user is looking at.
- **Bad Instinct**: Headers like *"Welcome to your project hub! Below you can find all your synchronized repositories and settings."*
- **Craft Solution**: Crisp, functional labels: *"Projects"*, *"Repositories"*, *"Settings"*. Let the visual structure communicate function without conversational filler.

### Rule 4: Cohesive Architecture over Frankenstein Collages
An interface must look conceived as a unified whole from day one—not an accumulation of additive edits.
- If a new control or feature makes a container feel cramped, unbalanced, or disjointed, **zoom out**. Do not simply bolt on another row or column; restructure the parent layout or reconsider the view's information architecture.

---

## 2. Visual Craft & Design System Standards

Adhere to these standards across all UI implementations (Web/Tailwind, Flutter, Desktop, Terminal):

| Dimension | Standard | Common AI Failure Mode |
| :--- | :--- | :--- |
| **Spatial Rhythm** | Strict 4/8pt grid (4, 8, 12, 16, 24, 32, 48, 64px). Symmetrical padding. | Arbitrary pixel values (`13px`, `22px`), uneven card padding, cramped borders. |
| **Typography Hierarchy** | Clear weight/size scale. Tight leading on headings. High contrast between title and body. | Flat wall of similar-sized text; bolding everything; low contrast. |
| **Color & Restraint** | Neutral-first foundation (zinc/slate/neutral). Max 1 primary accent. Muted borders (`border-white/10`). | Default saturated blues/purples everywhere; rainbow category badges. |
| **Affordance & Weight** | Exactly ONE primary CTA per view. Secondary actions are subtle/outline; tertiary are ghost/text. | Five equally bright primary buttons competing for attention. |
| **Whitespace Breathing** | Generous internal padding. Content should never hug edges or feel suffocated. | Crammed micro-containers with 4px margins stuffed into every corner. |

---

## 3. Activation Threshold

To keep development lean, apply this protocol with nuance based on task complexity:

- **Microscopic Tweaks (No subagent needed)**:
  - Nudging a margin, adjusting a color token, fixing a typo, or updating a CSS utility class.
  - *Action*: Apply the anti-slop rules directly inline. Do not launch a subagent.

- **Non-Trivial Work (Spawns UX Auditor subagent)**:
  - Building new components, cards, forms, modals, or views.
  - Redesigning existing screens, layouts, or navigation flows.
  - Any UI task where the user explicitly invokes `/ux`.
  - *Action*: Follow the full 2-Agent Subagent Delegation Loop below.

---

## 4. The UX Auditor Subagent Loop

When non-trivial UI work is performed, the builder agent MUST delegate to a specialized `UX Auditor` subagent before presenting the final result.

```
[Builder Agent]
       │  1. Implements initial UI code
       ▼
[invoke_subagent (Role: 'UX Auditor')]
       │  2. Conducts adversarial anti-slop audit
       │  3. (Optional) Generates Generative UI visual preview artifact
       ▼
[Audit Report returned to Builder]
       │  4. Contains spatial refactor critiques & pill/copy warnings
       ▼
[Builder Agent]
       │  5. Refactors code autonomously to resolve audit findings
       ▼
[Clean, Polished UI Delivered to User]
```

### Step 1: Spawning the Auditor
The builder agent calls `invoke_subagent` with:
- **Role**: `UX Auditor`
- **TypeName**: `research` (or `self` if inspection requires local CLI commands)
- **Prompt**:
  ```text
  You are an uncompromising UX/UI Auditor and visual design critic.
  Audit the recently modified/created UI files for "generic AI slop" and visual craftsmanship defects.

  Review against these 4 non-negotiables:
  1. ANTI-GLUE CHECK: Did the builder add helper text, captions, or tooltips to explain ambiguous controls instead of redesigning the parent container, improving labels, or restructuring layout?
  2. PILL & BUBBLE OVERLOAD: Are there excessive rounded-full pills, colored badges, or bordered containers around basic text/metadata?
  3. CONVERSATIONAL FILLER: Is there patronizing copy, conversational headings ("Welcome to..."), or instructional filler?
  4. SPATIAL & VISUAL HIERARCHY: Is there a clear 4/8pt rhythm? Is whitespace generous? Is there exactly one primary CTA? Does the screen look like a single cohesive design or a collage of sequential patches?

  Provide a structured report with:
  - Slop Detections (Pills, filler text, glued helpers to remove)
  - Spatial & Layout Refactorings (Concrete proposals to restructure parent containers)
  - Hierarchy & Polish Adjustments (Typography, spacing, contrast fixes)
  ```

### Step 2: Visual Inspection via Generative UI Artifacts (When Helpful)
When reviewing complex layouts, component states, or color palettes, the auditor or builder can create a standalone HTML/CSS preview artifact in `<appDataDir>\brain\<conversation-id>` to visually inspect the rendered spatial balance, layout wrapping, and contrast.

### Step 3: Autonomous Remediation
The builder agent receives the auditor's report, applies the spatial and aesthetic refactors directly to the code, and autonomously verifies the result before delivering the finished solution to the user.
