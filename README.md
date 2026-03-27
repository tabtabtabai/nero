# nero

Dockerized OpenCode for a VPS with:

- Traefik reverse proxy when Nero owns `80/443`
- automatic fallback for boxes that already have a reverse proxy
- automatic Let's Encrypt SSL via Cloudflare DNS challenge
- OpenCode web UI exposed on a custom domain
- built-in OpenCode HTTP basic auth for both the UI and API
- persistent agent workspace mounted from the host
- GitHub repo, PR, and gh CLI support inside the agent container
- `zsh` and Oh My Zsh installed on fresh Ubuntu bootstrap
- global `nero` command installed on the VM

## Why this setup

Current OpenCode docs support protecting `opencode serve` and `opencode web` with:

- `OPENCODE_SERVER_PASSWORD`
- optional `OPENCODE_SERVER_USERNAME`

That means the simplest internet-safe default is:

1. Nero uses Traefik when the VM owns ports `80/443`, otherwise it reuses the existing reverse proxy
2. OpenCode handles UI and API password protection
3. The agent only sees its dedicated workspace mount

In self-proxy mode, Nero now uses Traefik file-based routing instead of Docker label discovery to avoid Docker API compatibility nonsense on some VPS setups.

## Project layout

```text
nero/
  nero
  compose.yaml
  .env.example
  AGENTS.md
  config/opencode/opencode.json
  opencode/
    Dockerfile
    entrypoint.sh
  scripts/
    bootstrap-ubuntu-24.sh
    install.sh
    update.sh
  workspace/agent/
```

## Quick start

1. On a fresh Ubuntu 24.04 VPS, run `sudo ./nero bootstrap`
2. Copy `.env.example` to `.env` if you want to prefill infra values
3. Run `./nero install`
4. Answer only the missing onboarding prompts:
   - domain
   - Let's Encrypt email
   - Cloudflare DNS token
   - OpenCode login password
   - GitHub integration and auth details, only when missing from `.env`
5. Open `https://<your-domain>`
6. If you chose OpenAI subscription auth, run `/connect` in OpenCode and select `OpenAI` -> `ChatGPT Plus/Pro`

The installer now also:

- fixes ownership on mounted OpenCode directories automatically
- detects when ports `80/443` are already in use
- skips Nero Traefik automatically on boxes that already have another proxy
- installs the `nero` command into `/usr/local/bin/nero`
- prepares `gh`, git identity, and SSH material for GitHub workflows
- reuses values already present in `.env` instead of asking every time
- writes shell-safe `.env` values so names with spaces do not break reinstall
- deploys in place when run from a git clone, so `nero update` always tracks the real repo
- installs or upgrades Docker Engine and Docker Compose from Docker's official Ubuntu repo

## Fresh Ubuntu 24 VM

If you just cloned the repo onto a clean Ubuntu 24.04 server:

```bash
sudo bash ./scripts/bootstrap-ubuntu-24.sh
cp .env.example .env
nano .env
./nero install
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

- `self`: Nero starts Traefik and manages TLS itself
- `external`: another proxy already owns `80/443`, so Nero only starts OpenCode on `127.0.0.1:4096`

When `external` mode is detected, point your existing proxy at `127.0.0.1:4096` for the Nero hostname.

## Commands

Use the repo wrapper command for common tasks:

```bash
./nero bootstrap
./nero install
./nero update
```

After install, the same wrapper is available globally:

```bash
nero install
nero update
```

`./nero update` does two things:

- pulls the latest repo changes with `git pull --ff-only`
- reruns the full install workflow so permissions, proxy mode, and containers are repaired from the repo state

If Nero was installed from a git clone, the repo itself is the deployment source.
That avoids stale copies under `/opt` and keeps `nero update` honest.

## GitHub integration

Nero can prepare GitHub access during install so the agent can clone repos,
write branches, and create pull requests.

The automated setup now:

- installs `gh` on the host and in the agent container
- prompts for git author name and email
- optionally stores a GitHub token for API and `gh` access
- writes a dedicated git config that uses `gh auth git-credential`
- optionally generates an SSH keypair in `config/ssh/`

Recommended path:

- use a fine-grained GitHub token with repository and pull request access
- let Nero generate an SSH key for SSH remotes

After install, if you generated an SSH key, add the printed public key to GitHub.

## One-command install target

The installer is designed so this can later be wrapped as a one-liner like:

```bash
curl -fsSL https://your-domain/install-nero.sh | bash
```

For now it assumes the project files are already present on the VPS.

## Authentication

This stack intentionally uses OpenCode's built-in server auth instead of adding a second password layer at Traefik.

- `OPENCODE_SERVER_PASSWORD` secures the UI and API
- `OPENCODE_SERVER_USERNAME` defaults to `opencode`
- TLS is terminated at Traefik

Optional hardening you can add later:

- Cloudflare Access in front of the domain
- IP allowlists
- Fail2ban on the VPS

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

The future admin service for integrations and permissions should be added as a second hostname, for example:

- `ADMIN_DOMAIN` -> admin UI

## Persistence

- OpenCode config: `config/opencode/`
- OpenCode data: `data/opencode/`
- Traefik ACME data: `data/traefik/`
- Agent workspace: `workspace/agent/`

## Notes

- The container starts OpenCode in `/workspace/agent`
- The default model is configured from installer onboarding via `OPENCODE_MODEL`
- OpenCode provider credentials from `/connect` are persisted in the mounted data directory
- Mounted config/data/workspace directories are auto-owned by the `opencode` container user during install
- `AGENTS.md` gives the instance a default personality inspired by OpenClaw's `SOUL.md` style
- The default OpenCode permissions config is conservative and asks before sensitive actions
- SSL uses the Cloudflare DNS challenge, so certificate renewal stays automatic
