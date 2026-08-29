# dev-env-template

Bootstrap a fresh Fedora VM into a dev environment: Docker + DevPod + VS Code
on the host, per-project devcontainers built from `template/`, and a shared
mise-managed toolchain (node, python, go, uv, pnpm, kubectl, helm, k9s,
terraform, Kilo CLI) installed identically on the VM and inside every
container.

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
Dev Containers extension, dotfiles defaults for DevPod, and the mise toolchain
(via `template/setup-mise.sh`).

**Then start a new shell** (or log out/in) so docker group membership applies.

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
devpod up ~/my-project --ide vscode
```

First run takes a few minutes (pulls the base image, installs the toolchain).

Terminal-first daily flow:

```bash
devpod up ~/my-project               # start container (idempotent)
devpod up ~/my-project --ide vscode  # attach VS Code to it
devpod ssh my-project                # shell into the container from any terminal
```

Note: plain `code ~/my-project` opens the folder *locally* — you'd get the
VM's toolchain, not the container's. Always attach via `--ide vscode` (or
"Dev Containers: Attach" from VS Code). Once attached, VS Code's integrated
terminal runs inside the container, and `devpod ssh` sessions share the same
container, dotfiles, and mise toolchain.

## Layout

| Path | Purpose |
|---|---|
| `vm-bootstrap.sh` | One-time VM base layer (packages, docker, devpod, VS Code, mise) |
| `template/setup-mise.sh` | Shared toolchain installer — runs on the VM and in every devcontainer |
| `template/.devcontainer/` | Copy into each new project: container definition + post-create hook |

## Notes

- **mise is the only tool manager.** Global tools: `mise use -g <tool>`.
  Project overrides: `mise.toml` in the project root. Refresh: `mise upgrade`.
- **Docker runs on the VM.** Containers use docker-outside-of-docker (sibling
  containers sharing the host daemon and build cache, no privileged mode).
- **Dotfiles** are applied by DevPod to every workspace. Change with:
  `devpod context set-options -o DOTFILES_URL=... -o DOTFILES_SCRIPT=...`
- **GitHub auth inside containers:** run `gh auth login` on the VM once and
  `gh auth setup-git`; DevPod forwards git/SSH into workspaces.
