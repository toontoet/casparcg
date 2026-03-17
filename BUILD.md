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

## Triggering a build

Builds are triggered automatically when:

- `build-config.yml` is pushed to the `casparvc` branch.

Builds can also be triggered manually:

1. Go to **Actions** → **Build Custom CasparCG** in the GitHub repository.
2. Click **Run workflow** and select the `casparvc` branch.

## Merge conflicts

If a feature branch conflicts with upstream master (or another feature), the
build will **fail** with a clear error message identifying the conflicting
branch.

To fix:

```bash
git checkout feature/conflicting-branch
git fetch upstream
git rebase upstream/master
# resolve conflicts
git push --force-with-lease
```

Then re-trigger the build.

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

- The fork repository must have **GitHub Packages** write access enabled
  (default for `GITHUB_TOKEN` with `packages: write` permission).
- Feature branches must be pushed to this fork (`origin`).
- Feature branches should be regularly rebased onto upstream master to prevent
  merge conflicts.
