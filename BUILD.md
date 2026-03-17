# CasparCG Custom Build System

This repository uses a **config-driven build** that combines the upstream
CasparCG master branch with selectively enabled feature branches from this
fork. The result is a Docker image pushed to GitHub Container Registry.

## How it works

```
upstream/master ─────────────┐
                             ├─ merge ─► Docker build ─► ghcr.io image
feature branches (enabled) ──┘
```

1. The GitHub Actions workflow reads `build-config.yml` from the **casparvc**
   branch.
2. It checks out the upstream CasparCG master branch.
3. Each feature branch marked `enabled: true` is merged on top of upstream
   master (in the order listed).
4. The merged source is built using `tools/linux/Dockerfile`.
5. The resulting Docker image is pushed to `ghcr.io/<owner>/casparcg` with two
   tags:
   - `latest`
   - `upstream-<short-sha>` (the upstream master commit the build is based on)

## Configuration

All build configuration lives in **`build-config.yml`** on the `casparvc`
branch.

### File structure

```yaml
upstream:
  repo: CasparCG/server      # upstream GitHub repo (org/name)
  branch: master              # upstream branch to track

fork:
  repo: toontoet/casparcg     # this fork (org/name)

features:
  - name: Human-readable name
    branch: feature/branch-name
    enabled: true              # true = include, false = skip
    description: >
      Optional description of what this feature does.
```

### Enable or disable a feature

1. Switch to the `casparvc` branch:
   ```bash
   git checkout casparvc
   ```
2. Edit `build-config.yml` — set `enabled: true` or `enabled: false` for each
   feature.
3. Commit and push:
   ```bash
   git add build-config.yml
   git commit -m "toggle feature X"
   git push
   ```
4. The push automatically triggers a new Docker build.

### Add a new feature branch

1. Create your feature branch from upstream master:
   ```bash
   git checkout -b feature/my-feature upstream/master
   # ... make changes, commit, push ...
   git push -u origin feature/my-feature
   ```
2. Switch to `casparvc` and add an entry to `build-config.yml`:
   ```yaml
   - name: My New Feature
     branch: feature/my-feature
     enabled: true
     description: >
       What this feature does.
   ```
3. Commit and push the config change to trigger a build.

## Local builds

Use `build.sh` to build locally. This is **required** when the build uses
proprietary files (like `libStereoTool`) that cannot be stored in git.

### Prerequisites

- **Docker Desktop** with buildx (comes with Docker Desktop for Mac)
- **Python 3** (pre-installed on macOS)
- **Git** with the `upstream` remote pointing to `CasparCG/server`

### Quick start

```bash
# Build the image locally:
./build.sh

# See what would be merged, without building:
./build.sh --dry-run

# Build and push to the registry:
docker login ghcr.io
./build.sh --push
```

The script automatically:
1. Reads `build-config.yml` from the `casparvc` branch
2. Creates a temporary git worktree from upstream master
3. Merges each enabled feature branch (in config order)
4. Copies local-only files (listed under `local_files:` in the config)
5. Runs `docker buildx build` for `linux/amd64`
6. Tags the image with `latest` and `upstream-<sha>`
7. Cleans up the temporary worktree

### Local-only files

Some features require proprietary binaries that cannot be stored in git (e.g.
`libStereoTool`). List these in `build-config.yml`:

```yaml
local_files:
  - test/libStereoTool_1075/lib/Linux/IntelAMD/64/libStereoTool_intel64.so
```

The build script copies these from your workspace into the Docker build
context. If a file is missing, the script prints a warning and continues.

### Overriding defaults

| Variable | Default | Description |
|----------|---------|-------------|
| `REGISTRY` | `ghcr.io` | Docker registry |
| `IMAGE` | `toontoet/casparcg` | Image name |
| `PLATFORM` | `linux/amd64` | Target platform |

```bash
REGISTRY=my.registry.io IMAGE=myorg/casparcg ./build.sh --push
```

## CI builds (GitHub Actions)

Builds are triggered automatically when:

- `build-config.yml` is pushed to the `casparvc` branch.

Builds can also be triggered manually:

1. Go to **Actions** → **Build Custom CasparCG** in the GitHub repository.
2. Click **Run workflow** and select the `casparvc` branch.

> **Note:** CI builds cannot access local-only files. Use `./build.sh` for
> builds that include proprietary libraries.

## Merge conflicts

Branches are merged **in the order listed** in `build-config.yml`. If a branch
conflicts with upstream master or with a previously merged branch, the build
will **fail** with a clear message identifying the conflicting branch.

### Understanding the cause

Conflicts happen when two branches modify the same section of the same file.
Common scenarios:

| Scenario | Example |
|----------|---------|
| Upstream changed a file your branch also edits | Upstream refactored `ffmpeg_consumer.cpp`, your branch adds code in the same area |
| Two feature branches edit the same file | `feature/reconnect` restructures a function, `feature/hw-encoding` adds code to the same function |

### Fixing a conflict with upstream

If a branch conflicts with upstream master:

```bash
git checkout feature/conflicting-branch
git fetch upstream
git rebase upstream/master
# Git will pause at each conflict. Edit the files, then:
git add <resolved-files>
git rebase --continue
# Repeat until rebase is complete, then force-push:
git push --force-with-lease
```

### Fixing a conflict between feature branches

If branch B conflicts with branch A (which is listed earlier in the config),
the easiest fix is to rebase B onto A:

```bash
git checkout feature/branch-B
git fetch origin
git rebase origin/feature/branch-A
# Resolve conflicts, then:
git add <resolved-files>
git rebase --continue
git push --force-with-lease
```

This makes B depend on A. As long as A is listed before B in
`build-config.yml` and both are enabled, the merge will succeed.

> **Note**: If you later disable branch A, branch B may fail to merge. Either
> rebase B onto `upstream/master` directly, or re-enable A.

### Verifying locally before pushing

You can test the full merge sequence locally:

```bash
git fetch upstream && git fetch origin

git checkout -b test-integration upstream/master

# Merge each enabled branch in config order:
git merge --no-edit origin/feature/reconnect
git merge --no-edit origin/feature/stereotool
git merge --no-edit origin/feature/hw-encoding-support
git merge --no-edit origin/fix/utf8-cg-update

# If all succeed, the integration is clean. Clean up:
git checkout -
git branch -D test-integration
```

### Tips

- **Branch order matters.** If two branches touch the same file, list the one
  with the larger structural changes first.
- **Keep branches focused.** A branch that only touches one file is less likely
  to conflict than one that touches ten.
- **Rebase regularly.** After upstream merges new commits, rebase your feature
  branches to stay close to master.

## Docker image tags

| Tag | Meaning |
|-----|---------|
| `latest` | Most recent successful build |
| `upstream-<sha>` | Based on this specific upstream master commit |

### Pulling the image

```bash
docker pull ghcr.io/toontoet/casparcg:latest
```

Or a specific upstream version:

```bash
docker pull ghcr.io/toontoet/casparcg:upstream-abc1234
```

### Running

```bash
docker run --rm -it \
  -p 5250:5250 \
  -v /path/to/casparcg.config:/opt/casparcg/casparcg.config \
  ghcr.io/toontoet/casparcg:latest
```

## Requirements

- **Docker Desktop** with buildx support (for local builds)
- **Python 3** (for config parsing in `build.sh`)
- Feature branches must be pushed to this fork (`origin`).
- Feature branches should be regularly rebased onto upstream master to prevent
  merge conflicts.
- For CI builds: the fork must have **GitHub Packages** write access enabled
  (default for `GITHUB_TOKEN` with `packages: write` permission).
