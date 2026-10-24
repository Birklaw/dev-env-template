# dev-env-template

Bootstrap a fresh Fedora VM or an Armbian/Debian-family host (tested:
Orange Pi 5B, aarch64, Armbian Debian trixie) into a dev environment:
Docker + DevPod on the host, per-project devcontainers built from
`template/`, and a shared mise-managed toolchain (node, python, go, uv, pnpm,
kubectl, helm, k9s, terraform) plus agent CLIs (herdr, pi) installed
identically on the host and inside every container.

Editing is **terminal-first with LazyVim (Neovim)**: `neovim`, `lazygit`,
`ripgrep`, `fd`, `fzf` and `tree-sitter` are mise-managed like everything
else, and the LazyVim config ships via the dotfiles repo into every
container. There is **no VS Code**: containers are started with
`devpod up --ide none` and entered over `devpod ssh`.

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

Any parent directory works (`~/projects`, `~/repos`, ...). Bootstrap clones
the **dotfiles as a sibling of this checkout** — `<parent>/dotfiles` — so
wherever you put `dev-env-template`, the dotfiles land next to it.

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

Wrapping the run in tmux is optional insurance: over SSH, a foreground
bootstrap dies with the connection, while a tmux session can be reattached.
The script is fail-closed and idempotent, so an interrupted run is always
safe to rerun — on a stable link, just run it directly.

`bootstrap.sh` detects the host (reads `/etc/os-release`; recognizes Armbian
via the `/etc/armbian-release` marker) and dispatches to `targets/fedora.sh`
or `targets/debian.sh`; distro-agnostic steps are shared via `lib/common.sh`.

Detection is fail-closed: the `case` in `bootstrap.sh` is the support
matrix — hosts are supported after being tested, never via `ID_LIKE` fuzzy
matching. An unknown OS stops with an error printing the detected facts. To
add a new distro: run the matching target directly, verify, then add the
detected `$ID` to the case. Router dry run: `./bootstrap.sh --print-family`.

