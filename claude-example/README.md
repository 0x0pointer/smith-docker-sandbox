# agent-smith in a Docker Sandbox

A distributable [Docker Sandbox](https://docs.docker.com/ai/sandboxes/) template that runs
**Claude Code + agent-smith + its tool containers entirely inside a microVM**. Hand someone one
tar file and they have a working pentest environment — no Python, no Poetry, no agent-smith
checkout, no image builds on their machine.

```
┌─ your Mac ──────────────────────────────────────────────────────┐
│  sbx microVM ─────────────────────────────────────────────────┐ │
│   claude ──(SSE 127.0.0.1:7778)──► pentest-agent MCP server   │ │
│                                          │ docker CLI          │ │
│                        sandbox-local dockerd                   │ │
│                          ├── pentest-kali (127.0.0.1:5001)     │ │
│                          └── nmap / httpx / nuclei / semgrep …  │ │
│   dashboard :7777 ─────────────────────────────► published      │ │
│  └──────────────────────────────────────────────────────────────┘ │
│   all outbound TCP → host proxy → only allow-listed hosts        │
└──────────────────────────────────────────────────────────────────┘
```

**Why a sandbox and not a container.** agent-smith's own
`docs/production-isolation.md:56-77` argues that mounting the host Docker socket into a Smith
container is *less safe than a bare install* — any code-exec inside Smith escapes with
`docker run -v /:/host --privileged`. Its prescription is a VM running its own dockerd. That is
exactly what a Docker Sandbox is, so this template is that guidance packaged, not a shortcut
around it. Note also that Docker's MCP gateway (`sbx mcp add`) runs local MCP servers **on the
host**; we deliberately bypass it so nothing of Smith touches your machine.

## Quick start (consuming a prebuilt template)

```bash
brew trust docker/tap && brew install docker/tap/sbx    # macOS Sonoma 14+, Apple silicon
sbx login
sbx secret set anthropic                                # or use /login inside Claude Code

sbx policy init balanced                                # ONE TIME per machine: creates the
                                                        # policy store. Without it, every
                                                        # `policy allow` returns 412.
sbx template load smith-sandbox-local.tar

sbx policy allow network app.example.com                # ← the engagement scope. Required.
cd ~/code/target-app                                    # the codebase under test
sbx run claude --template smith-sandbox:local \
        --kit ~/Desktop/smith-docker-sandbox/kit \
        --publish 7777:7777
```

**The `--kit` is required, not optional.** `sbx` launches the agent itself and does not use the
template image's `ENTRYPOINT`/`CMD`, so nothing in the image starts the MCP server on its own. The
kit's `setup.startup` runs the bring-up (`/usr/local/bin/smith-entrypoint`) and blocks until the
server is listening, then `sbx` starts Claude Code. Without it you get a session with no pentest
tools — which looks like the model refusing to use them rather than like an error.

`--kit` only takes effect when a sandbox is **created**. To add it to a sandbox that already
exists, either `sbx kit add <sandbox> ~/Desktop/smith-docker-sandbox/kit` (this restarts it), or
run the bring-up by hand and restart the agent:

```bash
sbx exec <sandbox> -- /usr/local/bin/smith-entrypoint   # idempotent; exits when MCP is up
```

Inside the session, `/mcp` should list `pentest-agent` with five tools
(`scan`, `kali`, `http`, `report`, `session`). Then `/pentester https://app.example.com`.

## Building it

```bash
./build.sh                                    # → smith-sandbox-*.tar  (for sbx template load)
./build.sh --push docker.io/myorg/smith:v1     # → registry instead
./build.sh --repo ~/Desktop/agent-smith        # build Kali from a local checkout
./build.sh --with-metasploit                   # + Metasploit (~2.6 GB)
./build.sh --with-weasyprint                   # PDF output for /report
./build.sh --skip-tool-images                  # small template, pulls tools at runtime
```

Needs Docker and about 25 minutes on a first run (most of it the Kali build). It is re-runnable:
already-saved tarballs and the cached agent-smith clone are reused.

`build.sh` exists because a plain `docker build` cannot run Docker during a build, so the tool
images can't be baked as layers. Instead it builds/pulls them, `docker save`s them beside the
Dockerfile, and the template `COPY`s the tarballs in; `smith-entrypoint` loads them into the
sandbox's own daemon on first start.

`build.sh` pulls the scanner images **by the exact reference the code uses**, extracted from
`tools/*.py` at build time. They are digest-pinned there, and `docker image inspect <ref>`
(`tools/docker_runner.py:16-18`) is what decides whether agent-smith pulls at runtime — pulling
the bare tags that `installers/install.sh` pre-pulls would produce tarballs that don't actually
prevent a runtime pull.

## Size and disk — read this before you build

The Kali image with `core + web` is **~10 GB uncompressed**, measured by layer attribution on a
real build. (`docs/installation.md:199` claims ~3 GB; that number is stale.)

| | |
|---|---|
| Base sandbox template | ~0.7 GB compressed |
| Kali `core+web` tarball | ~3.5–4 GB |
| 7 scanners + `python:3.11-slim` | ~0.5 GB |
| **Template tar you distribute** | **~5 GB** |
| Sandbox disk after first start | **~20–25 GB** (tarballs *and* their loaded copies) |

You pay for the tool images twice: once as tarballs inside the image (which cannot be reclaimed —
deleting a file from a lower overlay layer only writes a whiteout) and once expanded into the
sandbox's `/var/lib/docker`. That is the cost of "one file, works offline". If disk is tight, use
`--skip-tool-images` and let the sandbox pull them, or push Kali to a registry and pull it inside.

## What works here, and what does not

The sandbox's network model is not negotiable, and the failure modes are **silent** — a
proxy-refused connection looks exactly like "the target is down".

| Constraint | Consequence |
|---|---|
| **UDP and ICMP are blocked at the network layer and cannot be re-enabled by policy** | No ping/fping/traceroute/`nmap -sn`/hping3/arp-scan. No UDP scans. |
| All outbound TCP is proxied through the host | Raw SYN scans don't work. Use `flags='-Pn -sT -n'` for nmap, `flags='-scan-type c'` for naabu, and treat port-scan results as low confidence. |
| Egress is deny-by-default | Every target needs `sbx policy allow network <host>` first. |
| No inbound connectivity | Reverse shells, chisel/ligolo tunnels, Kali's file-transfer port and Metasploit handlers are unreachable from outside. OAST/interactsh still works (outbound only). |
| Built `core + web` only | netexec, impacket, hydra, medusa, smbmap, enum4linux-ng, bloodhound, responder, chisel, ligolo are **not installed**. |

**In scope:** `/web-exploit`, `/api-security`, `/param-fuzz`, `/business-logic`,
`/oauth-security`, `/saml-sso`, `/ssl-tls-audit`, `/codebase`, `/supply-chain`, `/analyze-cve`,
`/aikido-triage`, `/ai-redteam` against a remote endpoint, `/osint` (partially — most passive
sources are blocked).

**Out of scope:** `/ad-assessment`, `/lateral-movement`, `/network-assess`,
`/credential-audit` brute-force phases, `/reverse-shell`, `/post-exploit` pivoting.

The entrypoint writes this contract to `~/.claude/CLAUDE.md` inside the sandbox so the agent knows
its own limits — in particular that a blocked connection is **not** evidence of a clean result and
must never close a coverage cell.

## Running more than one sandbox

`sbx` names a sandbox after the workspace directory, so re-running from the same directory
**re-attaches** to the existing one — and `--template`, `--kit` and `--publish` are only honoured
when a sandbox is created. Name them per engagement instead:

```bash
sbx run claude --name smith-acme \
    --template smith-sandbox:local \
    --kit ~/Desktop/smith-docker-sandbox/kit \
    --publish 7776:7777 \
    ~/code/acme-app
```

Note the port mapping is `host:sandbox` and the dashboard is always **7777 inside** the sandbox —
so a second sandbox is `7776:7777`, not `7776:7776`.

```bash
sbx ls                                      # what exists
sbx run --name smith-acme                   # re-attach (no --template/--publish)
sbx ports smith-acme --publish 7776:7777    # add a port after the fact
sbx stop smith-acme ; sbx rm smith-acme
sbx prune --dry-run
```

Two things that bite when running several:

**Policy rules are global unless scoped.** Adding a target for one engagement makes it reachable
from every sandbox. Scope them so each sandbox's reachable surface equals its own authorization:

```bash
sbx policy allow network acme.example.com --sandbox smith-acme
sbx policy ls --wide
```

**Sandboxes share no images.** Each has its own Docker daemon and image cache, so the baked tool
images cost their full ~20 GB *per sandbox* (see the size table). `sbx rm` finished engagements.

## Engagement scope

The allow-list is the scope, and it is enforced rather than promised. The global policy must be
initialized once before any rule can be added — otherwise `policy allow` fails with
`412 Precondition Failed: global network policy has not been initialized`:

```bash
sbx policy init balanced   # default-deny + a baseline allow-list (AI APIs, package
                           # managers, code hosts, container registries). What you want.
# sbx policy init allow-all  # no egress restriction at all
# sbx policy init deny-all   # blocks EVERYTHING, including api.anthropic.com — this
                           # breaks Claude Code itself. Don't.
```

```bash
sbx policy allow network app.example.com          # exact host
sbx policy allow network '*.staging.example.com'  # wildcard
sbx policy allow network 10.1.2.3:8443            # host:port
sbx policy check  network app.example.com         # test a rule
sbx policy ls                                     # what is currently allowed
```

Targets are never baked into the image. If you want the pre-`sbx` behaviour of unrestricted
egress, `sbx policy init allow-all` — but then you lose the containment that makes this worth
using. (The docs describe the presets as "Open / Balanced / Locked Down"; the CLI values are
`allow-all` / `balanced` / `deny-all`.)

## Dashboard

The agent starts it on `report(action='dashboard')`; before that the port is legitimately dead.
The image sets `DASHBOARD_HOST=0.0.0.0` because `sbx --publish` cannot forward to a
loopback-only listener (`core/api_server/serve.py:133` defaults to `127.0.0.1`).

```bash
sbx exec <sandbox> -- cat /opt/agent-smith/logs/dashboard.token
open "http://localhost:7777/#k=<token>"
```

Two caveats: `/api/*` is only token-gated **once a scan has minted the token**
(`core/api_server/__init__.py:106`), so before the first scan the dashboard is open to anything
that can reach the published port — confirm `sbx --publish` binds your host's loopback, not
`0.0.0.0`. And never set `SMITH_DASHBOARD_AUTH=0`.

## Useful environment variables

```bash
sbx run -e AITEST_ANTHROPIC_API_KEY=sk-ant-…  \  # AI red-team tooling (NOT the agent's own key)
        -e OPENAI_API_KEY=sk-…                \
        -e SMITH_SPAWN_USE_API_KEY=1          \  # needed if you auth via `sbx secret set anthropic`
        -e SMITH_WATCHDOG_DISABLED=1          \  # stop unattended respawns while validating
        --template smith-sandbox:local --publish 7777:7777 claude
```

`SMITH_SPAWN_USE_API_KEY=1` matters: the watchdog's respawn strips `ANTHROPIC_API_KEY` from the
child unless it is set (`core/api_server/smith/spawn.py:272-276`), so with API-key auth the
respawn would launch with no credential. If you authenticate with `/login` instead, ignore it.

The image ships a **comments-only `.env`**. That is deliberate: `mcp_server/_app.py:244-245`
returns early when `.env` is absent, skipping the `AITEST_ANTHROPIC_API_KEY → ANTHROPIC_API_KEY`
remap at `:262-264`. A comments-only file makes the remap run while setting nothing — and since
`.env` values *override* the inherited environment (`:255`), it must stay empty of `KEY=value`
lines or it would clobber what you pass on the command line.

## Troubleshooting

**`/mcp` shows no `pentest-agent`, or `claude` starts with no tools.** First check you passed
`--kit` at sandbox creation — without it nothing starts the MCP server, because `sbx` ignores the
image's `ENTRYPOINT`/`CMD`. Recover an already-running sandbox with:

```bash
sbx exec <sandbox> -- /usr/local/bin/smith-entrypoint    # then restart the claude session
```

If the kit did run, the bring-up waits up to 45 s for the server and logs loudly if it gives up:
```bash
sbx exec <sandbox> -- tail -40 /opt/agent-smith/logs/mcp_sse.log
sbx exec <sandbox> -- sh -c 'PYTHONPATH=/opt/agent-smith /opt/agent-smith/.venv/bin/python -c "import mcp_server"'
```

**`kali()` returns "docker run failed".** Almost always `/dev/net/tun`, which
`tools/kali_runner.py:141` requires unconditionally. The entrypoint tries to create it; check:
```bash
sbx exec <sandbox> -- sh -c 'ls -l /dev/net/tun || sudo modprobe tun'
```
If Kali starts but every hostname inside it fails to resolve, the nested bridge network can't
reach the sandbox's DNS (UDP is blocked). Workaround — run Kali on the sandbox's own network
namespace instead, which the MCP will then adopt because `ensure_running()` short-circuits on an
already-running container (`tools/kali_runner.py:112`):
```bash
sbx exec <sandbox> -- docker run -d --name pentest-kali --network=host \
  --cap-add=NET_RAW --cap-add=NET_ADMIN \
  -v /opt/agent-smith/tools/kali/api_guard.py:/usr/local/bin/kali-api-guard:ro \
  -e KALI_API_TOKEN="$(cat /opt/agent-smith/logs/.kali_api_token)" \
  -e KALI_UPSTREAM_PORT=5555 -e KALI_GUARD_PORT=5001 \
  pentest-agent/kali-mcp \
  sh -c 'kali-server-mcp --ip 127.0.0.1 --port 5555 & exec python3 /usr/local/bin/kali-api-guard'
```
Set `SMITH_KEEP_CONTAINERS=1` so scan completion doesn't stop it (`core/session/lifecycle.py:186`).

**Scans return nothing.** Check the policy before believing the result:
`sbx policy check network <target>`.

**nuclei finds nothing on the first run.** `tools/nuclei.py:37,48` mounts
`~/.nuclei-templates` and always passes `-ut`, so on a fresh sandbox the template
directory is empty and nuclei downloads it from GitHub — which the egress policy
blocks, leaving you with zero findings that look like a clean scan. Either allow
the fetch once:
```bash
sbx policy allow network github.com
sbx policy allow network raw.githubusercontent.com
sbx policy allow network objects.githubusercontent.com
```
or pre-seed the directory from the host with `sbx cp`. Treat any nuclei run whose
template count is zero as not-run, never as clean.

**Digest-pinned images "reloaded" but tools still try to pull.** `docker load` of a
digest-only reference restores RepoTags only on a classic overlay2 daemon, so the
exact ref becomes unresolvable. `build.sh` therefore also tags each pinned image
`smith-baked/<name>:pinned-<short>`, and the entrypoint repoints the source
literal at that tag when it detects the loss — look for `repinned …` in its
output. `smith-entrypoint` reports counts as
`N present, N loaded, N repinned, N unavailable`; anything in `unavailable` will
be pulled at runtime and needs registry egress.

**`no space left on device`.** See the size table. `sbx rm` old sandboxes; they don't share images.

## What this deliberately does not use

`installers/` — all ~166 KB of it. It covers host installs for three agent clients across three
OSes, plus launchd/systemd supervisors, a port-change utility and uninstallers. In a container we
control the environment, so five steps survive (clone, `poetry install`, skills, `.mcp.json`,
launch) and they are inlined in the `Dockerfile` and `smith-entrypoint`. `install.sh` would in fact
*fail* here: it has no OS guard and aborts under `set -euo pipefail` at its launchd block, before
skills are installed. `run-mcp-server.sh` is skipped too — its only real job is discovering the
Poetry venv interpreter, and this image pins it at `/opt/agent-smith/.venv/bin/python`.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | The template. Clones agent-smith at a pinned SHA, provisions Python 3.11 + Poetry, installs deps, bakes `.mcp.json`, runs a build-time MCP self-test. |
| `smith-entrypoint` | Runs on every start: ensure `/dev/net/tun`, wait for dockerd, `docker load` missing tool images, install the 35 skills, write the capability contract, start the MCP server, wait for it, then `exec claude`. |
| `build.sh` | Builds Kali `core+web`, pulls the exact scanner refs, saves tarballs, builds the template, emits a loadable tar or pushes. |
| `kit/spec.yaml` | The `sbx` mixin kit. Creates `/dev/net/tun`, runs the bring-up blocking on MCP readiness, sets env, declares the egress allow-list and denies cloud metadata, and gives the agent its capability contract. |
| `images/` | Build output (gitignored) plus `manifest.txt` mapping each exact image ref to its tarball. |
