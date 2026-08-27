#!/usr/bin/env bash
#
# build.sh — produce the agent-smith sandbox template.
#
# Why this script has to exist at all: a plain `docker build` cannot run Docker
# during the build, so the tool images (Kali + scanners) can't be baked as
# layers. Instead we build/pull them here, `docker save` them next to the
# Dockerfile, and the template COPYs the tarballs in; smith-entrypoint loads
# them into the sandbox's own daemon on first start.
#
# Output (default): smith-sandbox-<tag>.tar  ->  `sbx template load` it.
# With --push:      pushes to a registry instead.
#
# Usage:
#   ./build.sh                                  # build + save the template tar
#   ./build.sh --push docker.io/myorg/smith-sandbox:v1
#   ./build.sh --repo ~/Desktop/agent-smith     # use a local checkout
#   ./build.sh --with-metasploit                # + pentest-agent/metasploit (~2.6GB)
#   ./build.sh --with-weasyprint --with-mermaid # PDF reports / server-side diagrams
#   ./build.sh --platform linux/amd64           # cross-build (default: host arch)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# ── defaults ────────────────────────────────────────────────────────────────
SMITH_REPO_URL="https://github.com/0x0pointer/agent-smith.git"
SMITH_REF="921c6cde7c62146ae75171dfb3e83459a2a58314"
SANDBOX_TEMPLATE="docker/sandbox-templates:claude-code-docker-0.5.0"
TEMPLATE_TAG="smith-sandbox:local"
LOCAL_REPO=""
PUSH_REF=""
PLATFORM=""
WITH_METASPLOIT=0
WITH_WEASYPRINT=0
WITH_MERMAID=0
SKIP_TOOL_IMAGES=0

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
die()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }
step() { echo; echo -e "${GREEN}==>${NC} $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --push)             PUSH_REF="${2:?--push needs a registry ref}"; shift 2 ;;
        --tag)              TEMPLATE_TAG="${2:?--tag needs a value}"; shift 2 ;;
        --repo)             LOCAL_REPO="${2:?--repo needs a path}"; shift 2 ;;
        --ref)              SMITH_REF="${2:?--ref needs a commit}"; shift 2 ;;
        --base)             SANDBOX_TEMPLATE="${2:?--base needs an image}"; shift 2 ;;
        --platform)         PLATFORM="${2:?--platform needs a value}"; shift 2 ;;
        --with-metasploit)  WITH_METASPLOIT=1; shift ;;
        --with-weasyprint)  WITH_WEASYPRINT=1; shift ;;
        --with-mermaid)     WITH_MERMAID=1; shift ;;
        --skip-tool-images) SKIP_TOOL_IMAGES=1; shift ;;
        -h|--help)          sed -n '2,25p' "$0"; exit 0 ;;
        *)                  die "unknown argument: $1" ;;
    esac
done

[ -n "$PUSH_REF" ] && TEMPLATE_TAG="$PUSH_REF"

command -v docker >/dev/null 2>&1 || die "docker not found — this script needs a working Docker daemon."
docker info >/dev/null 2>&1 || die "docker daemon not reachable. Start Docker and retry."

# ── run a docker command with the full log kept on disk ─────────────────────
# Same shape as agent-smith's own installer helper: never hide the real error
# behind a truncated tail. Foreground pipeline so the exit status is docker's.
_progress() {
    if [ -t 1 ]; then
        awk '/^#[0-9]+ \[[ 0-9]*[0-9]+\/[0-9]+\]/ { printf "\r\033[K    %.100s", $0; fflush() }
             END { printf "\r\033[K" }'
    else
        cat
    fi
}

_logged() {  # $1=label  $2..=command
    local label="$1"; shift
    local log
    log="$(mktemp "${TMPDIR:-/tmp}/smith-sandbox-build-XXXXXX")"
    if "$@" 2>&1 | tee "$log" | _progress; then
        rm -f "$log"
        return 0
    fi
    warn "$label FAILED. Full log: $log"
    if [ -t 1 ] && [ -s "$log" ]; then
        echo "    ---------------- last 60 log lines ----------------"
        tail -60 "$log" | sed 's/^/    /'
        echo "    ---------------------------------------------------"
    fi
    die "$label failed"
}

# NOTE on array expansions below: macOS ships bash 3.2.57, where expanding an
# EMPTY array as "${arr[@]}" is an unbound-variable error under `set -u` (bash
# fixed that in 4.4). Every expansion here therefore uses the portable
# ${arr[@]+"${arr[@]}"} form. Same reason there is no `mapfile` in this script.
PLATFORM_ARGS=()
[ -n "$PLATFORM" ] && PLATFORM_ARGS=(--platform "$PLATFORM")

