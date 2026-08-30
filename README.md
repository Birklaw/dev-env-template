# dev-env-template

Bootstrap a fresh Fedora VM into a dev environment: Docker + DevPod + VS Code
on the host, per-project devcontainers built from `template/`, and a shared
mise-managed toolchain (node, python, go, uv, pnpm, kubectl, helm, k9s,
terraform) plus agent CLIs (herdr, pi) installed identically on the VM and
inside every container.

Editing is **terminal-first with LazyVim (Neovim)**: `neovim`, `lazygit`,
`ripgrep`, `fd`, `fzf` and `tree-sitter` are mise-managed like everything
else, and the LazyVim config ships via the dotfiles repo into every
container. VS Code remains installed on the VM as a fallback (Jupyter, GUI
debugging) — attach it per-project with `devpod up --ide vscode`.

## Prerequisites

- Fedora VM (x86_64 or aarch64), with sudo
- GitHub access to this repo (it is private — see below)

## 1. Get this repo onto the VM

The repo is private, so GitHub auth must exist *before* cloning. Pick one:

```bash
# Option A: SSH key (add the pubkey to GitHub first)
ssh-keygen -t ed25519
cat ~/.ssh/id_ed25519.pub   # add at github.com/settings/keys
git clone git@github.com:Birklaw/dev-env-template.git

# Option B: GitHub CLI
sudo dnf install -y gh
gh auth login
gh repo clone Birklaw/dev-env-template
```

## 2. Bootstrap the VM (once per VM)

```bash
cd dev-env-template
./vm-bootstrap.sh
```

Installs: git/curl/gh, libatomic (if missing), Docker, DevPod CLI, VS Code +
Dev Containers extension, Nerd Font symbols (pinned + hash-verified,
fontconfig fallback so the terminal font itself doesn't change), dotfiles
defaults for DevPod, and the mise toolchain + agent CLIs (via
`template/setup-mise.sh`).

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
VM's toolchain, not the container's. Always attach via `--ide vscode` (or
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
   files live on the VM and are shared by every session (VS Code, `devpod
   ssh`) that touches this workspace.
3. **`postCreateCommand`** — runs `.devcontainer/post-create.sh` inside the
   container: installs `libatomic1` if needed, runs `setup-mise.sh` (mise +
   global toolchain, isolated from project config), then applies your
   project's `mise.toml` pins if present. This is the slow step on first
   creation (~1–2 min); it does not re-run on subsequent starts.
4. **Dotfiles** — DevPod clones your dotfiles repo *inside the container* and
   runs the configured install script. The repo must be cloneable without
   host credentials (public HTTPS, or SSH with agent forwarding).
5. **IDE attach** (`--ide vscode` only) — DevPod launches the VM's VS Code,
   the Dev Containers extension connects to the container, and the extension
   list from `devcontainer.json` is installed into the container's VS Code
   server in the background.

### Lifecycle

```bash
devpod up my-project            # start (idempotent; reuses existing container)
devpod stop my-project          # stop, keep container + its state
devpod up ... --recreate        # rebuild after changing .devcontainer/
devpod delete my-project        # remove container entirely (project files
                                # survive — they're the mounted VM directory)
```

Container-local state (installed tools, dotfiles symlinks, anything outside
the project dir) is rebuilt by `post-create.sh` + dotfiles on recreation, so
`delete` + `up` is always a safe reset.

## Layout

| Path | Purpose |
|---|---|
| `vm-bootstrap.sh` | One-time VM base layer (packages, docker, devpod, VS Code, mise) |
| `template/setup-mise.sh` | Shared toolchain installer — runs on the VM and in every devcontainer |
| `template/.devcontainer/` | Copy into each new project: container definition + post-create hook |

## Notes

- **LazyVim is the primary editor; VS Code is the fallback.** Neovim +
  `lazygit`/`ripgrep`/`fd`/`fzf`/`tree-sitter` come from the shared mise
  toolchain (identical on VM and in containers). The LazyVim config lives in
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
  hardcoded in `vm-bootstrap.sh`) installed user-local with a fontconfig
  fallback rule — the terminal's font setting does not change. If icons look
  wrong, verify `fc-list | grep "Symbols Nerd Font"` shows two families.
- **tmux**: `.tmux.conf` (dotfiles) sets `tmux-256color` + truecolor and
  undercurl passthrough, which LazyVim needs. Fedora's native terminal
  (Ptyxis/GNOME Terminal) supports both; no alternative terminal required.
- **mise is the only tool manager.** Global tools: `mise use -g <tool>`.
  Project overrides: `mise.toml` in the project root. Refresh: `mise upgrade`.
  Global installs are isolated from project config (`setup-mise.sh` runs from
  `$HOME`), so a project's pins can never break the base toolchain.
- **Docker runs on the VM.** Containers use docker-outside-of-docker: the
  feature mounts the host socket to `/var/run/docker-host.sock` and proxies a
  permission-fixed `/var/run/docker.sock` (sibling containers, shared build
  cache, no privileged mode). Don't add your own socket mount.
- **Dotfiles** are applied by DevPod to every workspace. Change with:
  `devpod context set-options -o DOTFILES_URL=... -o DOTFILES_SCRIPT=...`
- **GitHub auth inside containers:** `gh auth login` on the VM does **not**
  propagate into devcontainers. Git over SSH works via agent forwarding
  (`ssh-add` your key on the VM); for HTTPS/`gh` inside a container, run
  `gh auth login` there once (auth persists in the container's home until
  recreation).
