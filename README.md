# nero

OpenCode on the host with Docker only for Traefik:

- Traefik reverse proxy when Nero owns `80/443` (TLS via Cloudflare DNS challenge)
- automatic fallback for boxes that already have a reverse proxy
- OpenCode web UI on a custom domain; Traefik proxies to host OpenCode via `host.docker.internal`
- built-in OpenCode HTTP basic auth for both the UI and API
- persistent agent workspace on the host (`~/nero/workspace` by default)
- GitHub repo, PR, and `gh` CLI support (configs under `/opt/nero/config`, symlinked into the OpenCode service user’s home)
- host OpenCode managed by `systemd` (`nero-opencode.service`); `nero update` refreshes the `opencode-ai` npm package and restarts the service
- Node.js 22 from NodeSource when needed, `opencode-ai` installed globally with `npm`
- `zsh` and Oh My Zsh on fresh Ubuntu bootstrap
- global `nero` command on the VM

## Why this setup

Current OpenCode docs support protecting `opencode serve` and `opencode web` with:

- `OPENCODE_SERVER_PASSWORD`
- optional `OPENCODE_SERVER_USERNAME`

That means the simplest internet-safe default is:

1. Nero uses Traefik when the VM owns ports `80/443`, otherwise it reuses the existing reverse proxy
2. OpenCode handles UI and API password protection
3. The agent uses the host workspace directory with full host tooling (install any extra packages on the VM yourself)

In self-proxy mode, Nero uses Traefik as the machine-level edge with both file-based routes for Nero itself and Docker label discovery for hosted workloads like Appius workspaces.

Default deployment mode is `self`, so Nero starts Traefik and manages SSL unless you explicitly set `TRAEFIK_MODE=external` or `TRAEFIK_MODE=auto`.

## Project layout

```text
nero/
  nero
  compose.yaml
  .env.example
  AGENTS.md
  config/opencode/opencode.json
  scripts/
    run-opencode-host.sh
    bootstrap-ubuntu-24.sh
    doctor.sh
    install.sh
    update.sh
  templates/workspace/
  # agent workspace is created in the installing user's home directory
```

## Quick start

1. On a fresh Ubuntu 24.04 VPS, optionally run `sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/PatrickRogg/nero/main/scripts/bootstrap-ubuntu-24.sh)"`
2. Run `curl -fsSL https://raw.githubusercontent.com/PatrickRogg/nero/main/scripts/install-remote.sh | bash`
3. Answer only the missing onboarding prompts:
   - domain
   - Let's Encrypt email
   - Cloudflare DNS token
   - OpenCode login password
   - GitHub integration and auth details, only when missing from `.env`
4. Open `https://<your-domain>`
5. If you chose OpenAI subscription auth, run `/connect` in OpenCode and select `OpenAI` -> `ChatGPT Plus/Pro`

The installer now also:

- fixes ownership on OpenCode config, data, and workspace directories automatically
- installs or upgrades Node.js (NodeSource 22.x) when needed, then `opencode-ai` globally (`OPENCODE_CLI_VERSION`, default `latest`)
- installs and enables `nero-opencode.service` (restarted on every `nero install` / `nero update`)
- detects when ports `80/443` are already in use
- skips Nero Traefik automatically on boxes that already have another proxy
- installs the `nero` command into `/usr/local/bin/nero`
- prepares `gh`, git identity, and SSH material for GitHub workflows
- reuses values already present in `.env` instead of asking every time
- writes shell-safe `.env` values so names with spaces do not break reinstall
- installs into `/opt/nero` by default and refreshes that directory during updates
- installs or upgrades Docker Engine and Docker Compose from Docker’s official Ubuntu repo (Traefik only)

## Fresh Ubuntu 24 VM

