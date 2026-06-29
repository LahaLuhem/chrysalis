# CLAUDE.md — `chrysalis`

Claude-Code-specific guidance. Project facts, stack, repo layout, and hard rules live in
[AGENTS.md](./AGENTS.md); design rationale lives in [`../APPENDIX.md`](../APPENDIX.md).
**Read AGENTS.md first.**

## Role & context

You're assisting with **chrysalis**: a repo whose only job is to **build and publish**
multi-arch (`amd64` + `arm64`) Flutter + Android-SDK Docker images to `ghcr.io/lahaluhem`,
tracking the latest stable Flutter. *How or where the images are consumed is out of scope.*
Treat the user as technical and direct. Published images are outward-facing — a bad or
mistagged push is visible to anyone who pulls — so publishing is a confirm-first action.

## Communication

- **Concise.** No "here's what I just did" recap; the diff speaks.
- **Explain the *why*** when recommending; the *what* is in the diff.
- Reference files as `path:line` (`build_and_push.yml:42`), markdown links when you can.
- Flag anything that changes *what gets published* (tags, registry, platforms) loudly and
  early.

## How the user wants work driven

- **Plan first, then execute incrementally.** For any non-trivial task, present a written
  plan (sub-tasks + intended changes) and **wait for review** before editing. Then do **one
  sub-task at a time**, pausing for review between them. Do **not** one-shot a multi-step
  change.
- **Ask before choosing between defensible alternatives.** If a reasonable maintainer could
  disagree with a pick, stop and ask — list options with trade-offs, mark your
  recommendation with `★`, then wait. Obvious single-answer fixes (typo, one-correct-patch
  bug): just do them.
- **Surface findings that change the premise.** If verification contradicts an assumption
  (as the arm64 limitation did), stop and report before building on it.
- **Refactor first when it clears the way.** If a change would sit cleaner on a different
  structure (or upcoming work will strain the current one), do the enabling,
  behaviour-preserving refactor as step one, then build the change on it. Repo longevity beats
  short-term speed. Full rationale: `~/.claude/rules/refactor-first.md`.

## VCS — the user manages git

- **Do NOT commit, push, branch, merge, rebase, tag, or otherwise mutate git** unless the
  user explicitly asks *in that message*. The user owns version control here.
- Make changes in the working tree and let the user commit. If something is commit-worthy,
  say so and suggest a message — don't run `git commit`.
- Never `git add -A`; never `--force` / `reset --hard` / `branch -D` / `clean -fd`.

## Tool preferences

- **Read / Edit / Grep / Glob** over `cat` / `sed` / `grep` / `find`.
- **Bash** for things without a dedicated tool: `docker` / `docker buildx`, `gh`, `curl`,
  and (only when the user asks) `git`.
- **Lint workflows with `actionlint`** before treating a workflow change as done — it
  catches expression + shellcheck issues that plain YAML parsing misses.
- **Verify versions against registries** before pinning an action or dependency — never
  from memory (`~/.claude/rules/dependency-versions.md`).
- **Agent / Explore** for wide, open-ended searches, to keep large output out of context.

## Validating arm64 (the main risk)

The arm64 image's Android toolchain is x86-64 (AGENTS hard rule 5). When a change could
affect arm64, **validate natively** — this is an Apple-Silicon host with OrbStack, so you
can `docker buildx build --platform linux/arm64 … --load` and run the real tools, including
`flutter build apk --debug` on a throwaway app. Report exactly what you verified and what
you did NOT.

## Definition of done

- **`actionlint` clean** on any touched workflow.
- **Dockerfile changes build** for the affected arch(es) locally where feasible.
- **arm64-affecting changes validated natively** — or an explicit note of what wasn't.
- **A publish is "done" only when `docker manifest inspect <ref>` shows BOTH `linux/amd64`
  and `linux/arm64`.** Never claim a successful multi-arch publish otherwise.
- Report outcomes faithfully — if CI hasn't run or you couldn't verify, say so.

## Auto-memory conventions for this project

- **`project`** — scope/constraints the user states aloud (deadlines, decisions like the
  arm64 strategy). Convert relative dates to absolute.
- **`feedback`** — corrections and validated non-obvious choices, with **Why** + **How to
  apply** (the plan-first/incremental workflow is one).
- **`reference`** — external pointers (the upstream forks, GHCR package pages, the Flutter
  releases JSON).
- **Don't save** what the repo records (file paths, the workflow shape, `versions.env`) —
  re-derive it. Verify a named file/flag still exists before acting on a memory.

## Forbidden / confirm-first actions

- **Publishing images** — anything that pushes to `ghcr.io/lahaluhem`, including triggering
  the publish workflow on a branch via `workflow_dispatch` — is **confirm-first**
  (outward-facing).
- **Any git mutation** — see *VCS* above.
- **Hand-editing `versions.env`'s `FLUTTER_VERSION`** — that's Renovate's job
  (`.github/renovate.jsonc`); bump only when the user asks.
- **Destructive Docker on shared state** (`docker system prune`, removing the user's
  images/volumes) — ask first.
