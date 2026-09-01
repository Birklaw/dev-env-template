# dev-env-template

Bootstrap a fresh Fedora VM or an Armbian/Debian-family host (tested:
Orange Pi 5B, aarch64, Armbian Debian trixie) into a dev environment:
Docker + DevPod + VS Code on the host, per-project devcontainers built from
`template/`, and a shared mise-managed toolchain (node, python, go, uv, pnpm,
kubectl, helm, k9s, terraform) plus agent CLIs (herdr, pi) installed
identically on the host and inside every container.

Editing is **terminal-first with LazyVim (Neovim)**: `neovim`, `lazygit`,
`ripgrep`, `fd`, `fzf` and `tree-sitter` are mise-managed like everything
else, and the LazyVim config ships via the dotfiles repo into every
container. VS Code remains installed on the host as a fallback (Jupyter, GUI
debugging) — attach it per-project with `devpod up --ide vscode`.

## Prerequisites

- Fedora VM (x86_64/aarch64), or an Armbian/Debian-family host (tested:
  Orange Pi 5B, aarch64, Armbian Debian trixie), with a non-root sudo user
- GitHub access: the repo is public, so a plain clone works on any fresh
  host; pushing from it needs `gh auth login` + `gh auth setup-git`, or an
  SSH key (see below)

## 1. Get this repo onto the host

```bash
git clone https://github.com/Birklaw/dev-env-template.git
cd dev-env-template
```

Cloning is unauthenticated (public repo, HTTPS). To **push** from a fresh
host, pick one after cloning:

```bash
# Option A: GitHub CLI (installed by bootstrap.sh in any case)
gh auth login
gh auth setup-git

# Option B: SSH key
ssh-keygen -t ed25519
cat ~/.ssh/id_ed25519.pub   # add at github.com/settings/keys
git remote set-url origin git@github.com:Birklaw/dev-env-template.git
```

## 2. Bootstrap the host (once per machine)

```bash
cd dev-env-template
./bootstrap.sh
```

`bootstrap.sh` detects the host (reads `/etc/os-release`; recognizes Armbian
via the `/etc/armbian-release` marker) and dispatches to `targets/fedora.sh`
or `targets/debian.sh`; distro-agnostic steps are shared via `lib/common.sh`.

Detection is fail-closed: the `case` in `bootstrap.sh` is the support
matrix — hosts are supported after being tested, never via `ID_LIKE` fuzzy
matching. An unknown OS stops with an error printing the detected facts. To
add a new distro: run the matching target directly, verify, then add the
detected `$ID` to the case. Router dry run: `./bootstrap.sh --print-family`.