If you want the host prep step on a clean Ubuntu 24.04 server:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/PatrickRogg/nero/main/scripts/bootstrap-ubuntu-24.sh)"
```

The bootstrap script installs the host dependencies Nero expects:

- Docker Engine
- Docker Compose plugin
- automatic Docker/Compose upgrades on rerun
- gh, git, curl, rsync, nano, zsh
- Oh My Zsh for the invoking non-root user when available
- UFW with `OpenSSH`, `80/tcp`, and `443/tcp` allowed

## Proxy modes

Nero supports two install modes automatically:

- `self`: Nero starts Traefik and manages TLS itself; OpenCode listens on `0.0.0.0:${OPENCODE_BIND_PORT:-4096}` so Traefik in Docker can reach the host via `host.docker.internal`
- `external`: another proxy already owns `80/443`, so OpenCode listens on `127.0.0.1:${OPENCODE_BIND_PORT:-4096}` only

Default: `self`

When `external` mode is detected, point your existing proxy at `127.0.0.1:4096` for the Nero hostname.

You can also set:

- `TRAEFIK_MODE=self` to force Nero-managed SSL
- `TRAEFIK_MODE=auto` to let Nero decide based on port usage
- `TRAEFIK_MODE=external` to reuse another reverse proxy intentionally

## Commands

Use the global command after install:

```bash
nero doctor
nero install
nero update
```

One-line install and update:

```bash
curl -fsSL https://raw.githubusercontent.com/PatrickRogg/nero/main/scripts/install-remote.sh | bash
curl -fsSL https://raw.githubusercontent.com/PatrickRogg/nero/main/scripts/install-remote.sh | bash -s -- update
```

`nero update` does two things:

- downloads the latest Nero source archive into a temporary directory
- reruns the full install workflow so permissions, proxy mode, Traefik, and the host OpenCode service (`opencode-ai` npm version + `systemctl restart nero-opencode`) stay aligned with the latest source

The installer itself is idempotent: it removes any legacy `nero-opencode` Docker container and `/opt/nero/opencode` if present, bumps the internal stack signature when `scripts/install.sh` or `scripts/run-opencode-host.sh` change so Traefik is recreated when needed, and resolves `OPENCODE_UID` to a real passwd account when the workspace is owned by an orphan numeric uid.

That keeps the live install under `/opt/nero` without requiring the Nero repo itself to be cloned on the server.

If you are developing Nero itself, local repo commands still work:

```bash
./nero bootstrap
./nero doctor
./nero install
./nero update
```

## Workspace layout

Defaults live in `templates/workspace/` and are copied into the host workspace on install (`~/nero/workspace` by default, using `cp -an` so your files are never overwritten).

| Path | Purpose |
|------|---------|
| `drop/` | Files to process immediately |
| `knowledge/` | Raw archive / library |
| `memory/` | Distilled notes (`_index.md`, `me.md`, …) |
| `output/` | Generated deliverables (`YYYY-MM-DD-*.md`) |
| `code/` | Repos and experiments |
| `scripts/` | Agent-created scripts; `scripts/defaults/` has extraction helpers |
| `.agents/` | Navigation, `SOUL.md` (voice and values), local skills |
| `Agents.md` | Full workspace rules (memory vs knowledge, Appius docs, parallel tasks) |

Important conventions:

- Nested `.agents/` folders are fine when a subdirectory needs local context.
- `nero install` migrates a legacy `workspace/agent/` or `workspace/agents/` directory from inside the Nero project into the host workspace if present.
- The style target for future UI and content surfaces should be closer to Notion than Word: clean, lightweight, structured, and calm.

## GitHub integration

Nero can prepare GitHub access during install so the agent can clone repos,
write branches, and create pull requests.

The automated setup now:

- installs `gh` on the host
- prompts for git author name and email
- optionally stores a GitHub token for API and `gh` access
- writes a dedicated git config that uses `gh auth git-credential`
- optionally generates an SSH keypair in `config/ssh/`

Recommended path:

- use a fine-grained GitHub token with repository and pull request access
- let Nero generate an SSH key for SSH remotes

After install, if you generated an SSH key, add the printed public key to GitHub.

## One-command install target

The default install path is already a one-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/PatrickRogg/nero/main/scripts/install-remote.sh | bash
```

