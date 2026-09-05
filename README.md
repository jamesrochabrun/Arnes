# Arnes

*Arnés* — Spanish for **harness**. A model-adaptive agent harness for
[OpenRouter](https://openrouter.ai), built in Swift.

Every major coding agent is tuned for one model family; swapping the model underneath leaves
the wrong prompts and wire format in place. Arnes inverts that: **the model you pick drives
everything** — the wire dialect, the prompt pack, the request shape — all discovered from
OpenRouter's live model manifest, never hardcoded. See [DESIGN.md](DESIGN.md) for the full
architecture; [INSTRUCTIONS.md](INSTRUCTIONS.md) if you're contributing.

## Install

Prebuilt binaries (macOS arm64/x64, Linux x64/arm64) ship on npm — any JS package
manager works:

```bash
bun add -g arnes                # or: npm install -g arnes
bunx arnes                      # or zero-install one-off runs
export OPENROUTER_API_KEY=sk-or-...
arnes --help
```

The key can also live in `~/.arnes/credentials` (just the key on one line, or
`OPENROUTER_API_KEY=sk-or-...`; `chmod 600` it) — used whenever the env var is unset, so
arnes works from shells that never source your profile.

Not on OpenRouter? See [Providers & gateways](#providers--gateways) for LiteLLM and
other OpenAI-compatible endpoints.

Binaries are also attached to each [GitHub release](https://github.com/jamesrochabrun/Arnes/releases).
Or build from source:

```bash
git clone https://github.com/jamesrochabrun/Arnes && cd Arnes
./scripts/install.sh            # builds release + installs to /opt/homebrew/bin (pass a dir to override)
```

(The script removes the old binary and ad-hoc re-signs the new one — overwriting a signed
binary in place gets it SIGKILLed on Apple Silicon.)

## Interactive mode

`arnes` with no subcommand opens the REPL — the primary way to live in the tool:

```bash
arnes                                   # router picks the model (openrouter/auto)
arnes -m anthropic/claude-haiku-4.5     # pick one up front
arnes -m openrouter/auto --fallback deepseek/deepseek-v4-flash   # reliability chain
arnes --safe                            # read-only: every mutating tool is denied
arnes --no-mcp                          # skip connecting MCP servers (see "MCP servers" below)
arnes --continue                        # resume the most recent session
arnes --resume <id>                     # resume a specific one (ids from `arnes sessions`)

› refactor Sources/App/Router.swift to use async/await
# streams the answer (reasoning dimmed, when the model emits it);
# asks before each mutating tool (bash / write_file / edit_file) and before any read
# outside the working directory or of a credential path (~/.ssh, ~/.aws, …):
#   y = allow once · a = always this session (a scoped pattern: the command prefix, or for an
#       out-of-tree read the whole directory, so exploring a sibling repo asks once per tree)
#       · n = deny (the model is told)
# read-only tools (read_file / grep / glob) run freely inside the working directory;
# Ctrl-C interrupts the turn safely;
# tool activity renders as one concise line per call (• edit_file Sources/App/Router.swift) —
# Ctrl-O toggles the verbose form (raw arguments + result previews), mid-turn or at the prompt;
# typing while a turn streams queues input: lines ended with Enter run next, in order,
# and an unfinished fragment pre-fills the next prompt;
# the model may ask you one short question mid-turn (ask_user): it shows as
#   ? model asks: Which database?   1) sqlite   2) postgres
# and the input box becomes the answer field — type a line (a number picks an option),
# Enter sends it, Esc skips (the model is told to assume); at most 3 questions per turn;
# every turn ends with a status line:
# ─ openrouter/auto → deepseek/deepseek-v4-flash · 3 steps · 2 tools · turn $0.0004 · session $0.0021 · ctx 12%
```

Slash commands inside the REPL:

```text
/model sonnet     switch the WHOLE conversation to another model, mid-session —
                  history is client-side, so 20 turns into Claude you can finish on GPT
                  (fuzzy search: "son5", "4o", "flash" all resolve; even across dialects —
                  anthropic→openai swaps the wire format under the same conversation)
/cost             running session total (live usage.cost)
/verify [model]   loop-1: a second model judges whether the last task was completed
/compact [model] [instructions]
                  summarize older turns to free context (also automatic at ~80% full, once
                  clearing older tool results from the request wasn't enough; the status
                  line shows live usage: · ctx 34%); the first word is a model only if it has
                  a / or is a configured alias — the rest steers the summary
/save demo        name the session; resume later with /resume or `arnes resume demo`
                  (/rename does the same)
/resume [id|name] switch to another saved session without leaving the REPL
                  (most recent other session when omitted; unique id prefixes work)
/fork [name]      branch: continue in a copy and leave the original where it was —
                  a "try it another way" point you can /resume back to
/rewind [n [what]] list the turns (and the files each changed); /rewind 3 puts the files
                  back as they were at the start of turn 3 AND cuts the conversation to it,
                  after a y/N — add code or conversation to do only one (/undo = the last
                  turn's files, conversation kept). Pre-images are kept before every
                  write_file/edit_file; bash edits and commits are not checkpointed
/diff             uncommitted changes (git) — or, outside a repo, what changed since the
                  session began, from the checkpoints
/memory           the project's memory: where it lives, how much of it is loaded, the index
/tasks            background subagents and shell jobs (`bash … background: true`) this session runs
/status           key limits + credit balance
/status           the session and its dials: id, name, fork parent, model, the dialect the
                  last turn actually used, effort, provider, mode, sandbox, hooks, messages,
                  cost vs budget, the measured context, taint, the model's current plan
/context          what the next request spends the context window on — every system-prompt
                  section by name, the history by role, the tool definitions — in bytes and
                  ~tokens (scaled to the last request's real prompt tokens once one was measured)
/btw <question>   a side question over the conversation, answered inline with a (btw) prefix
                  and never remembered by the model
/effort high      move the reasoning-effort dial from the next request on (minimal…max, none,
                  or off = no dial); persists with the session
/thinking off     hide streamed reasoning (Ctrl-T does the same, mid-turn too; the model still
                  thinks — only the display changes)
/budget 0.50      let this session spend $0.50 more (a turn stops at the step that crosses it;
                  /budget off lifts the ceiling) — the REPL also takes --budget, --max-steps
                  and --dialect like `arnes do`
/schema <file>    ask every finished turn for its answer as one JSON object matching the
                  schema (a file or an inline {…}), printed under the reply; /schema off
                  stops, /schema alone shows the one in force — the REPL also takes
                  --output-schema like `arnes do`
/clear            wipe history (keeps the session)
/help /exit       (/quit and /q also exit)
```

Sessions persist to `~/.arnes/sessions/` as every message lands (crash-safe), and every file
the agent writes or edits is checkpointed first under `~/.arnes/checkpoints/<session>/` (owner-only,
swept with the session), so a wrong edit is one `/rewind` away (`checkpoints: {enabled: false}`
in `~/.arnes/config.json` turns it off). The model also keeps **memory** across sessions:
`~/.arnes/memory/<project>/MEMORY.md` (notes it writes with the ordinary file tools — every such
write asks you first) rides its system prompt as a `# Memory` section, capped and scanned like a
tool result; `arnes memory` lists/shows/forgets it, `--no-memory` or `memory: {enabled: false}`
switches it off. The REPL
also works piped — no TTY needed, so scripts and agents can drive it:

```bash
printf 'summarize Sources/ArnesKit/Session.swift\n/cost\n/exit\n' | arnes -m deepseek/deepseek-v4-flash
```

(For piped runs that must *mutate* files, prefer headless `arnes do --yes` below — it
approves tool calls up front instead of prompting.)

Saved sessions are yours to keep or throw away:

```bash
arnes sessions                                # list (most recent first)
arnes sessions export <id|prefix|name>        # readable markdown (--out <file> to save it)
arnes sessions delete <id|prefix|name>        # transcript + its scratch
arnes sessions prune --older-than 30          # sweep by age (--all also drops named ones)
arnes resume <id> --fork --name experiment    # continue in a copy; the original stays put
```

Retention can be automatic — `"sessions": {"retentionDays": 30}` in `~/.arnes/config.json`
sweeps unnamed sessions older than that once per process and says what it removed. It is off
unless you set it: a harness that quietly deletes your history is worse than one that keeps
too much.

Headless stays first-class:

```bash
# one-shot chat, router picks the model, cost printed after
arnes chat "explain actors in swift" -m openrouter/auto

# agent loop with tools (read/write/edit/bash/grep/glob), verified by a second model
arnes do "add a --version flag to main.swift" --yes \
  -m anthropic/claude-sonnet-5 \
  --fallback openai/gpt-5.6-luna \
  --verify openai/gpt-4o-mini
# --yes (-y) auto-approves mutations and out-of-tree reads; without it a headless run is
# read-only inside the working directory and the model is told to report instead
# --verify judges the agent's report against the uncommitted diff of the working tree (never
# the transcript) and answers a structured verdict: PASS (high) — … / FAIL (medium) — unmet: …
# prints "⇄ routed to <model> (<provider>)" live when routing changes, and ends with
# [requested openrouter/auto → served by deepseek/deepseek-v4-flash · 3 steps · $0.0003]
# --session persists the transcript; --session-id <uuid> pins its id so a pipeline can --resume it
# by name (refused when a saved session already has it, and beside --resume/--continue/--fork/--panel)

# discover models
arnes models "grok" --supports tools

# key limits + credit balance, plus one row per switch a run reads (sandbox, framing, transport,
# prompt cache, manifest cache, compaction, checkpoints, memory, web, limits, subagents, judge)
arnes status

# the local scoreboard: cost + verifier pass-rate per model (+ the verifier's stated confidence
# and the prompt-cache hit rate, each column only when a shown run reported it)
arnes runs

# every listing takes --json (one document, stable snake_case keys) for scripts
arnes runs --json --days 7

# check the setup a run would load — config, key, hooks, MCP, rules, sandbox, instruction files
arnes doctor                 # exit 1 on any error; --connect also fetches the manifest + MCP

# the exact system prompt + tool list a session here would send, with per-section sizes
arnes debug prompt
arnes debug prompt --permission-mode acceptEdits --effort high --add-dir ../lib --disallowed-tools bash
# …as THAT run would send it; the tool table is the set offered to the model (a withheld view_image is named)

# write this repo's AGENTS.md with the built-in `init` skill — one headless turn that edits without asking
arnes init -m haiku          # runs as `do … --yes --permission-mode acceptEdits --no-mcp --no-agents --no-memory`: in-tree writes only

# evals: models × tasks × trials in isolated workdirs, scored by check scripts
arnes eval evals/basics -m anthropic/claude-haiku-4.5,openai/gpt-4o-mini -t 3
# ✓ fix-bug · anthropic/claude-haiku-4.5 · 5 steps · $0.0112 · 14.1s
# model                        pass        cost      steps  time   errors
# anthropic/claude-haiku-4.5   24/24 (100%)  $0.15   3.4    8.5s   0
#   pass@3 8/8 · pass^3 8/8                  (with -t > 1: tasks passed at least once / every time)

# as a CI gate: 4 trials at once, exit 2 under 100% or on a regression against the history, one JSON document
arnes eval evals/basics -m deepseek/deepseek-v4-flash --parallel 4 --min-pass 1.0 \
  --compare last --fail-on-regression --json > report.json     # see .github/workflows/arnes-evals.yml
arnes eval evals/basics -m deepseek -m haiku --compare last:3 --json   # -m repeats accumulate (≡ -m deepseek,haiku); last:N = the newest N rows per task

# an A/B arm (a pack sentence or a tool default changes only after one — evals/ab/README.md is the recipe):
# tag the rows, run the other arm under a committed prompt variant, read each arm back
arnes eval evals/basics -m deepseek/deepseek-v4-flash --label control
ARNES_PACKS_DIR=evals/ab/packs-no-s6 arnes eval evals/basics -m deepseek/deepseek-v4-flash --label s6-out
arnes evals show --label s6-out

# panel: fan one task to N models in isolated snapshots, judge picks, winner lands here
arnes do "make the greeting configurable" --panel 3 --yes \
  -m anthropic/claude-sonnet-5,openai/gpt-5.6-luna,deepseek/deepseek-v4 \
  --judge anthropic/claude-sonnet-5    # --no-apply keeps the winner in its snapshot
# every candidate becomes a labeled eval row — real work grows the eval history for free
# --effort <level> runs every candidate with the reasoning dial (the judge's request stays dial-less)
# a panel only when the verifier says FAIL: the failed attempt is kept, the tree reverted to a pre-run
# snapshot, a panel of N runs over it, the winner is applied and re-verified, exit code = that verdict
arnes do "make the tests pass" --verify anthropic/claude-haiku-4.5 --yes --panel-on-fail 2 \
  -m deepseek/deepseek-v4,anthropic/claude-sonnet-5   # or `policies.panelOnVerifierFail: 2` in the config
```

Evals append to `~/.arnes/evals.jsonl` (and feed the `runs` scoreboard). A task is one
JSON file — prompt + optional bash `setup` + a bash `check` whose exit code is the ground
truth — so adding your own suite is trivial. Three optional keys refine a pass without ever
replacing the check: a `rubric` (criteria a judge model scores from the task, the agent's
report, the diff of the workdir and the check's verdict — never the transcript; `--judge
<model>`, else the provider's default, else the candidate itself with a `self-grading`
warning), `limits` (`maxSteps`/`maxCostUSD` cap the run, `maxToolCalls`,
`forbiddenTools`/`requiredTools` are read from the record; `gate` decides whether they
fail the trial) and `verify: true` (the loop-1 verifier with `--verify <model>`, recorded —
judged over the same workdir diff the rubric judge reads, and scored against the check in
`arnes evals`' `verifier` column).
Every trial's transcript is kept under `~/.arnes/eval-sessions/` — `arnes evals transcript
<id>` prints one — unless `--no-transcripts`; see `evals/graded/`. For CI, `--parallel N`
runs N trials at once (each has its own workdir, tools and session), `--min-pass 0…1` exits
2 when any model falls under it, `--compare last|last:N|<N>d` sets each task against its own history
(a task at ≥ 80% before and < 50% now is a regression, the reverse a fix; `--fail-on-regression`
exits 2 on one), `--effort`/`--budget` set every trial's reasoning dial and cost ceiling, and
`--json` prints one document (models with pass@k / pass^k, regressions, fixes, every outcome,
the gate, the exit code, and `collapsed_models` — the models a repeated `-m` collapsed to one run)
with progress on stderr; in text mode every progress line is flushed as it prints, so a redirected
log keeps them if the run dies. For an A/B, `--label <arm>` tags every row of
a run with an arm name (`arnes evals show --label <arm>` reads it back), `--adaptive-think` is
the arm for `policies.adaptiveThink` (no `think` tool for a model that reasons natively under
`--effort` — on by default since the 2026-09-03 A/B, `policies.adaptiveThink: false` keeps the
tool), and `ARNES_PACKS_DIR=<dir>` runs under another packs directory — `evals/ab/` holds the
committed prompt variants (`packs-think-tool` and `packs-no-s6`, each a `base.md` that replaces
the base prompt; `packs-delegate-wide`, a `## Delegation` override per family), the recipe and
the recorded results; `evals/safety` is the prompt-injection probe and
`evals/subagents` the delegation one, whose checks read the trial's own `ARNES_SESSION_ID`.
You don't even have to write tasks by hand:

```bash
# watched the agent fumble something? distill that session into a reusable test
arnes evals capture                          # from the most recent session
arnes evals capture --session <id> --hint "focus on the regex it got wrong"
arnes evals capture --task "find the max in numbers.txt and append max=<n> in place"
arnes evals capture --split                  # auto-slice: one task per user turn, chit-chat
                                             # skipped, follow-up turns made self-contained
# ✔ captured append-max-to-file → evals/captured/append-max-to-file.json
#   (validated: setup succeeds, check FAILS pre-work — a check that already passes tests nothing;
#    validation RUNS the writer's bash, so you're shown the scripts and asked first — --yes skips that)
arnes eval evals/captured -m deepseek/deepseek-v4-flash    # rerun it forever

# see the history, visually — pass-rate bars per suite × model × dialect
arnes evals
# basics   anthropic/claude-haiku-4.5   messages  ████████████ 8/8 (100%)  $0.0501  08-24 12:30
#          openai/gpt-4o-mini           chat      ███████████░ 7/8 (87%)   $0.0033  08-24 12:31
arnes evals show --suite basics --model haiku --days 7     # filters (--task <id>, --label <arm> too)
arnes evals show --json                                    # {type: evals, rows: [{suite, model, dialect, trials, passed, pass_rate, cost_usd, last_run}]}

# read a trial's trajectory (kept under ~/.arnes/eval-sessions by `arnes eval`)
arnes evals transcript                       # list them: id · when · model · suite/task ✓|✗
arnes evals transcript 3f9a                  # one, as markdown (session id, prefix, or run-id prefix)
arnes evals transcript --json [3f9a]         # as data: {type: eval_transcripts, rows: [...]} — or one {type: eval_transcript, …, entries: [the JSONL lines as stored]}

# trim the history (a removed row's transcript goes with it)
arnes evals prune --older-than 30            # rows older than 30 days
arnes evals prune --suite panel              # one suite
arnes evals prune --label s6-out             # one A/B arm
arnes evals prune --all
``` For the industry benchmark,
`benchmarks/terminal-bench/` has a [Harbor](https://www.harborframework.com) adapter to run
Arnes on [Terminal-Bench](https://www.tbench.ai) — the same harness used to score Claude
Code and Codex CLI — with `ARNES_MODEL` selecting the model per run.

## Code review

`arnes review` reads a diff and reports correctness defects as structured findings — a
reviewer that cannot be talked into anything by the code it reviews:

```bash
arnes review                                   # uncommitted changes: staged + unstaged + untracked
arnes review --base origin/main --fail-on high # a pull request against main; exit 2 on a high finding
arnes review --commit abc1234 --focus "the retry logic"
arnes review --base main --json                # one JSON document for scripts
```

The reviewer is **read-only by construction**: `read_file`, `grep`, `glob`, `think`, and `bash`
for read-only commands (`git log`, `git blame`), with every mutation refused — and nothing the
repository ships (no MCP servers, skills, subagents, hooks or instruction files), so a change
cannot inject into its own review. Every string in the diff is data to it; a line that addresses
the reviewer is itself a finding. `--allow-run` lets it run tests and builds, and needs the OS
sandbox (refused where the platform can't enforce one). The diff is built with the repository's
`diff.external`/`textconv`/`fsmonitor` pinned off (and every `git` the reviewer runs itself
inherits the same pins), untracked files are pasted only when they are regular text under 256 KB
that `read_file` would read freely — a symlink is never read through, a credential location or a
`paths.denyRead` match is named and skipped — and only while the diff has room, and the run is
tagged `agent: review` in the scoreboard. Findings come back as `{file, line, severity, category, summary,
failure_scenario, confidence}` validated against a fixed schema; text mode groups them high →
medium → low, `--json` prints them as one document, and the exit code says the rest: 0 clean ·
1 error · **2 a finding at or above `--fail-on`** · 3 the reviewer stopped short · 64 usage.
`.github/workflows/arnes-review.yml` is a CI recipe that posts the findings as an untrusted PR
comment and fails the job only on exit 2.

## Providers & gateways

Arnes talks to OpenRouter by default. The same loop — tools, permission gating, evals,
panels, scoreboards — also runs against a **LiteLLM proxy** (or a gateway fronting one)
or a plain OpenAI-compatible endpoint. Providers live in `~/.arnes/config.json`
(`ARNES_CONFIG` overrides the path):

```json
{
  "provider": "gateway",
  "providers": {
    "gateway": {
      "kind": "litellm",
      "baseURL": "https://llm-gateway.example.com/v1",
      "apiKeyEnv": "GATEWAY_TOKEN",
      "headersEnv": "GATEWAY_HEADERS",
      "defaultModel": "claude-sonnet-4-5"
    }
  }
}
```

```bash
arnes providers                          # the table, which entry is active, whether each resolves (offline)
arnes --provider gateway                 # pick one for a run (or: ARNES_PROVIDER=gateway)
arnes status                             # key/budget + manifest size for the active provider (and whether it came from the cache)
arnes models claude --supports tools     # the gateway's manifest (capabilities from /model/info)
arnes models --refresh                   # refetch it now; otherwise the copy under ~/.arnes/models serves for 24 h
arnes do "..." -m sonnet --fallback haiku     # fallbacks become LiteLLM's per-request `fallbacks`
```

- `kind` is `openrouter`, `litellm`, or `openai-compatible`; `baseURL` is the API root
  *including the version segment* (`https://openrouter.ai/api/v1`, `https://host/v1`).
- The token comes from `apiKeyEnv` (default per kind: `OPENROUTER_API_KEY`,
  `LITELLM_API_KEY`, `OPENAI_API_KEY`), a literal `apiKey`, or a `NAME=value` line in
  `~/.arnes/credentials` — one line per provider; OpenRouter's bare key still works.
- Short-lived tokens (IAP/OIDC, an hour at a time): set `"apiKeyCommand": "iap-auth"`
  (or `gcloud auth print-identity-token`, a vault CLI) instead of a static key. Arnes runs
  it, caches the token, and re-runs it a minute before a JWT's `exp` (50 minutes for
  opaque tokens) — the `apiKeyHelper` idea, so long sessions never send a stale token.
  Any static source (`apiKey`, the env variable, the credentials file) still wins when set.
- Extra headers: static `headers`, plus `headersEnv` naming a variable holding one
  `Name: value` per line (the `ANTHROPIC_CUSTOM_HEADERS` convention, so a gateway's
  headers can feed Arnes and Claude Code from one place). Header values may use
  `${SOME_ENV_VAR}` and `${UUID}` (one fresh id per run — handy for tracing headers).
- `defaultModel` is what runs when `-m` is omitted — set it once you've seen
  `arnes models --provider <name>` (until then, pass `-m`). A LiteLLM *model group*
  alias is the natural choice: that's where the gateway's own routing (deployments,
  fallbacks, load balancing) lives, the way `openrouter/auto` does on OpenRouter. `-m`
  still picks per run and `/model` fuzzy-searches the gateway's manifest.
- `aliases` is your own routing table: `{"haiku": "claude-haiku-4-5-20251001", "sonnet": "…"}`
  makes `-m haiku`, `/model haiku`, `/agents explore haiku`, `model: haiku` in agent files,
  and a subagent request for "haiku" all land on the exact id — essential on a gateway
  with no manifest to fuzzy-match against, and an explicit alias beats a fuzzy match
  everywhere. `defaultModel` may be an alias too.
- `bashJudge` (optional) names a cheap/fast model — an id or one of your `aliases`, a free
  model is the point — that gives a second opinion on shell commands **already headed for a
  permission prompt**. It's a safety *escalation* on top of the deterministic classifiers,
  never a replacement: it can flag a command (its reason rides the interactive prompt; in
  headless `--yes` it vetoes the command outright) but can never approve one Arnes already
  blocks, and if it errors or times out the deterministic decision stands. Off unless set.
  It is also the default model for **prompt hooks** — a `hooks.json` entry with
  `"type": "prompt"` and a `"prompt"` (with `$ARGUMENTS` standing for the event JSON) asks a
  model instead of running a command, under the same rules: it may `BLOCK: reason` or
  `ASK: reason`, never allow, rewrite or end the turn; an error or an unreadable reply is a
  notice, not a verdict; verdicts are cached per payload (a failure is asked again); the spend
  lands in the turn's cost.
  `"model"` on the hook picks another model; `arnes hooks` shows what each would run on.
- `sandbox` (optional) OS-confines the tools that can change your machine — the real
  containment behind the string-level classifiers and the judge. `{"enabled": true}` runs
  every `bash` command under a macOS `sandbox-exec` profile that keeps **file writes inside
  the working tree + `--add-dir` roots + temp**, keeps `.github/workflows`, `.arnes`, `.claude`
  and — in a directory that already is a git repository — `.git/hooks` and `.git/config`
  read-only *inside* the tree (`git init` in an empty directory still works, and committing in
  an existing repo never touches either), makes the working
  root itself un-deletable, and makes credential locations (`~/.ssh`, `~/.aws`, …) unreadable;
  `"network": false` cuts off the network, `"writable": ["~/.npm"]` grants extra paths a build
  needs, `"denyRead": ["/etc/secret"]` adds more unreadable paths (paths, not globs — a glob
  belongs in the top-level `paths.denyRead`). `write_file` and `edit_file` never touch a shell,
  so they check the same boundary in-process and refuse with `error: sandbox denies write to
  <path>`. A destructive command that slips past the other layers still can't reach `~/.ssh`,
  `/etc`, or anything outside the project.
  **Unattended runs are confined by default** where the platform can enforce it — `arnes do
  --yes`, `--panel`, and `arnes eval` — since nobody is watching them; `--no-sandbox` opts out
  with a warning, and an explicit `"enabled": false` is honored. Interactive sessions stay
  opt-in, because confinement breaks commands that legitimately write outside the tree.
  **Fail-closed**: if the platform can't enforce it (Linux isn't wired yet), commands refuse to
  run rather than run unconfined — `"failIfUnavailable": false` trades that for a warning, and
  only for interactive runs. The banner shows `sandbox` / `sandbox no-net` when it's on.
- `reasoningShape` (optional) says how a **chat** request to this entry spells the reasoning
  dial (`--effort`, `/effort`): `"openai"` — OpenAI's top-level `reasoning_effort: "<level>"`
  string, what LiteLLM (which translates it, for Anthropic into a `thinking` budget) and
  OpenAI-compatible servers accept, and the default for both kinds; `"openrouter"` — OpenRouter's
  `reasoning: {"effort": …}` object, its own default, which a LiteLLM gateway refuses with
  `400 reasoning: Extra inputs are not permitted`; `"none"` — the endpoint takes neither, so no
  chat request carries the dial. The level rides verbatim in either spelling; `/messages` and
  `/responses` use their own APIs' shapes whatever this says. `arnes providers --json` shows the
  resolved `reasoning_shape` per entry, and `arnes probe <model> --effort medium --dialect chat`
  checks that the gateway takes it.
- One-run overrides: `ARNES_BASE_URL`, `ARNES_API_KEY`, `ARNES_DEFAULT_MODEL`. Plain
  `http://` is refused except to localhost unless the entry sets `"insecure": true` —
  the token rides every request. The session banner names the provider and host.

What changes behind a LiteLLM gateway: the manifest comes from `/model/info` (tool
support, reasoning, context size, per-token prices — `/v1/models` when it's hidden, with
tools assumed on); fallbacks ride the request's `fallbacks` list; cost is **estimated**
from `usage` × manifest prices (`$0` when the manifest has no prices) rather than read
off the response; native `/messages` and `/responses` dialects are still tried first
(`"nativeDialects": false` pins everything to chat), and a broken endpoint falls back
to chat and is remembered exactly as on OpenRouter — while a wire failure (a 429 storm, a
5xx run) only cools the native route for 15 minutes, never a week, and a gateway that rejects
`cache_control` gets the request re-sent once without it; the reasoning dial rides a chat request
as OpenAI's `reasoning_effort` string (the `reasoningShape` key above), not OpenRouter's object. On every provider the fetched
manifest is cached under `~/.arnes/models/<provider>.json` and served from there for 24 hours
(`policies.manifestCache: {ttlHours, enabled}`), a model the copy doesn't know costs one
refetch, and a manifest outage falls back to the cached copy with a warning instead of
degrading every model to "unknown". Every row in `~/.arnes/runs.jsonl`
records the provider, so `arnes runs` never mixes routers. OpenRouter-only features
(`openrouter/auto`, provider preferences, ZDR, credit balance) are simply absent
elsewhere. With no config file nothing changes: OpenRouter with `OPENROUTER_API_KEY`.

## Permissions & trust

The model drives tools; the user holds the gates.

- **Mutations ask.** `bash`, `write_file`, `edit_file`, and MCP tools (unless the server
  marks them read-only) prompt in the REPL. So do **reads outside the working
  directory** and reads of credential paths (`~/.ssh`, `~/.aws`, `~/.arnes/credentials`,
  …) — the prompt says which. Reads inside the project run freely — including
  *obviously read-only shell commands*: `git status`/`log`/`diff`/`show`, `ls`, `cat`,
  `head`, `grep`, `find` and friends with in-tree relative paths, no redirection, no `$`
  or backticks. Anything the classifier isn't sure about asks (`git push`, `echo x > f`,
  `cat ~/.ssh/id_rsa`, `find -delete`, `swift build`).
- **Headless is read-only by default.** `arnes do` denies gated calls and tells the
  model why; pass `--yes` (`-y`) to auto-approve, `--safe` for an explicit read-only run.
  `--panel` requires `--yes` (candidates run unattended), and so does `--panel-on-fail N`
  (a panel only after a `--verify` FAIL; refused with `--panel`, `--no-apply`, `--safe`,
  `--add-dir`, a resumed session or the lead-shape flags). `arnes eval` keeps
  auto-approving — every trial lives in a throwaway temp directory.
- **`--yes` means "don't ask about the task", not "do anything".** It auto-approves
  ordinary work *inside* the working directory. A `read_file`/`write_file`/`edit_file`/
  `grep`/`glob` call on a path outside it — or on a credential, shell-startup or protected
  path — stays denied, with the reason pointing at the fix: **`--add-dir <path>`**
  (repeatable, on `arnes do` and the REPL) makes another directory count as inside, so
  widening a run is something you type rather than something `--yes` implies.
- **The harness's own files are never tool-writable.** `write_file`/`edit_file` refuse
  anything under `~/.arnes/` (and whatever `ARNES_CONFIG`/`ARNES_HOOKS_CONFIG`/
  `ARNES_MCP_CONFIG`/`ARNES_RULES_CONFIG` point at) inside the tool itself, before any
  permission decision — so no mode, rule, hook or `--yes` lets an agent rewrite the
  guardrails it runs under. Edit them yourself.
- **You can add your own touchy paths.** A top-level `"paths"` block in
  `~/.arnes/config.json` extends the built-in classification (it can only tighten):
  `{"paths": {"protected": ["deploy/**"], "sensitiveWrite": ["~/Library/LaunchDaemons/**"],
  "denyRead": ["**/.env*", "**/*.pem"]}}`. `arnes status` prints what is active.
- **Project files are the repository's, not yours.** `.arnes/` and `.claude/` skills and
  agents in the working directory add text to the system prompt and define subagents
  (prompt, tools, model). The REPL asks once per directory — `[y]es and remember ·
  [o]nce · [n]o` — and headless runs skip them until the directory is trusted
  (`arnes trust`, `--trust-project`, `arnes trust --list/--forget`;
  stored in `~/.arnes/trusted.json`). Your own `~/.arnes/` definitions never need trust —
  nor do your Claude Code ones: `~/.claude/skills` and `~/.claude/agents` are read as-is
  after `~/.arnes/skills`/`~/.arnes/agents` (an Arnes file of the same name shadows a
  drop-in; `arnes skills`/`arnes agents` show where each came from). Discovery order, first
  name wins: `./.arnes/`, `./.claude/`, `~/.arnes/`, `~/.claude/`, then the built-ins. An
  agent file's `skills: a, b` preloads those skills' bodies into the subagent's prompt
  (32 KB cap); a skill file's `allowed-tools`/`model` are parsed and listed, not applied.
- **Typing doesn't answer prompts.** A permission prompt that opens mid-sentence keeps
  routing keys to the input box until you pause for a second, so a `y` in "yes, and…"
  never approves a command.
- **Model-written scripts are shown first.** `arnes evals capture` validates drafts by
  running their `setup`/`check`; interactively you see them and confirm, piped runs need
  `--yes`.
- **Shell commands can't hang the turn.** `bash` runs with stdin closed, stops waiting
  when bash exits (a background child holding the pipe — a telemetry `curl`, a dev
  server — no longer blocks), is killed after `timeout_seconds` (the call's own, up to 600;
  else `limits.bashTimeoutSeconds`, 5 minutes by default) **with its whole process tree**, and
  dies with Ctrl-C/Esc. Long work runs detached: `bash … background: true` returns a job id at
  once, the `job` tool polls, waits for or kills it (its output lands in a private log that is
  read back only while it is still the file arnes created — a job that swaps its log for a link
  to a secret or a FIFO gets a refusal, not a read), a
  finished job is announced to the model before its next request, `/tasks` lists them — and
  every job dies with the session that started it (exit, `/resume`, `/fork`, `/clear`, the end
  of an `arnes do`, the end of a subagent's turn).
- **Secrets stay put.** Everything under `~/.arnes` is created owner-only (0700/0600),
  `arnes` warns when `credentials`/`config.json` are readable by others, and MCP server
  processes never inherit the provider token (pass it on purpose with
  `"env": {"GATEWAY_TOKEN": "${GATEWAY_TOKEN}"}` in `mcp.json`). `bash` commands and hooks
  don't inherit it either — `arnes status` prints exactly what they do inherit.
- **Tool results are data, not instructions.** Everything a tool returns — a file, a command's
  output, an MCP result, a subagent's report — passes one guard on its way into the model's
  context: vendor-shaped secrets (`sk-…`, `ghp_…`, `AKIA…`, a PEM block, a JWT, a
  `TOKEN=…` assignment) are redacted to `[REDACTED:<kind>:<last4>]` before anything is stored
  (the transcript on disk never holds a key, pasted by you or read by the model); content
  shaped like instructions — a `Human:`/`System:` line, a chat-template token, a forged
  `<tool_result` tag, "ignore previous instructions" — is flagged with a one-line notice the
  model reads (`⚠ flagged: read_file result matched … — treated as data` for you); in the CLI
  every result is framed in `<tool_result source=… nonce=…>` tags with a per-session nonce the
  system prompt never carries (`"policies": {"toolResultFraming": false}` turns the frame off).
  A flag **taints** the session: from then on a network-reaching `bash` command (`curl`,
  `git push`, `pip install`, `gh`, …), any interpreter or substitution the classifier cannot see
  through (`sh -c`, `python3 …`, `xargs`, `$(…)`) and every irreversible or out-of-tree call
  prompt loudly with the source named, and `--yes` refuses them — read untrusted files in one
  run, act in another. An MCP server you mark `"trust": "untrusted"` in `mcp.json` taints on every result
  and its read-only claims are ignored; every server's tool definitions are pinned by hash on
  first sight, and a tool whose description changes later is withheld until you read it and
  `arnes mcp --approve <server>`. `arnes trust` covers a directory's subdirectories up to the
  repository root, never its neighbors and never your home directory; `arnes trust --show`
  says what a directory defines and through which trust decision it loads.

## MCP servers

Drop a config at `~/.arnes/mcp.json` — the same `mcpServers` shape Claude Desktop and
Claude Code use, so an existing config copies verbatim — and every server's tools join the
loop in both the REPL and `arnes do`:

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
    },
    "docs": {
      "type": "http",
      "url": "https://mcp.example.com/mcp",
      "headers": {"Authorization": "Bearer ${DOCS_TOKEN}"},
      "required": true,
      "toolTimeoutSeconds": 60
    }
  }
}
```

```bash
arnes mcp          # connect the configured servers and list their tools (no API key needed)
# filesystem · stdio npx -y @modelcontextprotocol/server-filesystem /tmp · 11 tools
#   mcp__filesystem__read_file   [read-only]   Read the complete contents of a file...
#   mcp__filesystem__write_file  [mutating]    Create or overwrite a file...
# docs · http mcp.example.com · 4 tools · 1 prompts [required]
```

- Tools surface to the model as `mcp__<server>__<tool>`, schemas passed through untouched.
- MCP tools are **mutating by default** — the REPL prompts y/a/n and `--safe` denies them —
  unless the server annotates `readOnlyHint`, which lets them run freely like `grep`
  (`destructiveHint`/`openWorldHint` make them `.sensitive` instead: the louder prompt).
- Two transports: **stdio** (arnes launches `command` and speaks JSON-RPC over its pipes)
  and **streamable HTTP** (`url`, or `"type": "http"`) — each message is POSTed and the
  reply comes back as JSON or SSE, with the server's session id carried across requests.
  `https` is required unless the host is loopback or the entry sets `"insecure": true`, and
  a redirect to another host is never followed (the headers hold your token).
- `${NAME}` in `headers` (and `env`) expands from the environment, so tokens stay out of
  the file, and `arnes mcp` never prints a header value or a URL path.
- Per server: `"required": true` (a failure stops `arnes do` with exit 1 instead of letting
  the model improvise), `"enabled": false`, `"startupTimeoutSeconds"` (30),
  `"toolTimeoutSeconds"` (120), and an optional `"maxResultChars"` inner bound.
- Oversized results are handled like every other tool's: the session keeps the head and
  the tail (`limits.toolResultChars`, 30000 by default) and writes the whole result
  owner-only under `~/.arnes/tmp/<session>/`; the reply names the path, so the model pages
  it with `read_file` instead of flooding the context (that directory is the only one under
  `~/.arnes` the model may read, and only its own session's). An explicit `maxResultChars` cuts a
  chatty server's results below that cap before the session sees them.
- Server **prompts** are yours, not the model's: `/mcp__<server>__<prompt> [args]` in the
  REPL runs one as a turn.
- No config file simply means MCP is off; `--no-mcp` skips connecting for one run;
  `--mcp-config <path|inline json>` picks a config for this run (merging over the home file,
  `--strict-mcp-config` to ignore it), and `ARNES_MCP_CONFIG=./mcp.json` still works.
- Panels never load MCP tools: candidates run in isolated snapshots, and a shared server
  would leak side effects between them.

### Setting servers up from the CLI

```bash
arnes mcp add filesystem -- npx -y @modelcontextprotocol/server-filesystem /tmp     # stdio: the command after --
arnes mcp add docs --url https://mcp.example.com/mcp \
  --header 'Authorization: Bearer ${DOCS_TOKEN}'                                     # http; ${VAR} stays a template
arnes mcp add repo-tools --scope project -- ./tools/mcp.sh                          # the repository's .mcp.json
arnes mcp add-json docs '{"type": "http", "url": "https://mcp.example.com/mcp"}'    # a raw entry, validated the same way
arnes mcp get docs          # one entry as arnes uses it — templates verbatim, literals as <set>, never a URL path
arnes mcp list              # every entry across the scopes this directory loads (offline)
arnes mcp remove docs       # user scope first, then the project's; the server's tool pins are forgotten
```

- The verbs are offline and edit the file as a JSON tree, so keys arnes doesn't model survive
  (key order does not — the file is rewritten sorted and pretty-printed, 0600 in a 0700
  directory). `arnes mcp` alone is still the connecting status view; `get`/`list` take `--json`.
- **Secrets never land in the file as literals.** An `--env` or `--header` value that looks
  like one — a credential header name such as `Authorization` or `X-Api-Key`, or a vendor-shaped
  token, JWT, PEM block or `TOKEN=…` assignment — is refused with the `${NAME}` to write
  instead; `--allow-literal` writes it anyway (0600, this machine only). Names must match
  `[A-Za-z0-9][A-Za-z0-9_-]{0,63}` with no `__` (the tool-name separator); a `url` goes through
  the same policy as a connect; a stdio command not on PATH is only a warning.
- **A repository's own servers** live in `<repo root>/.mcp.json` (Claude Code's file; `--scope
  project` writes it 0600 — `chmod 644` before committing). arnes loads it **only in a trusted
  directory** (`arnes trust`, or `--trust-project` headless; never under `--bare` or
  `--strict-mcp-config`) and always as `trust: untrusted`: every result taints the session and
  the server's read-only claims are ignored, whatever the file says. A project entry can't be
  `required` (a clone must not be able to fail every run) and never overrides a user entry of
  the same name — both are said out loud. The trust prompt, the headless skip notice and
  `arnes trust --show` list the servers a repository declares (`mcp: <name> (stdio …)`), and
  `arnes doctor` checks the file with every finding a warning.
- **`/mcp`** in the REPL shows what the session connected to — one row per server with tool and
  prompt counts, failures with their error, `[required]`/`[untrusted]`/`[N withheld]` tags, the
  config files in play and how to add one; `/mcp <server>` lists its tools, withheld tools and
  prompts. Information only: the toolset is fixed when a session starts, so a config change
  takes effect in the next one.

## Driving Arnes from an agent

The repo ships a Claude Code skill at [`.claude/skills/arnes/`](.claude/skills/arnes/SKILL.md)
that teaches an agent the whole CLI surface — "arnes run evals", "panel this task",
"probe a model" — including cost-conscious model defaults and how to read the scoreboards.
It loads automatically for sessions inside this repo; to use it from anywhere:

```bash
ln -s "$(pwd)/.claude/skills/arnes" ~/.claude/skills/arnes
```

## What's inside

- **`ArnesKit`** (embeddable, UI-free): the `Session` actor (streaming agent loop, permission
  gating, interrupts), capability manifest (`ModelCatalog`), per-family prompt packs
  (user-overridable at `~/.arnes/packs/<family>.md`; a `## Delegation` section there replaces
  the built-in when-to-delegate guidance, which rides the prompt only while subagents are
  available; a `base.md` beside them replaces the base prompt itself, and `ARNES_PACKS_DIR`
  points a run at another packs directory — the seam an A/B runs a variant through), ten built-in tools — eleven with a configured `web_fetch` — plus any MCP server's
  (`~/.arnes/mcp.json`), session transcripts (`~/.arnes/sessions/`), and the `RunRecord`
  eval substrate (`~/.arnes/runs.jsonl`). `edit_file` edits one file in several places in one
  call — an `edits` array of `{old_string, new_string, replace_all?}` applied in order and
  written once, so a failing edit writes nothing — at one prompt, one checkpoint and one step.
- **Clarifying questions without leaving the turn**: one dumb `ask_user` tool (a question and up
  to five options) answered through a `UserInputDelegate` the embedder binds — the REPL asks at
  the prompt, serialized with permission prompts and capped at three per turn; headless runs
  (`arnes do`, panels, evals) answer "no user is present" and the model is told to pick the most
  reasonable option and state the assumption. Subagents never have it.
- **Tools the model is offered depend on the model** (`CapabilityGatedTool`, decided once per
  request from the manifest): `view_image` lets a vision model *look at* a screenshot, diagram or
  mockup (PNG/JPEG/GIF/WEBP ≤ 5 MB; the image rides the conversation as content, the transcript
  keeps a `[image attached: …]` sentinel; path-gated like `read_file`) and is simply absent for a
  model whose manifest doesn't list `image` among its input modalities — an unknown model
  counts as text-only, the one capability assumed *off*. `web_fetch` reads a public https page
  as text, only when `~/.arnes/config.json` has a top-level `web` block: hosts in
  `allowedDomains` are fetched freely, `deniedDomains` never, every other host is a loud
  `.sensitive` prompt that `--yes` refuses — no default allowlist, no private addresses (names
  and literals alike, judged by what they resolve to), same-host redirects only. A page is data
  under the untrusted-content scanner like any result: instruction-shaped text on it taints the
  session, and after any taint every fetch — allowlisted or not — is the human-only prompt.
  Approving a fetch of a host *outside* the allowlist at the prompt taints the session too
  (source `web:<host>`): that approval is one call's consent, not a trust declaration. Off
  entirely under a `network: false` sandbox.
- **`arnes`** (CLI): `interactive` (default) · `chat` · `do` · `resume` · `models` · `status`
  · `providers` · `runs` · `sessions` · `eval` · `evals` · `probe` · `mcp` · `skills` · `agents`
  · `hooks` · `trust` · `doctor` · `debug` · `review`.
- Built on [OpenRouterSwift](https://github.com/jamesrochabrun/OpenRouterSwift) — usage cost
  tracked per request, model fallbacks on every call.
- **Routing visibility**: every response reports the model that actually served it
  (`response.model` post-routing); run records keep the requested → served mapping.
- **Stateless by design**: OpenRouter holds no conversation state; history lives client-side
  in the `Session` — which is exactly what makes mid-conversation `/model` swaps possible.
- **The model knows where it is**: every system prompt carries an `# Environment` block
  (working directory, platform, date, git branch/status/recent commits, model, permission
  mode, sandbox, effort) captured once per session — the way Claude Code and Codex do it —
  so a smaller model's first steps aren't `pwd`, `uname` and `git status`. Subagents, eval
  trials and panel candidates get their own. The git probe is treated like any other shell
  the run starts: it runs inside the run's OS sandbox, and the repository's own `.git/config`
  can't make it execute anything (`core.fsmonitor` and `log.showSignature` are pinned off).
  Opt out with `"policies": {"environmentContext": false}` in `~/.arnes/config.json`.
- **Tool-loop hygiene at one chokepoint**: every tool result — bash, MCP, grep, a subagent's
  report — passes one cap on its way into history (30000 chars, head 60 % + tail 40 %, so a
  failing build's last lines survive), with the full text spilled owner-only to
  `~/.arnes/tmp/<session>/` and a pointer the model can `read_file` — the one place under
  `~/.arnes` it may read, and only its own session's directory, never another's. `bash`
  output is bounded in memory as it streams (`yes | head -c 20000000` costs what `echo`
  costs). A call with malformed or incomplete arguments, or an unknown tool name, gets a
  coaching error instead of a run. And a **loop guard** stops a model going in circles: one
  `[arnes]` nudge after 3 failures in a row, 3 identical calls or 8 edits to one file, then
  `stuck` (exit 3 headless) when the same call fails 6 times, 6 calls fail in a row, or 8
  edits to one file fail in a turn — successful work never trips it. All under `"limits"` in
  `~/.arnes/config.json`.
- **Dialect-native transport**: Anthropic models run on `/messages` and OpenAI models on
  `/responses` (chat-completions for everyone else) — chosen per model automatically, forced
  with `--dialect` for A/Bs. History stays chat-shaped internally and is translated per
  request, so `/model` swaps work *across* dialects mid-conversation. On the starter suite,
  claude-haiku-4.5 native vs chat: same 8/8 pass, −15% cost, −11% steps, −14% time.
  Conformance is self-checking: clean native runs record an ok verdict, a misbehaving
  native endpoint falls back to chat mid-turn and is remembered (`~/.arnes/dialects.jsonl`,
  failures retried after 7 days) — `arnes probe <model>` checks a model explicitly, and
  `--effort <level>` on it also checks the reasoning round-trip: a thinking model's signed
  `thinking` blocks (`/messages`) or encrypted reasoning items (`/responses`) are carried on
  the assistant message and replayed on the next request of a tool loop, so `--effort` no
  longer breaks the loop (a thinking-shape refusal is recorded as `category: thinking` and
  never pins the model to chat); `--dialect chat` probes the floor itself — the same round-trip
  forced onto chat completions, the dial in the provider's `reasoningShape` spelling — and
  records no verdict, since chat is what auto selection falls back to and is never pinned.
- **Transport resilience**: a request the wire refused **before any output token** — a 429
  (its `Retry-After` honored), a 5xx, an overloaded or timed-out provider, a lost connection, a
  stream that broke or went silent for 5 minutes — is retried with jittered exponential
  backoff (4 request retries, 5 stream retries, 60 s of waiting at most per step; `retrying` on
  the event stream, `retries` on the run record), on the same dialect: a rate limit is not a
  dialect verdict, so it never pins a native endpoint to chat (nor does a connection that drops
  mid-answer). Anything after the model started answering, and every 4xx — on the HTTP layer or
  relayed mid-stream as a 4xx-coded error event —, is never retried. A reply cut off at the output-token limit
  is a `truncated` event: a tool call cut mid-arguments is dropped before it can enter history,
  whole calls before it run, the model is told once to continue shorter, and a second cutoff
  ends the turn with `stop_reason: truncated` (exit 3) with the partial text kept. Tune under
  `"policies": {"transport": {…}}` in `~/.arnes/config.json` (`0` switches a budget or the idle
  timeout off).
- **Prompt-cache discipline**: the system prompt and tool definitions are a stable prefix every
  step re-sends, kept byte-identical within a session by construction (reminders ride user
  messages, no clock in the prompt, a fixed tool list; only a compaction or a `/model`, `/effort`,
  `/permissions` change rebuilds it, at a turn boundary). On the Anthropic family — where the
  provider takes the field (OpenRouter, LiteLLM; never a generic OpenAI-compatible endpoint) —
  requests mark that prefix with `cache_control` breakpoints (the system text and the last
  message on chat completions, the last tool and the last block on `/messages`), and every
  dialect measures what a request read from the cache: `cachedTokens` on the run record, a
  ` · cache N%` footer segment when something was cached, a `cache=N%` column on `arnes runs`
  when some run cached anything, `cached_tokens` on the `do --output-format json` envelope,
  `cached_prompt_tokens` on the `turn_finished` event and a `cache` row in `/status`. `"policies": {"promptCache": {"anthropicBreakpoints": false,
  "ttl": "1h"}}` switches the breakpoints off or sets the TTL.
- **Context budget**: a request carries a *view* of the conversation — tool results older than
  the last 6 and larger than 2000 chars reach the model as one `[arnes: cleared <tool> result
  (N chars) … call the tool again if you need it]` line (an `error:` keeps its first line), while
  the session's history and the transcript keep the real results and no message is ever dropped.
  The stubs move only at a turn's start and at a mid-turn relief point, so a turn's requests share
  one stable prefix; at turn start clearing runs before the summarizer, which is asked only when
  clearing alone won't bring the window under the threshold; mid-turn a step that reports a full
  window clears more, and when the window is estimated to stay at 95 % after that clearing the
  turn's own exchanges are summarized into the note (twice per turn at most, then a
  `context_warning`; the hint on a stub is what the tool allows — nothing to re-call for a `task`
  report or an `ask_user` answer). The summarizer
  is told to keep the files touched, the verifying commands, the unresolved errors and the
  current `update_plan` checklist verbatim, and a project's `## Compact instructions` steer it.
  Tune under top-level `"compaction": {"threshold", "keepRecentToolResults", "clearMinChars",
  "maxPerTurn", "keepRecentImages"}` (the last: `view_image` pictures older than the kept results
  are replaced by their caption plus a recall hint, all but the newest one — a screenshot stops
  riding every later request); `/compact [model] [instructions]` steers one summary by hand. The
  REPL also re-reads the project's `MEMORY.md` at every turn start, so a note the model saves
  reaches the next turn's system prompt.

## Status

v0.4 — eval lifecycle tooling (`arnes evals` history/capture/prune, `capture --split`
session slicing), on top of v0.3's dialect-native execution (`/messages`, `/responses`,
per-model auto + `--dialect`), `--panel N` (parallel candidates, judge, labeled eval rows),
eval framework (`arnes eval`, bash checks as ground truth), and CI (macOS + Linux) with
static Linux release binaries and a Terminal-Bench/Harbor adapter — all over v0.2's
interactive REPL (permission gating, mid-session `/model` swap, persistence + resume,
coding tools, context compaction) and the v0.1 loop (inline verification, run records).

Unreleased since v0.4.1 (on `feat/p1-hardening`): a large harness-parity effort against the
Claude Code and Codex playbooks — MCP servers (stdio + streamable HTTP), the two orthogonal
safety axes (an OS sandbox crossed with a permission policy: path gates, a catastrophic-bash
floor, rules + modes, an audit trail, env scrubbing, an optional command judge), subagents
(a `task` tool = nested `Session` with lineage, parallel + background delegation, snapshot/fork
isolation, persisted transcripts + resume), the canonical primitives (project instructions,
`update_plan`/`think`/`ask_user`, the `# Environment` block, structured output, skills v2,
tool-loop hygiene), lifecycle hooks at every point, dialect-native transport with the reasoning
round-trip, the headless run contract (`RunResult`, `--output-format`, exit codes) with parity
flags on `do`, `--json` on every listing, `arnes doctor` / `debug prompt` / `review`, eval
graders (rubric/limits/verifier) and CI gates (`--parallel`, `--min-pass`, `--compare`,
pass@k), untrusted-content framing/redaction/taint, file checkpoints (`/rewind`, `/diff`), and
auto-memory (`~/.arnes/memory/<project>/MEMORY.md` as a `# Memory` section, edited through the
file tools across a narrow carve-out of the `~/.arnes` floor; `arnes memory`, `/memory`).
the REPL's dials and introspection (`/context`, a richer `/status`, `/btw`, `/effort`, `/thinking`,
`/budget`, the plan pinned as it updates), context-budget microcompaction (a request carries a
*view* of the conversation with old tool results stubbed, the persisted history untouched — with
mid-turn relief and `/compact` steering), prompt-cache discipline (`cache_control` breakpoints on
the Anthropic-family stable prefix with a cached-token metric on every dialect), transport
resilience (jittered retries of a request that failed before any output token, a stream idle
timeout, and the output-limit cutoff handled), bash v2 (`timeout_seconds`, a process-tree kill,
`background: true` jobs behind a `job` tool that die with their session), and capability-gated
tools (`view_image` for vision models, `web_fetch` under `URLPolicy.strict`, model-adaptive `think`
omission), then panel policy triggers (`--panel-on-fail`) and cached model profiles. Next:
scoreboard-driven routing defaults, gated pack-improvement proposals, a Linux sandbox backend. The full record is the `## Status` list
in [INSTRUCTIONS.md](INSTRUCTIONS.md); the roadmap is in [DESIGN.md](DESIGN.md).
