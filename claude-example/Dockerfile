# syntax=docker/dockerfile:1
#
# agent-smith + Claude Code as a Docker Sandbox template.
#
# Everything runs INSIDE the sandbox microVM: Claude Code, the pentest-agent MCP
# server, the sandbox's own dockerd, and the tool containers it spawns. Nothing
# reaches the host Docker socket — which is the whole point. See
# docs/production-isolation.md:56-77 in the agent-smith repo for why a VM with
# its own dockerd is the sanctioned boundary and a Smith container sharing the
# host socket is not.
#
# Build:  ./build.sh
# Run:    sbx run --template docker.io/<org>/smith-sandbox:<tag> --publish 7777:7777 claude
#
# NOTE: this image deliberately does NOT run agent-smith's installers/install.sh.
# That script targets host installs across three agent clients and three OSes; it
# hard-fails on Linux at its launchd block (no OS guard + `set -euo pipefail`),
# aborting before skills are installed. The five steps that actually matter in a
# container are inlined below and in smith-entrypoint.

ARG SANDBOX_TEMPLATE=docker/sandbox-templates:claude-code-docker-0.5.0
FROM ${SANDBOX_TEMPLATE}

# ---------------------------------------------------------------------------
# What the base image already gives us (read from its registry config, so we
# don't reinstall any of it):
#   Ubuntu 26.04 (glibc) · USER agent uid 1000 · ENTRYPOINT ["tini","--"]
#   CMD ["claude","--dangerously-skip-permissions"]
#   docker-ce + containerd.io + docker-buildx + golang + JDK + bubblewrap
#   uv at /usr/local/bin/uv · the claude CLI · agent is in the docker+sudo groups
#   LABEL com.docker.sandboxes.start-docker=true  <- how sbx knows to start dockerd
#   NO_PROXY=localhost,127.0.0.1,::1,172.17.0.0/16 <- loopback + docker bridge
#                                                     bypass the egress proxy
# ---------------------------------------------------------------------------

ARG SMITH_REPO=https://github.com/0x0pointer/agent-smith.git
# Pin the commit, not a branch — matches the repo's own supply-chain posture.
ARG SMITH_REF=921c6cde7c62146ae75171dfb3e83459a2a58314
# 3.11 is what CI tests (.github/workflows/ci.yml) and what pyproject.toml's
# `python = "^3.11"` floor was validated against. Do NOT fall back to whatever
# python3 Ubuntu 26.04 happens to ship.
ARG PYTHON_VERSION=3.11
# Same version CI pins.
ARG POETRY_VERSION=2.1.3
# Optional extras, off by default to keep the image small.
ARG INCLUDE_WEASYPRINT=0
ARG INCLUDE_MERMAID_CLI=0

# Fixed, system-wide locations so nothing we need lives under /home/agent, which
# the sandbox may back with a persistent volume that would shadow baked content.
ENV UV_PYTHON_INSTALL_DIR=/opt/uv-python \
    UV_TOOL_DIR=/opt/uv-tools \
    UV_TOOL_BIN_DIR=/usr/local/bin \
    SMITH_HOME=/opt/agent-smith \
    SMITH_IMAGES_DIR=/opt/smith-images \
    SMITH_MCP_PORT=7778 \
    TMPDIR=/opt/agent-smith/.tmp

USER root