It downloads the latest archive from GitHub, installs into `/opt/nero`, and leaves `nero` available globally.

## Authentication

This stack intentionally uses OpenCode's built-in server auth instead of adding a second password layer at Traefik.

- `OPENCODE_SERVER_PASSWORD` secures the UI and API
- `OPENCODE_SERVER_USERNAME` defaults to `opencode`
- TLS is terminated at Traefik

Optional hardening you can add later:

- Cloudflare Access in front of the domain
- IP allowlists
- Fail2ban on the VPS

## SSL note

If Nero reports `Proxy mode: external`, SSL is handled by your existing reverse proxy, not by Nero.

In that mode, a browser warning like `Not secure` usually means the external proxy is serving the hostname without a valid certificate yet. Nero OpenCode is only listening on the loopback address and port from `.env`; TLS is entirely up to that proxy.

## Provider onboarding

The installer handles provider and model setup interactively so `.env.example` can stay minimal.

Nero now defaults to OpenAI subscription auth with `openai/gpt-5.4` and only
prompts for missing install values. If `.env` already contains domain, auth,
and GitHub settings, rerunning install should be quiet.

Current default path:

- provider: OpenAI
- model: `openai/gpt-5.4`
- auth: ChatGPT Plus/Pro subscription via `/connect`

Why this default:

- Default to the newest OpenAI model for the shortest high-quality setup path
- OpenCode supports OpenAI account auth via `/connect` using `ChatGPT Plus/Pro`
- provider credentials are stored by OpenCode in persistent auth storage instead of forcing an API key into `.env`
- API keys still work, but subscription auth is the cleaner default when you already have the Codex/ChatGPT plan

The installer currently supports:

- OpenAI subscription auth
- OpenAI API key
- Anthropic
- OpenRouter

## Domains

This initial scaffold exposes one hostname:

- `OPENCODE_DOMAIN` -> OpenCode web UI and API

Nero also owns the shared external Docker edge network `nero-edge`, which other stacks can join when they need Traefik routing through the host-level proxy.

The future admin service for integrations and permissions should be added as a second hostname, for example:

- `ADMIN_DOMAIN` -> admin UI

## Persistence

- OpenCode config: `config/opencode/`
- OpenCode data: `data/opencode/`
- Traefik ACME data: `data/traefik/`
- Agent workspace: `~/nero/workspace/` by default (`WORKSPACE_HOST_DIR` overrides it)
- Git worktrees vs OpenCode: run `nero sync-oc-worktrees` (runs `scripts/oc-sync-worktrees.sh` from the Nero install) to register linked git worktrees in OpenCode’s `sandboxes` list in SQLite (`data/opencode/opencode/opencode.db` under the install dir when present).

## Notes

- OpenCode runs under `systemd` with `WorkingDirectory` set to `WORKSPACE_HOST_DIR` (same tree the installer chowns to `OPENCODE_UID`, default `1000`)
- In `self` mode, OpenCode listens on `0.0.0.0:${OPENCODE_BIND_PORT:-4096}` on the **host** (systemd `nero-opencode.service`), not in Docker. Traefik reaches it at `host.docker.internal` / the Docker bridge. If **UFW** is enabled, the installer adds a rule so the `NERO_EDGE_NETWORK` subnet can reach that port (otherwise HTTPS works but the UI returns bad gateway).
- The default model is configured from installer onboarding via `OPENCODE_MODEL`
- OpenCode provider credentials from `/connect` are persisted under `data/opencode`
- Config, data, and workspace directories are auto-owned by `OPENCODE_UID` during install
- `AGENTS.md` gives the instance a default personality; `~/nero/workspace/.agents/SOUL.md` holds voice and values for the workspace by default
- OpenCode permissions default to allow (no approval prompts); adjust `config/opencode/opencode.json` if you want stricter gates
- SSL uses the Cloudflare DNS challenge, so certificate renewal stays automatic