# ── 1. the agent-smith checkout (only needed for the Kali build context) ────
step "agent-smith source"
if [ -n "$LOCAL_REPO" ]; then
    REPO="$(cd "$LOCAL_REPO" && pwd)"
    [ -f "$REPO/tools/kali/Dockerfile" ] || die "$REPO does not look like an agent-smith checkout"
    ok "using local checkout: $REPO"
    warn "building Kali from your working tree, not the pinned commit $SMITH_REF"
else
    REPO="$HERE/.build-cache/agent-smith"
    if [ -d "$REPO/.git" ]; then
        git -C "$REPO" fetch --quiet origin || warn "fetch failed; using the cached clone"
    else
        mkdir -p "$(dirname "$REPO")"
        _logged "clone agent-smith" git clone --quiet "$SMITH_REPO_URL" "$REPO"
    fi
    git -C "$REPO" checkout --quiet "$SMITH_REF" || die "commit $SMITH_REF not found"
    git -C "$REPO" submodule update --init --recursive --quiet
    ok "pinned checkout at $(git -C "$REPO" rev-parse --short HEAD)"
fi

# ── 2. tool images ──────────────────────────────────────────────────────────
mkdir -p images
MANIFEST="images/manifest.txt"

if [ "$SKIP_TOOL_IMAGES" = "1" ]; then
    warn "--skip-tool-images: the template will pull tool images at runtime"
    : > "$MANIFEST"