Installs: git/curl/gh (GitHub's upstream apt repo on Debian-family), tmux,
libatomic (if missing), Docker (docker-ce on Debian-family), a firewalld zone that lets the
container bridge forward (see "Container networking" below), DevPod CLI,
Nerd Font symbols (pinned + hash-verified, fontconfig fallback so the
terminal font itself doesn't change), dotfiles defaults for DevPod, the
mise toolchain + agent CLIs (via `template/setup-mise.sh`), the skill
packs (via `template/install-skills.sh`), and finally **the dotfiles on the
host itself** (see below).

Every host is also smoke-tested before the slow steps: a throwaway container
must resolve a hostname and reach the internet. A container that cannot turns
later failures into unrelated-looking ones (`git clone` exit 128 in DevPod's
dotfiles step, `curl: (6)` inside a devcontainer feature build), so the
bootstrap fails here instead, naming the cause.

### Host dotfiles (cloned alongside this checkout)

DevPod applies the dotfiles inside every container, but herdr, pi, tmux and
nvim run *on the host*, and `pi/mcp.json` is deliberately host-only. So the
bootstrap clones `DOTFILES_URL` to `<parent-of-this-repo>/dotfiles` and runs
its `install.sh` as your user — no sudo, same script, one URL shared with
DevPod so host and container cannot drift apart.

It runs *after* the mise toolchain, because `install.sh`'s Neovim pre-warm
needs a real `nvim`. Re-running bootstrap is safe: the checkout is synced,
then the installer is re-applied idempotently.

How the existing checkout is treated (it never merges and never discards
work):

| State of `<parent>/dotfiles` | Action |
| --- | --- |
| missing | `git clone $DOTFILES_URL` |
| clean, behind `origin` | fast-forward pull |
| clean, up to date | re-apply only |
| dirty (uncommitted changes) | do not pull; apply the working tree as-is |
| ahead of / diverged from `origin` | warn; do not pull; apply as-is |
| origin is a different repo | warn; apply as-is |
| `offline` (fetch fails) | warn; apply the local copy |

After applying, every path in `DOTFILES_VERIFY_PATHS` must be a symlink or
the bootstrap aborts. That gate exists because `install.sh` reports success
even when a source file is missing (`[skip]` + exit 0), which once produced a
host with a herdr-generated default config and no dotfiles at all.

Knobs (environment variables, all optional):

- `DOTFILES_URL` / `DOTFILES_SCRIPT` — repo and script; also feed DevPod's
  `DOTFILES_URL`/`DOTFILES_SCRIPT` context options. Both have built-in
  defaults (`https://github.com/Birklaw/dotfiles`, `install.sh`), so a plain
  `./bootstrap.sh` needs no arguments; override by exporting the variable
  (`DOTFILES_URL=... ./bootstrap.sh` — bootstrap `exec`s the target, so it
  must be in the environment, not just a shell variable). The sibling
  directory name follows the URL's basename (`dotfiles`).
- `DOTFILES_VERIFY_PATHS` — space-separated `$HOME`-relative paths asserted
  to be symlinks afterwards; set to `""` to disable.
- `SKIP_DOTFILES=1` — skip the host-side clone/apply entirely (the DevPod
  defaults are still configured).

Two asymmetries worth knowing. First, the host uses your **working tree**
(symlinks), while containers get a fresh **clone of the pushed branch** — so
commit and push before expecting a dotfiles change to show up in a container.
Second, apps that rewrite their own config (herdr writes through the symlink)
edit the repo on the host but a throwaway clone in a container; re-check
`git -C <parent>/dotfiles status` after changing such settings, and run
`herdr server reload-config` if a herdr server is already running.

**Then reboot** (a fresh login is often enough, but a reboot is the reliable
way to get docker group membership picked up everywhere).

## 3. Start a new project

```bash
mkdir ~/my-project && cd ~/my-project
cp -r ~/dev-env-template/template/. .    # trailing "/." also copies hidden entries (.devcontainer/)
git init
```

`-r` and the trailing `/.` are both required, and they fail differently:

- `template/*` (no `/.`): the shell expands `*` **before** `cp` runs, so
  `.devcontainer/` is never in the argument list. `cp` exits 0 and prints
  nothing — `-r` cannot help, it cannot copy an entry it was never given.
- `template/.` without `-r`: `cp` sees a directory and fails loudly
  (`-r not specified; omitting directory`), copying nothing.

Either way DevPod falls back to language detection and gives you a stripped
container, so verify the spec before going further:

```bash
test -f .devcontainer/devcontainer.json || echo "SPEC MISSING — re-copy"
git status --short   # .devcontainer/ should be there, not deleted
```

The copy places the container definition and its provisioning scripts
(`.devcontainer/`, `setup-mise.sh`, `install-skills.sh`) in the project.
These are read by the devcontainer's post-create hook — they are not part
of your application code.

Optional — pin project-specific tool versions in a `mise.toml`:

```toml
[tools]
node = "20"
python = "3.12"
```

## 4. Spin up the devcontainer

```bash
devpod up ~/my-project --ide none    # start container, don't launch an editor
```

**Always pass `--ide none`.** DevPod's default IDE is VS Code, which is no
longer installed; without the flag `devpod up` tries to launch it. `--ide
none` starts the container only, and you enter it over SSH.

First run takes a few minutes (pulls the base image, installs the toolchain).

Terminal-first daily flow (LazyVim):

```bash
devpod up ~/my-project --ide none    # start container (idempotent)
devpod ssh my-project                # shell into the container
nvim .                               # LazyVim: LSP, fuzzy-find, git, debug
```

If you ever do want a GUI editor, any DevPod-supported IDE can be attached
per-project with `--ide <name>` (`devpod ide list`); the template itself stays
editor-agnostic and ships no extension list.

### Browser testing: browser on the host, app in the container

UI work needs a real browser. It runs **on the host**, against the workspace's
forwarded dev-server port — not inside the container:

```bash
# 1. workspace running (as usual)
devpod up ~/my-project --ide none
# 2. hold a forwarding session, with a stable local port for this project
devpod ssh -L 3000:localhost:3000 my-project      # leave it open in a tmux pane
# 3. Pi + chromium on the HOST, in the mounted project dir
cd ~/my-project && pi
```

Why this split:

- **The container has no browser and stays that way.** Nothing container-side
  reaches the host's forwarded ports, so a workspace agent cannot see another
  project's dev server. In-container Pi deliberately gets no chrome-devtools
  MCP entry (the dotfiles installer skips it under DevPod).
- **Container isolation is not a security boundary here anyway** — the
  container holds the host's Docker socket and forwarded SSH agent (see Notes),
  so "run the browser in the box" buys tidiness, not containment. What it does
  cost is fidelity: headless-in-container loses host fonts and has to disable
  the Chrome sandbox.
- **The host browser is still restricted.** `chromium` is installed by
  bootstrap; the dotfiles `pi/mcp.json` launches it headless, `--isolated`
  (temporary profile, wiped on close), and with `--allowedUrlPattern` limited
  to `http://localhost:*`, `http://127.0.0.1:*` and `about:*`. No external
  hosts, no tailnet, no metadata endpoint, no `file://`.

Consequences worth knowing before you debug the wrong layer:

- **Forwarding only exists while an ssh session is up.** DevPod has no
  `up --forwardPorts`; ports come from `devpod ssh` (auto-detected) or an
  explicit `-L`. A stable explicit port per project also keeps the allowlist
  meaningful and avoids two workspaces fighting over `localhost:3000`.
- **External subresources are blocked.** Pages that load CDNs, web fonts or a
  remote API will fail under the allowlist. Widen it per project with a
  `.pi/mcp.json` that repeats the entry with the extra pattern — a project
  entry replaces the user-level one of the same name:

  ```json
  {"mcpServers": {"chrome-devtools": {
    "command": "npx",
    "args": ["-y", "chrome-devtools-mcp@1.10.1", "--headless", "--isolated",
             "--executablePath", "/usr/bin/chromium",
             "--allowedUrlPattern", "http://localhost:3000/*",
             "--allowedUrlPattern", "https://api.staging.example.com/*"]
  }}}
  ```

- **Logins do not survive a session** (`--isolated`). If a project needs a
  persisted dev login, override with `--userDataDir ~/.cache/chrome-devtools-mcp/<project>`
  in that project's `.pi/mcp.json`.
- **Chromium ≥ 149 is required.** `verify_host_browser` warns at bootstrap if
  the distro build is older, because the allowlist would then be a no-op while
  still looking configured.
- **The MCP server is pinned** (`chrome-devtools-mcp@1.10.1`) in the dotfiles
  `pi/mcp.json`, not `@latest`: it is spawned from an unpinned supply chain
  otherwise. Bump it there deliberately.
- **No GUI.** The host is reached over ssh, so the browser is always headless;
  screenshots are the verification surface, not a window you watch.
## What happens on `devpod up`

Understanding the sequence makes the moving parts easy to debug:

1. **Build** — Docker builds an image from `.devcontainer/devcontainer.json`
   (base image + features, e.g. the docker-outside-of-docker CLI). Cached
   after the first run; rebuilt only when the config changes or you pass
   `--recreate`.
2. **Container start** — the project directory is bind-mounted in, so your
   files live on the host and are shared by every `devpod ssh` session that
   touches this workspace.
3. **`postCreateCommand`** — runs `.devcontainer/post-create.sh` inside the
   container: installs `libatomic1` if needed, runs `setup-mise.sh` (mise +
   global toolchain, isolated from project config), installs the configured
   skill packs (`install-skills.sh`), then applies your
   project's `mise.toml` pins if present. This is the slow step on first
   creation (~1–2 min); it does not re-run on subsequent starts.
4. **Dotfiles (container)** — DevPod clones your dotfiles repo *inside the
   container* and runs the configured install script. This is a fresh clone of
   the pushed branch, independent of the host copy bootstrap applied; the repo
   must be cloneable without host credentials (public HTTPS, or SSH with agent
   forwarding). The script
   re-runs on every subsequent `devpod up` (clone skipped, install repeated),
   and its Neovim pre-warm is timeout-bounded (`NVIM_BOOTSTRAP_TIMEOUT`,
   default 30 min): a wedged headless bootstrap degrades to a warning + retry
   instead of hanging `devpod up`. A failure here (including a `git clone`
   that cannot resolve the host, which exits 128) surfaces as "Error tunneling
   to container", because the agent waits for the dotfiles step.
5. **No IDE attach** — with `--ide none`, DevPod stops after starting the
   container; connect with `devpod ssh`. (Any DevPod IDE can still be attached
   per-project with `--ide <name>`.)

### Lifecycle

```bash
devpod up my-project --ide none        # start (idempotent; reuses existing container)
devpod stop my-project                 # stop, keep container + its state
devpod up ... --ide none --recreate    # rebuild after changing .devcontainer/
devpod delete my-project               # remove container entirely (project files
                                       # survive — they're the mounted host directory)
```

Container-local state (installed tools, dotfiles symlinks, anything outside
the project dir) is rebuilt by `post-create.sh` + dotfiles on recreation, so
`delete` + `up` is always a safe reset.

## Container networking

DevPod is only as good as the host's container network. Two independent
failure modes look like something else entirely, and both are configured and
verified by the bootstrap.

### `docker0` in no firewalld zone (Fedora)

Docker creates its `docker` zone at runtime and then logs:

```
dockerd: Firewalld: docker zone already exists, returning
```

i.e. it never adds `docker0` to it. An interface in no zone matches no
firewalld policy, so forwarded traffic from the bridge is **rejected**:

- the daemon looks healthy and image pulls work (they use the host's netns),
- containers can talk to each other (pure L2 bridging),
- but containers cannot reach the host **or** the internet.

In a workspace that surfaces as `git clone` failing with **exit 128** in
DevPod's dotfiles step ("Could not resolve host: github.com", reported as
"Error tunneling to container"), or as `curl: (6) Could not resolve host`
during a devcontainer feature build (`exit code: 2`). `Host is unreachable`
from inside a container is the tell: a **reject**, not a timeout.

The bootstrap writes `/etc/firewalld/zones/docker.xml` with `target="ACCEPT"`,
`<forward/>`, `docker0` and — when it exists — `tailscale0`, then reloads
firewalld and restarts Docker (a reload drops Docker's own chains):

```xml
<zone target="ACCEPT">
  <forward/>
  <interface name="docker0"/>
  <interface name="tailscale0"/>
</zone>
```

Verify:

```bash
firewall-cmd --get-zone-of-interface=docker0        # expect: docker
docker run --rm alpine:3 sh -c 'wget -q -T8 -O /dev/null http://1.1.1.1/; echo $?'
```

Two caveats. If Tailscale is installed **after** the bootstrap, rerun it (it is
idempotent) so `tailscale0` joins the zone. And any later
`firewall-cmd --reload` — e.g. after a firewalld package update — flushes
Docker's rules; restart Docker if containers suddenly lose their network.

On Debian-family hosts firewalld is normally absent, so this step is a no-op
and `docker-ce` manages nftables itself. If **ufw** is installed the same
class of failure appears; check `ufw status verbose` (the smoke test says so).

### A Tailscale exit node blackholes local subnets — including the bridge

While an exit node is active, Tailscale's `ip rule` sends everything through
its own table, and with LAN access **off** it installs the host's local
subnets pointing at the tunnel:

```
$ ip route show table 52
default        dev tailscale0
172.17.0.0/16  dev tailscale0     # the docker bridge
192.168.1.0/24 dev tailscale0     # the LAN
```

So host↔container and container→host are routed into the tunnel and die, while
container↔container (L2) still works. This is a **routing** problem, not a
firewall one — stopping firewalld changes nothing.

```bash
sudo tailscale set --exit-node-allow-lan-access=true
ip route show table 52 | grep -E 'throw|dev tailscale0'
#   throw 172.17.0.0/16   -> falls through to main -> dev docker0
```

`allow-lan` is required whenever the exit node is up; container internet
traffic still goes through the tunnel (and is masked), only local subnets
bypass it. It cannot be scoped to containers: the preference is host-wide.
To stop containers reaching the LAN (or falling back to direct egress if the
tunnel drops), add a firewalld policy rejecting `docker -> FedoraWorkstation`.

### DNS: containers inherit a resolver they cannot use

Docker copies the host's upstream resolvers into every container. With
Tailscale (or another VPN) managing DNS, the host's
`/run/systemd/resolve/resolv.conf` contains a stub such as `100.100.100.100`
that exists only inside the host's network namespace. Containers cannot reach
it, so every lookup stalls until timeout (~40s) and fails. dockerd logs the
hand-off explicitly:

```
detected 127.0.0.53 nameserver, assuming systemd-resolved,
so using resolv.conf: /run/systemd/resolve/resolv.conf
```

The bootstrap only **warns** about this (it changes Docker's behaviour for
every container). To have it write the pin, run:

```bash
DOCKER_DNS="194.242.2.2 1.1.1.1" ./bootstrap.sh
```

or do it by hand:

```bash
sudo tee /etc/docker/daemon.json >/dev/null <<'JSON'
{ "dns": ["194.242.2.2", "1.1.1.1"] }
JSON
sudo systemctl restart docker
```

Trade-off: `*.ts.net` MagicDNS names stop resolving inside containers. (The
template's `runArgs --dns` covers container **runtime** only; feature and
image **builds** use the daemon's resolvers, which is why the daemon-level pin
is the one that matters for `devpod up`.)

The smoke test separates the two layers — name resolution versus egress by
IP — so its message points at the right fix. Knobs:

- `SKIP_CONTAINER_NETWORK_CHECK=1` — skip the smoke test (not recommended;
the check exists to fail early instead of mid-workspace).
- `DOCKER_DNS` — space/comma separated resolvers to pin in
`/etc/docker/daemon.json` (written only when the file does not exist yet).
- `DOCKER_FIREWALLD_ZONE_FILE` — override the zone path; exists so the
function can be exercised without touching `/etc`.

## Layout

| Path | Purpose |
| --- | --- |
| `bootstrap.sh` | Router: detect OS family (fail-closed) → dispatch to a target |
| `targets/fedora.sh` | Fedora host base layer: dnf packages + docker |
| `targets/debian.sh` | Debian-family/Armbian host base layer: apt, docker-ce, gh apt repo |
| `lib/common.sh` | Distro-agnostic host steps (devpod, docker group, nerd font, mise) |
| `template/setup-mise.sh` | Shared toolchain installer — runs on the host and in every devcontainer |
| `template/install-skills.sh` | Shared skill-pack installer — installs configured packs into Pi's global skills dir; runs on the host and in every devcontainer |
| `template/install-pi-packages.sh` | Shared Pi package installer (providers/extensions) — runs on the host and in every devcontainer |
| `template/.devcontainer/` | Copy into each new project: container definition + post-create hook |

## Notes

- **Skill packs.** `install-skills.sh` installs one or more skill packs into
  `~/.agents/skills/`, Pi's global Agent Skills location, so they are
  available in every project on the host and in every container with no
  per-project wiring. Packs are declared as `install_pack` calls in
  `template/install-skills.sh` (option reference at the top of that script);
  a pack's skills are symlinked individually, so a subset can be selected.
  Each pack is kept as a full checkout under `~/.local/share/agent-skills/`,
  because its skills may reference files shared across the pack by relative
  path. Cross-cutting behaviours that no pack carries live in the dotfiles
  `~/.pi/agent/AGENTS.md`.
- **Pi packages (providers).** `install-pi-packages.sh` installs the declared
  Pi packages via `pi install`, pinned to immutable refs. Each package is listed
  under `~/.pi/agent/` and records the source in `~/.pi/agent/settings.json`;
  nothing is vendored into this repo. **Credentials are not provisioned:**
  they live in `~/.pi/agent/auth.json` and are set at runtime.
  A devcontainer's home is ephemeral, so these will be reset.
  Add or remove a package with one `install_pi_package` line in
  `template/install-pi-packages.sh`.
- **LazyVim is the editor.** Neovim +
  `lazygit`/`ripgrep`/`fd`/`fzf`/`tree-sitter` come from the shared mise
  toolchain (identical on host and in containers). The LazyVim config lives in
  the dotfiles repo (`nvim/` → `~/.config/nvim`): language extras are
  declared in `lazyvim.json`, plugins pinned in `lazy-lock.json`, LSP
  servers/formatters in `lua/plugins/tools.lua` (`ensure_installed`).
  Dotfiles `install.sh` runs the headless plugin + Mason sync — the pre-warm
  lives only there (NOT in `post-create.sh`, which runs before dotfiles are
  applied), timeout-bounded and re-applied on every `devpod up`; without it,
  first `nvim` launch self-heals. Extras in use: python, go, typescript,
  yaml, docker, terraform, helm, json, markdown + `dap.core` (debugging),
  `test.core`, `editor.aerial`. `devcontainer.json` ships no extension list —
  the container is editor-agnostic.
- **Nerd Font icons** come from a symbols-only tarball (pinned, SHA-256
  hardcoded in `lib/common.sh`) installed user-local with a fontconfig
  fallback rule — the terminal's font setting does not change. If icons look
  wrong, verify `fc-list | grep "Symbols Nerd Font"` shows two families.
- **tmux**: `.tmux.conf` (dotfiles) sets `tmux-256color` + truecolor and
  undercurl passthrough, which LazyVim needs. Fedora's native terminal
  (Ptyxis/GNOME Terminal) supports both; no alternative terminal required.
- **Container locale.** `post-create.sh` generates the host's locale
  (`en_IE.UTF-8`) once: DevPod's ssh transport forwards the client's
  `LANG`/`LC_*`, and the base image only ships `C.UTF-8`/`en_US.UTF-8`, so
  without it every `devpod ssh` prints `setlocale: LC_ALL: cannot change
  locale`. It's pinned to `en_IE` — change it in `post-create.sh` if the
  host's locale changes.
- **mise is the only tool manager.** Global tools: `mise use -g <tool>`.
  Project overrides: `mise.toml` in the project root. Refresh: `mise upgrade`.
  The base toolset in `setup-mise.sh` is pinned to compatibility boundaries
  (language major.minor, tool majors, 0.x minors, agent CLIs exact), so
  bootstrap is reproducible and `mise upgrade` moves within each pin rather
  than across it — bump a pin deliberately to move on. Global installs are
  isolated from project config (`setup-mise.sh` runs from `$HOME`), so a
  project's pins can never break the base toolchain.
- **Docker runs on the host.** Containers use docker-outside-of-docker: the
  feature mounts the host socket to `/var/run/docker-host.sock` and proxies a
  permission-fixed `/var/run/docker.sock` (sibling containers, shared build
  cache, no privileged mode). Don't add your own socket mount.
- **Container DNS.** The template pins public resolvers (`--dns 1.1.1.1`,
  `--dns 8.8.8.8`) in `devcontainer.json` and `post-create.sh` preflights
  resolution before the first `apt` call. This is deliberate: on a host whose
  resolver is the systemd-resolved stub `127.0.0.53` (host netns only) or
  behind a VPN/tailnet exit, containers otherwise fail to resolve the Ubuntu
  archive and can't pull images. If the container must resolve tailnet
  MagicDNS names, add the tailnet resolver to `runArgs` too; if the host's
  own resolver is already reachable from containers, the entries can be
  dropped.
- **Dotfiles** are applied by DevPod to every workspace. Change with:
  `devpod context set-options -o DOTFILES_URL=... -o DOTFILES_SCRIPT=...`
- **GitHub auth inside containers:** the template installs `gh` in every
  container (the `github-cli` devcontainer feature; the base image does not
  ship it). `gh auth login` on the host does **not** propagate into
  devcontainers. Git over SSH works via agent forwarding (`ssh-add` your key
  on the host); for HTTPS/`gh` inside a container, run `gh auth login` there
  once and paste the same fine-grained PAT the dotfiles installer asks for
  (or pipe it with `gh auth login --with-token`). Auth persists in the
  container's home until recreation. Do **not** run `gh auth setup-git` in
  that flow: it would replace the `store` credential helper the dotfiles
  installer deliberately configures for github.com.
- **ARM64 hosts** (e.g. Orange Pi 5B under Armbian): every component ships
  native aarch64 Linux builds — docker-ce and gh via their arm64-publishing
  apt repos, DevPod's `linux-arm64` binary, and the whole
  mise toolchain including the agent CLIs (herdr's official
  `herdr-linux-aarch64` assets, pi's `pi-linux-arm64` builds). Devcontainers
  built on an ARM host are arm64 images too — host arch = container arch,
  no emulation anywhere. First `devpod up` is just slower than on x86
  (image pulls + toolchain install on SBC-class storage); 16 GB RAM is
  plenty.
