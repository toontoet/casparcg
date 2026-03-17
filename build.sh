#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# CasparCG Custom Build — local build script
#
# Merges enabled feature branches onto upstream master and
# builds a Docker image, including local-only files (e.g.
# proprietary libs) that cannot be stored in git.
#
# Usage:
#   ./build.sh              Build image locally
#   ./build.sh --push       Build and push to registry
#   ./build.sh --dry-run    Show merge plan, don't build
#
# Environment overrides:
#   REGISTRY   Docker registry    (default: ghcr.io)
#   IMAGE      Image name         (default: toontoet/casparcg)
#   PLATFORM   Target platform    (default: linux/amd64)
# ─────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BUILDDIR="$REPO_ROOT/.build-work"

REGISTRY="${REGISTRY:-ghcr.io}"
IMAGE="${IMAGE:-toontoet/casparcg}"
PLATFORM="${PLATFORM:-linux/amd64}"
PUSH=false
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --push)    PUSH=true ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            head -17 "$0" | tail -14
            exit 0 ;;
        *)
            echo "Unknown option: $arg"
            echo "Usage: $0 [--push] [--dry-run] [--help]"
            exit 1 ;;
    esac
done

# ── cleanup on exit ──────────────────────────────────────────
cleanup() {
    if [ -d "$BUILDDIR" ]; then
        echo ""
        echo "Cleaning up build worktree..."
        git -C "$REPO_ROOT" worktree remove --force "$BUILDDIR" 2>/dev/null || true
        rm -rf "$BUILDDIR"
    fi
}
trap cleanup EXIT

# ── parse build-config.yml from casparvc branch ─────────────
echo "=== CasparCG Custom Build ==="
echo ""
echo "Reading build-config.yml from casparvc branch..."

CONFIG="$(git -C "$REPO_ROOT" show casparvc:build-config.yml)"

PARSED="$(echo "$CONFIG" | python3 -c "
import re, sys

text = sys.stdin.read()

m = re.search(r'upstream:\s*\n\s+repo:\s*(\S+)\s*\n\s+branch:\s*(\S+)', text)
print(f'UPSTREAM_REPO={m.group(1)}')
print(f'UPSTREAM_BRANCH={m.group(2)}')

features_b, features_n = [], []
for m in re.finditer(r'-\s+name:\s*(.+)\n\s+branch:\s*(\S+)\n\s+enabled:\s*(\S+)', text):
    if m.group(3).strip() == 'true':
        features_b.append(m.group(2).strip())
        features_n.append(m.group(1).strip())

print('FEATURE_BRANCHES=(' + ' '.join(repr(b) for b in features_b) + ')')
print('FEATURE_NAMES=('    + ' '.join(repr(n) for n in features_n) + ')')

local_files = []
in_section = False
for line in text.split('\n'):
    if re.match(r'local_files:', line):
        in_section = True
        continue
    if in_section:
        m2 = re.match(r'\s+-\s+(.+)', line)
        if m2:
            local_files.append(m2.group(1).strip())
        elif line.strip() and not line.strip().startswith('#'):
            break

print('LOCAL_FILES=(' + ' '.join(repr(f) for f in local_files) + ')')
")"

eval "$PARSED"

echo "  Upstream:  $UPSTREAM_REPO ($UPSTREAM_BRANCH)"
echo "  Features:  ${#FEATURE_BRANCHES[@]} enabled"
for i in "${!FEATURE_BRANCHES[@]}"; do
    echo "    [$((i+1))] ${FEATURE_NAMES[$i]}  (${FEATURE_BRANCHES[$i]})"