Installs: git/curl/gh (GitHub's upstream apt repo on Debian-family),
libatomic (if missing), Docker (docker-ce on Debian-family), DevPod CLI,
VS Code + Dev Containers extension, Nerd Font symbols (pinned +
hash-verified, fontconfig fallback so the terminal font itself doesn't
change), dotfiles defaults for DevPod, and the mise toolchain + agent CLIs
(via `template/setup-mise.sh`).

**Then reboot** (a fresh login is often enough, but a reboot is the reliable
way to get docker group membership picked up everywhere).

## 3. Start a new project

```bash
mkdir ~/my-project && cd ~/my-project
cp -r ~/dev-env-template/template/. .
git init
```

Optional — pin project-specific tool versions in a `mise.toml`:

```toml
[tools]
node = "20"
python = "3.12"
```

## 4. Spin up the devcontainer

```bash
devpod up ~/my-project               # terminal-first: no IDE flag needed
```

First run takes a few minutes (pulls the base image, installs the toolchain).

Terminal-first daily flow (LazyVim):

```bash
devpod up ~/my-project               # start container (idempotent)
devpod ssh my-project                # shell into the container
nvim .                               # LazyVim: LSP, fuzzy-find, git, debug
```

VS Code remains available as a fallback (Jupyter notebooks, GUI debugging):

```bash
devpod up ~/my-project --ide vscode  # attach VS Code to the container
```

Note: plain `code ~/my-project` opens the folder *locally* — you'd get the
host's toolchain, not the container's. Always attach via `--ide vscode` (or
"Dev Containers: Attach" from VS Code). Once attached, VS Code's integrated
terminal runs inside the container, and `devpod ssh` sessions share the same
container, dotfiles, mise toolchain, and LazyVim config.

## What happens on `devpod up`

Understanding the sequence makes the moving parts easy to debug:

1. **Build** — Docker builds an image from `.devcontainer/devcontainer.json`
   (base image + features, e.g. the docker-outside-of-docker CLI). Cached
   after the first run; rebuilt only when the config changes or you pass
   `--recreate`.
2. **Container start** — the project directory is bind-mounted in, so your
   files live on the host and are shared by every session (VS Code, `devpod
   ssh`) that touches this workspace.
3. **`postCreateCommand`** — runs `.devcontainer/post-create.sh` inside the
   container: installs `libatomic1` if needed, runs `setup-mise.sh` (mise +
   global toolchain, isolated from project config), then applies your
   project's `mise.toml` pins if present. This is the slow step on first
   creation (~1–2 min); it does not re-run on subsequent starts.
4. **Dotfiles** — DevPod clones your dotfiles repo *inside the container* and
   runs the configured install script. The repo must be cloneable without
   host credentials (public HTTPS, or SSH with agent forwarding).
5. **IDE attach** (`--ide vscode` only) — DevPod launches the host's VS Code,
   the Dev Containers extension connects to the container, and the extension
   list from `devcontainer.json` is installed into the container's VS Code
   server in the background.

### Lifecycle

```bash
devpod up my-project            # start (idempotent; reuses existing container)
devpod stop my-project          # stop, keep container + its state
devpod up ... --recreate        # rebuild after changing .devcontainer/
devpod delete my-project        # remove container entirely (project files
                                 # survive — they're the mounted host directory)
```

Container-local state (installed tools, dotfiles symlinks, anything outside
the project dir) is rebuilt by `post-create.sh` + dotfiles on recreation, so
`delete` + `up` is always a safe reset.

## Layout

| Path | Purpose |
|---|---|
| `bootstrap.sh` | Router: detect OS family (fail-closed) → dispatch to a target |
| `targets/fedora.sh` | Fedora host base layer: dnf packages, docker, VS Code repo |
| `targets/debian.sh` | Debian-family/Armbian host base layer: apt, docker-ce, gh + VS Code repos |
| `lib/common.sh` | Distro-agnostic host steps (devpod, docker group, nerd font, mise) |
| `template/setup-mise.sh` | Shared toolchain installer — runs on the host and in every devcontainer |
| `template/.devcontainer/` | Copy into each new project: container definition + post-create hook |

## Notes

- **LazyVim is the primary editor; VS Code is the fallback.** Neovim +
  `lazygit`/`ripgrep`/`fd`/`fzf`/`tree-sitter` come from the shared mise
  toolchain (identical on host and in containers). The LazyVim config lives in
  the dotfiles repo (`nvim/` → `~/.config/nvim`): language extras are
  declared in `lazyvim.json`, plugins pinned in `lazy-lock.json`, LSP
  servers/formatters in `lua/plugins/tools.lua` (`ensure_installed`).
  Dotfiles `install.sh` runs the headless plugin + Mason sync; without it,
  first `nvim` launch self-heals. Extras in use: python, go, typescript,
  yaml, docker, terraform, helm, json, markdown + `dap.core` (debugging),
  `test.core`, `editor.aerial`. VS Code's extension list in
  `devcontainer.json` is only consumed on `--ide vscode` attach — keep it
  for the Jupyter/debugging fallback path.
- **Nerd Font icons** come from a symbols-only tarball (pinned, SHA-256
  hardcoded in `lib/common.sh`) installed user-local with a fontconfig
  fallback rule — the terminal's font setting does not change. If icons look
  wrong, verify `fc-list | grep "Symbols Nerd Font"` shows two families.
- **tmux**: `.tmux.conf` (dotfiles) sets `tmux-256color` + truecolor and
  undercurl passthrough, which LazyVim needs. Fedora's native terminal
  (Ptyxis/GNOME Terminal) supports both; no alternative terminal required.
- **mise is the only tool manager.** Global tools: `mise use -g <tool>`.
  Project overrides: `mise.toml` in the project root. Refresh: `mise upgrade`.
  Global installs are isolated from project config (`setup-mise.sh` runs from
  `$HOME`), so a project's pins can never break the base toolchain.
- **Docker runs on the host.** Containers use docker-outside-of-docker: the
  feature mounts the host socket to `/var/run/docker-host.sock` and proxies a
  permission-fixed `/var/run/docker.sock` (sibling containers, shared build
  cache, no privileged mode). Don't add your own socket mount.
- **Dotfiles** are applied by DevPod to every workspace. Change with:
  `devpod context set-options -o DOTFILES_URL=... -o DOTFILES_SCRIPT=...`
- **GitHub auth inside containers:** `gh auth login` on the host does **not**
  propagate into devcontainers. Git over SSH works via agent forwarding
  (`ssh-add` your key on the host); for HTTPS/`gh` inside a container, run
  `gh auth login` there once (auth persists in the container's home until
  recreation).
- **ARM64 hosts** (e.g. Orange Pi 5B under Armbian): every component ships
  native aarch64 Linux builds — docker-ce, VS Code and gh via their
  arm64-publishing apt repos, DevPod's `linux-arm64` binary, and the whole
  mise toolchain including the agent CLIs (herdr's official
  `herdr-linux-aarch64` assets, pi's `pi-linux-arm64` builds). Devcontainers
  built on an ARM host are arm64 images too — host arch = container arch,
  no emulation anywhere. First `devpod up` is just slower than on x86
  (image pulls + toolchain install on SBC-class storage); 16 GB RAM is
  plenty.