else
    step "Kali image (core + web)"
    # INSTALL_INFRA defaults to 1 in the Kali Dockerfile, so it must be turned
    # OFF explicitly. The tag must be exactly what tools/kali_runner.py:20 uses.
    _logged "kali build" docker build ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} \
        --build-arg INSTALL_WEB=1 \
        --build-arg INSTALL_INFRA=0 \
        --build-arg INSTALL_MOBILE=0 \
        --build-arg INSTALL_CLOUD=0 \
        --build-arg INSTALL_AI=0 \
        -t pentest-agent/kali-mcp \
        "$REPO/tools/kali/"
    ok "pentest-agent/kali-mcp built"

    REFS=("pentest-agent/kali-mcp")

    if [ "$WITH_METASPLOIT" = "1" ]; then
        step "Metasploit image"
        _logged "metasploit build" docker build ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} \
            -t pentest-agent/metasploit "$REPO/tools/metasploit/"
        REFS+=("pentest-agent/metasploit")
        ok "pentest-agent/metasploit built"
    fi

    # Scanner images, read straight out of the tool definitions rather than
    # hand-listed. These are DIGEST-pinned in the code (e.g. tools/nmap.py:27),
    # and `docker image inspect <ref>` (tools/docker_runner.py:16-18) is what
    # decides whether agent-smith pulls at runtime — so we must bake the exact
    # reference, not the bare tag that installers/install.sh pre-pulls.
    step "scanner images (exact refs from the source)"
    SCANNER_REFS=()
    while IFS= read -r _ref_line; do
        [ -n "$_ref_line" ] && SCANNER_REFS+=("$_ref_line")
    done < <(
        grep -hoE '"[a-z0-9][a-z0-9._/-]*(@sha256:[a-f0-9]{64}|:[a-zA-Z0-9._-]+)"' \
            "$REPO"/tools/nmap.py \
            "$REPO"/tools/naabu.py \
            "$REPO"/tools/httpx.py \
            "$REPO"/tools/nuclei.py \
            "$REPO"/tools/subfinder.py \
            "$REPO"/tools/semgrep.py \
            "$REPO"/tools/trufflehog.py \
        | tr -d '"' \
        | grep -E '^(instrumentisto/nmap|projectdiscovery/(naabu|httpx|nuclei|subfinder)|semgrep/semgrep|trufflesecurity/trufflehog)' \
        | sort -u
    )
    [ "${#SCANNER_REFS[@]}" -ge 7 ] \
        || die "expected 7 scanner refs, extracted ${#SCANNER_REFS[@]} — the tool definitions moved; fix the grep above"
    # exec_sandbox's default image (tools/sandbox_runner.py:37). Baked because the
    # RCE-confirmation gate (mcp_server/report_tools/gates.py) effectively
    # obligates exec_sandbox, and it is only ~50 MB.
    SCANNER_REFS+=("python:3.11-slim")

    for ref in ${SCANNER_REFS[@]+"${SCANNER_REFS[@]}"}; do
        echo "    pulling $ref"
        _logged "pull $ref" docker pull --quiet ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} "$ref"
        # A wrong-arch image is worse than a missing one: it loads fine and then
        # fails at run time with "exec format error", and a microVM's dockerd has
        # no qemu/binfmt fallback.
        img_arch="$(docker image inspect "$ref" --format '{{.Os}}/{{.Architecture}}')"
        want_arch="${PLATFORM:-$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')}"
        [ "$img_arch" = "$want_arch" ] \
            || warn "$ref is $img_arch but this build targets $want_arch"
        REFS+=("$ref")
    done
    ok "${#SCANNER_REFS[@]} scanner images pulled"

    step "saving tool images to images/"
    # Each manifest line is "<exact-ref>\t<tarball>\t<fallback-tag>".
    #
    # The fallback tag exists because `docker save`/`docker load` of a
    # DIGEST-pinned reference is daemon-dependent: with the containerd
    # snapshotter the digest survives, but on a classic overlay2 daemon the load
    # restores RepoTags only and the image comes back DANGLING. Then
    # `docker image inspect <repo>@sha256:...` fails, tools/docker_runner.py:25-54
    # falls through to `docker pull`, and deny-by-default egress kills the tool —
    # presenting as an empty scan result rather than an error.
    #
    # So we also tag each digest ref as smith-baked/<name>:pinned and save THAT
    # (a plain tag always survives). smith-entrypoint prefers the exact ref and
    # only rewrites the source literals if the digest turns out unresolvable.
    : > "$MANIFEST"
    for ref in ${REFS[@]+"${REFS[@]}"}; do
        file="$(printf '%s' "$ref" | tr '/:@' '___').tar.gz"
        save_ref="$ref"
        fallback="-"
        case "$ref" in
            *@sha256:*)
                short="$(printf '%s' "${ref##*@sha256:}" | cut -c1-12)"
                base="${ref%@sha256:*}"
                fallback="smith-baked/$(basename "$base"):pinned-$short"
                docker tag "$ref" "$fallback"
                save_ref="$fallback"
                ;;
        esac
        if [ -f "images/$file" ]; then
            echo "    keeping images/$file"
        else
            echo "    saving  images/$file"
            docker save "$save_ref" | gzip -1 > "images/$file.partial"
            mv "images/$file.partial" "images/$file"
        fi
        printf '%s\t%s\t%s\n' "$ref" "$file" "$fallback" >> "$MANIFEST"
    done
    ok "$(wc -l < "$MANIFEST" | tr -d ' ') images staged ($(du -sh images | cut -f1) total)"
fi

# ── 3. the template ─────────────────────────────────────────────────────────
step "sandbox template: $TEMPLATE_TAG"
_logged "template build" docker build ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} \
    --build-arg "SANDBOX_TEMPLATE=$SANDBOX_TEMPLATE" \
    --build-arg "SMITH_REPO=$SMITH_REPO_URL" \
    --build-arg "SMITH_REF=$SMITH_REF" \
    --build-arg "INCLUDE_WEASYPRINT=$WITH_WEASYPRINT" \
    --build-arg "INCLUDE_MERMAID_CLI=$WITH_MERMAID" \
    -t "$TEMPLATE_TAG" \
    .
ok "template built: $TEMPLATE_TAG ($(docker image inspect "$TEMPLATE_TAG" --format '{{.Size}}' | awk '{printf "%.1f GB", $1/1024/1024/1024}'))"

# ── 4. distribute ───────────────────────────────────────────────────────────
if [ -n "$PUSH_REF" ]; then
    step "pushing $PUSH_REF"
    _logged "push" docker push "$PUSH_REF"
    ok "pushed"
    echo
    echo "  Teammates run:"
    echo "    sbx run --template $PUSH_REF --publish 7777:7777 claude"
else
    OUT="$(printf '%s' "$TEMPLATE_TAG" | tr '/:' '--').tar"
    step "saving template to $OUT"
    docker save "$TEMPLATE_TAG" -o "$OUT"
    ok "$OUT ($(du -h "$OUT" | cut -f1))"
    echo
    echo "  Hand that one file to a teammate. They run:"
    echo "    sbx template load $OUT"
    echo "    sbx policy allow network <target>"
    echo "    sbx run --template $TEMPLATE_TAG --publish 7777:7777 claude"
fi