done
if [ ${#LOCAL_FILES[@]} -gt 0 ]; then
    echo "  Local files: ${#LOCAL_FILES[@]}"
fi
echo ""

if $DRY_RUN; then
    echo "Dry run — nothing to build."
    exit 0
fi

# ── fetch latest ─────────────────────────────────────────────
echo "Fetching latest from upstream and origin..."
git -C "$REPO_ROOT" fetch upstream --quiet 2>&1 || true
git -C "$REPO_ROOT" fetch origin   --quiet 2>&1 || true
echo ""

# ── create integration worktree ──────────────────────────────
echo "Creating integration worktree from upstream/$UPSTREAM_BRANCH..."
cleanup 2>/dev/null || true
git -C "$REPO_ROOT" worktree add --detach "$BUILDDIR" "upstream/$UPSTREAM_BRANCH" --quiet 2>&1

UPSTREAM_SHA="$(git  -C "$BUILDDIR" rev-parse HEAD)"
UPSTREAM_SHORT="$(git -C "$BUILDDIR" rev-parse --short HEAD)"
echo "  Upstream commit: $UPSTREAM_SHORT"
echo ""

git -C "$BUILDDIR" config user.email "build@local"
git -C "$BUILDDIR" config user.name  "Local Build"

# ── merge feature branches ───────────────────────────────────
echo "=== Merging feature branches ==="
echo ""

MERGED=0
for i in "${!FEATURE_BRANCHES[@]}"; do
    branch="${FEATURE_BRANCHES[$i]}"
    name="${FEATURE_NAMES[$i]}"
    printf "  [%d/%d] %s (%s) ... " "$((i+1))" "${#FEATURE_BRANCHES[@]}" "$name" "$branch"

    if ! git -C "$BUILDDIR" merge --no-edit "origin/$branch" > /dev/null 2>&1; then
        echo "CONFLICT"
        echo ""
        echo "Failed to merge '$branch'."
        echo "Rebase this branch onto upstream/$UPSTREAM_BRANCH and push."
        echo "See BUILD.md for detailed instructions."
        git -C "$BUILDDIR" merge --abort 2>/dev/null || true
        exit 1
    fi

    echo "OK"
    MERGED=$((MERGED + 1))
done

echo ""
echo "  $MERGED branch(es) merged successfully."
echo ""

# ── copy local-only files ────────────────────────────────────
if [ ${#LOCAL_FILES[@]} -gt 0 ]; then
    echo "=== Copying local files into build context ==="
    echo ""
    MISSING=0
    for f in "${LOCAL_FILES[@]}"; do
        if [ -f "$REPO_ROOT/$f" ]; then
            mkdir -p "$BUILDDIR/$(dirname "$f")"
            cp "$REPO_ROOT/$f" "$BUILDDIR/$f"
            echo "  OK  $f"
        else
            echo "  MISSING  $f"
            MISSING=$((MISSING + 1))
        fi
    done
    echo ""
    if [ $MISSING -gt 0 ]; then
        echo "WARNING: $MISSING local file(s) not found. Build may fail."
        echo "         Check the local_files section in build-config.yml."
        echo ""
    fi
fi

# ── build docker image ───────────────────────────────────────
FULL_IMAGE="$REGISTRY/$IMAGE"

echo "=== Building Docker image ==="
echo ""
echo "  Image:    $FULL_IMAGE"
echo "  Platform: $PLATFORM"
echo "  Tags:     latest, upstream-$UPSTREAM_SHORT"
echo ""

BUILD_ARGS=(
    --platform "$PLATFORM"
    -f "$BUILDDIR/tools/linux/Dockerfile"
    -t "$FULL_IMAGE:latest"
    -t "$FULL_IMAGE:upstream-$UPSTREAM_SHORT"
    --build-arg "GIT_HASH=$UPSTREAM_SHA"
)

if $PUSH; then
    BUILD_ARGS+=(--push)
    echo "Build will push to $REGISTRY after completion."
    echo "Make sure you are logged in: docker login $REGISTRY"
    echo ""
else
    BUILD_ARGS+=(--load)
fi

docker buildx build "${BUILD_ARGS[@]}" "$BUILDDIR"

echo ""
echo "=== Build complete ==="
echo ""
echo "  $FULL_IMAGE:latest"
echo "  $FULL_IMAGE:upstream-$UPSTREAM_SHORT"

if ! $PUSH; then
    echo ""
    echo "To push manually:"
    echo "  docker push $FULL_IMAGE:latest"
    echo "  docker push $FULL_IMAGE:upstream-$UPSTREAM_SHORT"
    echo ""
    echo "Or re-run with --push:  ./build.sh --push"
fi