# git is the only apt package we need; everything else is already present.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# WeasyPrint is what the /report skill shells out to (skills/reporting/report/
# SKILL.md calls it the only supported PDF engine). It needs pango/cairo, hence
# opt-in rather than baked in for everyone.
# NOTE weasyprint goes into the SYSTEM python3, not the Poetry venv: the skill
# shells out to plain `python3` (skills/reporting/report/SKILL.md:112), so
# installing it into .venv would leave the skill still broken.
RUN if [ "$INCLUDE_WEASYPRINT" = "1" ]; then \
        apt-get update \
        && apt-get install -y --no-install-recommends \
             python3 python3-pip libpango-1.0-0 libpangoft2-1.0-0 libharfbuzz0b \
             libcairo2 libgdk-pixbuf-2.0-0 libffi8 \
        && pip3 install --break-system-packages --no-cache-dir weasyprint \
        && python3 -c "import weasyprint; print('[build] weasyprint', weasyprint.__version__)" \
        && rm -rf /var/lib/apt/lists/*; \
    else echo "[build] weasyprint skipped (INCLUDE_WEASYPRINT=0)"; fi

# Server-side Mermaid pre-render. Optional because it drags in Chromium; without
# it core/api_server/mermaid.py falls back to client-side rendering.
RUN if [ "$INCLUDE_MERMAID_CLI" = "1" ]; then \
        npm install -g @mermaid-js/mermaid-cli; \
    else echo "[build] mermaid-cli skipped (INCLUDE_MERMAID_CLI=0)"; fi

# The interpreter and Poetry, both at fixed system paths.
RUN uv python install "${PYTHON_VERSION}" \
    && uv tool install "poetry==${POETRY_VERSION}" \
    && poetry --version

# agent-smith itself, at a pinned commit, with the skills submodule.
# Both 0x0pointer/agent-smith and 0x0pointer/skills are public, so no
# credentials and no BuildKit secret are needed.
RUN git clone --recursive "${SMITH_REPO}" "${SMITH_HOME}" \
    && git -C "${SMITH_HOME}" checkout --quiet "${SMITH_REF}" \
    && git -C "${SMITH_HOME}" submodule update --init --recursive \
    && test -f "${SMITH_HOME}/skills/pentester.md" \
    && echo "[build] agent-smith at $(git -C "${SMITH_HOME}" rev-parse --short HEAD), $(find "${SMITH_HOME}/skills" -mindepth 2 -maxdepth 3 -name SKILL.md | wc -l) skills present"

# The repo ROOT must be writable by uid 1000: core/store.py:44 writes
# session.json / findings.json / coverage_matrix.json and friends atomically via
# mkstemp(dir=<same dir>), so a read-only root breaks every scan.
# .tmp is deliberately disk-backed and inside the repo: /tmp in a microVM is
# usually tmpfs (RAM), and tools/sandbox_runner.py:102 stages up to 512 MB there
# per exec_sandbox call (_MAX_STAGE_BYTES at :35), which would OOM the VM.
RUN mkdir -p "${SMITH_HOME}/logs" "${SMITH_HOME}/artifacts" "${SMITH_HOME}/pocs" \
              "${SMITH_HOME}/.tmp" \
    && chown -R 1000:1000 "${SMITH_HOME}"

# Baked MCP registration. This is how Claude Code learns about the server
# WITHOUT touching ~/.claude.json, which Docker documents as sandbox-managed and
# off-limits. Consumed via the --mcp-config flag in CMD below.
RUN printf '%s\n' \
    '{' \
    '  "mcpServers": {' \
    '    "pentest-agent": {' \
    '      "type": "sse",' \
    '      "url": "http://127.0.0.1:7778/sse"' \
    '    }' \
    '  }' \
    '}' > "${SMITH_HOME}/.mcp.json" \
    && chown 1000:1000 "${SMITH_HOME}/.mcp.json"

# Pre-baked tool images (Kali + scanners) as tarballs produced by build.sh.
# Copying the whole directory rather than a glob so the image still builds with
# an empty images/ dir — the entrypoint simply finds nothing to load.
COPY images/ ${SMITH_IMAGES_DIR}/

COPY --chmod=0755 smith-entrypoint /usr/local/bin/smith-entrypoint

USER agent

# In-project venv: installers/run-mcp-server.sh resolves the interpreter with
# `poetry env info --executable`, and Poetry's default venv path is HOME-derived
# (~/.cache/pypoetry). Putting it at /opt/agent-smith/.venv keeps it off
# /home/agent, so a sandbox-managed home volume cannot shadow it — and lets the
# entrypoint hardcode the interpreter path instead of shelling out to poetry.
ENV POETRY_VIRTUALENVS_IN_PROJECT=true \
    POETRY_NO_INTERACTION=1
WORKDIR ${SMITH_HOME}
RUN poetry env use "$(uv python find "${PYTHON_VERSION}")" \
    && poetry install --only main \
    && .venv/bin/python -V

# Build-time smoke test — same assertion installers/run-mcp-server.sh:77-102
# makes, so a broken image fails the build instead of failing on first use.
RUN PYTHONPATH="${SMITH_HOME}" .venv/bin/python - <<'PY'
import importlib

for module in (
    "mcp_server.scan_tools",
    "mcp_server.kali_tools",
    "mcp_server.http_tools",
    "mcp_server.report_tools",
    "mcp_server.session_tools",
):
    importlib.import_module(module)

from mcp_server._app import mcp

expected = {"scan", "kali", "http", "report", "session"}
actual = {tool.name for tool in mcp._tool_manager.list_tools()}
missing, extra = sorted(expected - actual), sorted(actual - expected)
if missing or extra:
    raise SystemExit(f"MCP tool registration mismatch. missing={missing} extra={extra}")
print("[build] MCP self-test OK: " + ", ".join(sorted(actual)))
PY

# A comments-only .env, mode 600. Counter-intuitive but load-bearing:
# mcp_server/_app.py:244-245 returns EARLY when .env is absent, which skips the
# AITEST_ANTHROPIC_API_KEY -> ANTHROPIC_API_KEY remap at :262-264. So with no
# .env at all, passing AITEST_ANTHROPIC_API_KEY via `sbx run -e` would never
# reach the server-side consumers. A file with only comments makes os.path.isfile
# true while setting nothing (the parser skips '#' and lines without '=' at
# :249), so real values still arrive from the environment and nothing is
# clobbered by a blank.
RUN printf '%s\n' \
    '# Managed by the sbx template - intentionally sets NOTHING.' \
    '# Real values arrive via `sbx secret set` / `sbx run -e VAR=...`.' \
    '# Do not add KEY=value lines here: .env OVERRIDES the inherited' \
    '# environment (mcp_server/_app.py:255), so a blank would win.' \
    > "${SMITH_HOME}/.env" \
    && chmod 600 "${SMITH_HOME}/.env"

# Merge two keys into the repo's existing .claude/settings.json (it already ships
# a SessionStart hook + an allow-list, so this must merge, not overwrite):
#   permissions.allow += mcp__pentest-agent__*   (what install.sh:351-371 does)
#   enableAllProjectMcpServers = true            (so the watchdog's headless
#     respawn gets the MCP server: core/api_server/smith/spawn.py:220-253 never
#     passes --mcp-config, and the child's cwd is the repo root, so its only
#     source is this project-scoped config - and `-p` cannot answer an approval
#     prompt.)
RUN .venv/bin/python - <<'PY'
import json, pathlib
p = pathlib.Path("/opt/agent-smith/.claude/settings.json")
data = json.loads(p.read_text()) if p.exists() else {}
allow = data.setdefault("permissions", {}).setdefault("allow", [])
if "mcp__pentest-agent__*" not in allow:
    allow.append("mcp__pentest-agent__*")
data["enableAllProjectMcpServers"] = True
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(data, indent=2) + "\n")
print("[build] settings.json merged:", sorted(data))
PY

# The dashboard binds core/api_server/serve.py:133's DASHBOARD_HOST, default
# 127.0.0.1, which `sbx --publish` cannot forward. 0.0.0.0 is a reasonable
# default inside a single-tenant microVM, and /api/* stays gated by the bearer
# token in logs/dashboard.token. Override with -e DASHBOARD_HOST=127.0.0.1.
ENV DASHBOARD_HOST=0.0.0.0

# Back to the base image's working directory; sbx overrides this with the
# mounted workspace at run time, and the entrypoint captures it for
# PENTEST_TARGET_PATH.
WORKDIR /home/agent/workspace

# tini stays PID 1 (inherited from the base); our script sets up the sandbox and
# then execs CMD, so `claude` remains the foreground process.
ENTRYPOINT ["tini", "--", "/usr/local/bin/smith-entrypoint"]
# --add-dir /opt/agent-smith: the workspace is the TARGET codebase, but the
# skills read findings.json / coverage_matrix.json from agent-smith's repo root
# (core/paths.py:29-38), which is outside the workspace tree.
CMD ["claude", "--dangerously-skip-permissions", \
     "--mcp-config", "/opt/agent-smith/.mcp.json", \
     "--add-dir", "/opt/agent-smith"]
