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
(`.devcontainer/`, `setup-mise.sh`, `install-skills.sh`,
`install-pi-packages.sh`) in the project.
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
- **The MCP server is pinned** in the dotfiles `pi/mcp.json` (not `@latest`):
  it is spawned from an unpinned supply chain otherwise. Bump it there
  deliberately.
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
   skill packs (`install-skills.sh`), installs the declared Pi packages
   (`install-pi-packages.sh`), then applies your
   project's `mise.toml` pins if present. This is the slow step on first
   creation (~1–2 min).
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

DevPod is only as good as the host's container network. Three things can look
like "devpod is broken" and are unrelated: the firewalld zone, a Tailscale
exit node's routing, and DNS. The bootstrap configures the first two and pins
the third, then proves the result with a smoke test.

### `docker0` in no firewalld zone, and forward rules (Fedora)

Docker creates its `docker` zone at runtime and then logs:

```
dockerd: Firewalld: docker zone already exists, returning
```

i.e. it never adds `docker0` to it. An interface in no zone matches no
firewalld policy, so forwarded traffic from the bridge is **rejected**: the
daemon looks healthy and image pulls work (they use the host's netns), and
containers can talk to each other (pure L2), but containers cannot reach the
host or the internet. Symptoms: `git clone` **exit 128** in DevPod's dotfiles
step ("Error tunneling to container"), or `curl: (6) Could not resolve host`
during a devcontainer feature build. `Host is unreachable` from inside a
container is the tell: a **reject**, not a timeout.

The bootstrap keeps zone `docker` (`target="ACCEPT"`, `<forward/>`) with
**only `docker0`** in it — `tailscale0` is deliberately removed, because
`target=ACCEPT` would accept every tailnet→host port. Forwarding needs are then
met by direct FORWARD rules instead:

```
-i docker0 -o tailscale0 -j ACCEPT
-i br-+    -o tailscale0 -j ACCEPT
-i tailscale0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-i docker0 -o br-+ -j ACCEPT
-i br-+    -o docker0 -j ACCEPT
-i br-+    -o br-+ -j ACCEPT
```

`br-+` covers the per-project bridges Docker creates (compose networks), not
just `docker0`. The rules are added at runtime and permanently; a firewalld
reload drops Docker's own chains, so the bootstrap reloads and restarts Docker
only when something actually changed.

Verify:

```bash
firewall-cmd --get-zone-of-interface=docker0        # expect: docker
firewall-cmd --direct --get-all-rules | grep FORWARD
docker run --rm alpine:3 sh -c 'getent hosts github.com; nc -z -w8 1.1.1.1 443'
```

Any later `firewall-cmd --reload` (e.g. after a firewalld update) flushes
Docker's rules; restart Docker afterwards if containers lose their network. On
Debian-family hosts firewalld is usually absent and this step is a no-op; if
**ufw** is present it can block the same hop (`ufw status verbose`).

### Container egress guard: no leak with an exit node, normal with it off

Requirement: with a Tailscale exit node configured, container traffic must not
leave by any path except the tunnel; with the exit node switched off,
containers must work normally over the host's uplink.

That is implemented as **routing**, not filtering. Every Docker bridge subnet
gets an `ip rule` into table 100, whose only default route is `tailscale0`
while an exit node is configured (`blackhole` if the tunnel interface is
missing). With the exit node off the route is removed, the lookup finds nothing,
and traffic falls through to the main table. Each bridge subnet also gets a
`throw` route in table 100, so traffic between the workspace (`docker0`) and
per-project compose networks (`br-*`) still takes the local bridge instead of
the tunnel default. Routing was chosen over a firewalld
REJECT because rule ordering between zones, policies and direct rules is not
obvious and would need empirical verification; `ip route get` is directly
checkable.

```
ip rule show                          # from <bridge subnet> lookup 100
ip route show table 100               # default dev tailscale0 (= masked)
ip route get 192.168.1.1 from 172.17.0.2   # which table/path a container would use
```

The logic lives in `lib/container-egress-guard.sh` (linted, diffable, testable)
and the bootstrap installs it as `/usr/local/sbin/container-egress-guard` plus a
systemd oneshot + 5 s timer. Properties:

- **Fail-closed**: if `tailscale debug prefs` cannot be read, egress stays in
  the tunnel (containers lose internet rather than leak).
- **Keyed on the preference, not the route**: `ExitNodeID` being set keeps the
  guard active even if Tailscale briefly withdraws the exit-node route, so a
  Mullvad outage does not fall back to direct egress.
- **Bounded window**: toggling the exit node takes up to 5 s to follow, and a
  *newly created* bridge subnet egresses via the uplink until the next
  reconcile (~5 s). Run `sudo /usr/local/sbin/container-egress-guard` manually
  and check `ip route show table 100` before relying on the state.
- **IPv4 only**, matching Docker's default bridge. The bootstrap writes
  `"ipv6": false` into `daemon.json` and warns if a Docker network has IPv6
  enabled; v6 container egress would bypass this guard.
- Applying it flushes table 100; nothing else should use that table.
- It does **not** protect the host's own traffic, and it cannot survive a
  container that has the Docker socket (which can run
  `tailscale set --exit-node=`). See "trust boundary" below.

Skip with `SKIP_CONTAINER_EGRESS_GUARD=1`. If the tunnel interface is missing
while an exit node is configured, the guard fails closed (`blackhole`);
`CONTAINER_EGRESS_GUARD_TUNNEL_ABSENT=direct` relaxes that to "use the uplink"
when tailscaled is simply stopped.

### DNS: containers inherit a resolver they cannot use

Docker copies the host's upstream resolvers into every container. With
Tailscale (or another VPN) managing DNS, `/run/systemd/resolve/resolv.conf`
contains a stub such as `100.100.100.100` that exists only inside the host's
network namespace. Containers cannot reach it, so every lookup stalls (~40 s)
and fails. dockerd logs the hand-off:

```
detected 127.0.0.53 nameserver, assuming systemd-resolved,
so using resolv.conf: /run/systemd/resolve/resolv.conf
```

When a tailnet stub is detected the bootstrap pins
`/etc/docker/daemon.json`, because with the egress guard active a resolver
reached over the LAN would break every lookup. The default is `1.1.1.1`
(neutral, reachable through any exit node) plus `"ipv6": false`. Overrides:

- `DOCKER_DNS="a.b.c.d ..."` — different resolvers. For a Mullvad exit node:
  `DOCKER_DNS="194.242.2.2 1.1.1.1"`.
- `DOCKER_DNS=""` (empty) is an error, not "use the default".
- `SKIP_DOCKER_DNS=1` — warn only (lookups will fail while the guard is active).
- An existing `daemon.json` is never modified; remove it to let the bootstrap
  write it.

Trade-off: `*.ts.net` MagicDNS names stop resolving inside containers.

### Trust boundary

The workspace container has the host's Docker socket, passwordless sudo, and
`label=disable`. It is host-root by design; the firewall and routing work above
is about correctness and leak-prevention, not containment. A container that can
reach the Docker socket can also disable the exit node, so "never leaks" is not
an enforceable property against a compromised container.

The smoke test separates the layers (name resolution vs egress by IP) so its
message points at the right fix. Knobs:

- `SKIP_CONTAINER_NETWORK_CHECK=1` — skip the smoke test (not recommended).
- `SKIP_CONTAINER_EGRESS_GUARD=1` — do not install the egress guard.
- `CONTAINER_EGRESS_GUARD_TUNNEL_ABSENT=block|direct` — see the guard section.
- `DOCKER_DNS` / `SKIP_DOCKER_DNS` — see above.
- `DOCKER_FIREWALLD_ZONE_FILE`, `DOCKER_DAEMON_JSON`, `DOCKER_RESOLV_CONF`,
  `CONTAINER_EGRESS_GUARD_SCRIPT/_UNIT/_TIMER` — path overrides used by the
  tests (they keep the suite away from `/etc`).

### Tests

`./tests/run.sh` runs the stub suite offline in seconds, with no sudo and no
host mutation: `firewall-cmd`, `ip`, `tailscale`, `docker`, `systemctl` and
`sudo` are fakes writing to a temp dir, so it is safe on any machine —
including one whose networking you are mid-debugging.

Run it **before** pointing a changed `lib/common.sh` or
`lib/container-egress-guard.sh` at a real host: it exercises the decisions
(which rules, which routes, which errors) without the failure mode that costs
you the machine. It also covers the `DOTFILES_URL` guards in `lib/common.sh`.

It proves **intent, not host state** — a rule that parses but forwards wrongly
still passes — and nothing enforces it, because the repo has no CI. Running it
is a habit; the end-to-end check remains a real bootstrap.

```bash
./tests/run.sh
```

On a real host, run the bootstrap with the exit node **on**, then:

```bash
sudo /usr/local/sbin/container-egress-guard
ip rule show | grep 'lookup 100'      # one rule per bridge subnet
ip route show table 100               # throws + default dev tailscale0
docker run --rm alpine:3 wget -qO- https://am.i.mullvad.net/ip   # exit-node IP
```

Switch the exit node off, wait for a tick, and confirm `ip route show table 100`
is empty and the container reports the host's own address. Re-run the bootstrap
and confirm it prints `already configured` and does **not** reload firewalld or
restart Docker (that is the direct-rule idempotency contract).

## Layout

| Path | Purpose |
| --- | --- |
| `bootstrap.sh` | Router: detect OS family (fail-closed) → dispatch to a target |
| `targets/fedora.sh` | Fedora host base layer: dnf packages + docker |
| `targets/debian.sh` | Debian-family/Armbian host base layer: apt, docker-ce, gh apt repo |
| `lib/common.sh` | Distro-agnostic host steps (devpod, docker group, nerd font, mise) |
| `lib/container-egress-guard.sh` | Container egress guard (installed to `/usr/local/sbin`) |
| `tests/` | Stub-driven tests: `./tests/run.sh` (no sudo, no host mutation) |
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
  they live in `~/.pi/agent/auth.json` and are set at runtime, and a
  devcontainer's home is ephemeral, so they are reset on recreation.
  `install-pi-packages.sh` prints each provider's setup step at the end of
  every run, so per-provider instructions live there rather than being
  duplicated here.
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
  first `nvim` launch self-heals. The enabled extras are declared in the
  dotfiles `nvim/lazyvim.json`, not here. `devcontainer.json` ships no
  extension list — the container is editor-agnostic.
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
