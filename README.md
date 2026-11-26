# agent-vm

Run Claude Code, opencode or any command in a [nix-vm](https://github.com/majchrzamemil/nix-vm) microVM (qemu + KVM) on a non-NixOS Linux host. The guest is NixOS with its own kernel and sees only what is shared into it.

## Prerequisites

- **Nix** with flakes enabled.
- **`/dev/kvm`** accessible to your user (`ls -l /dev/kvm`).
- **Unprivileged user namespaces** (virtiofsd runs unprivileged). Fedora allows them by default; Ubuntu 23.10+ restricts them through AppArmor.
- **x86_64** host (the opencode binary is linux-x64).
- **`secret-tool`** (libsecret) for the tokens.

## Setup

```sh
ln -s "$PWD/agent-vm" ~/.local/bin/agent-vm
agent-vm setup ~/src/myproject                  # each arg: a flake whose devShells.x86_64-linux.default is baked in
# Secrets live in the keyring; each launch fetches them on the host and injects them as env vars.
secret-tool store --label 'agent-vm GH_TOKEN' service agent-vm key GH_TOKEN                # fine-grained PAT
secret-tool store --label 'agent-vm claude' service agent-vm key CLAUDE_CODE_OAUTH_TOKEN   # from `claude setup-token`
```

More secrets: store each under `service agent-vm key NAME` and list it in `local/flake.nix` as `extraSecrets = [ "NAME" ];`. The guest gets it as env var `NAME`.

SSH for the agent: a dedicated key at `~/.config/agent-vm/ssh/id_ed25519` (optional).

```bash
mkdir -p ~/.config/agent-vm/ssh
ssh-keygen -t ed25519 -f ~/.config/agent-vm/ssh/id_ed25519 -C agent-vm
```

- Each launch loads it into a separate `ssh-agent` (`$XDG_RUNTIME_DIR/agent-vm-ssh.sock`), which nix-vm forwards over vsock. The key file never enters the guest, so the guest can sign while it runs but cannot copy the key.
- The host's own `SSH_AUTH_SOCK` is never forwarded. The key is removed from the dedicated agent when the last launch using it exits; a passphrase-protected key prompts on each first load.
- `--no-secrets` leaves the agent out.
- Pin the hosts the agent talks to with `programs.ssh.knownHosts` in `local/flake.nix` (`extraModules`).
- Scope the key on the server: a low-privilege user, `restrict,from=...,command=...` in `authorized_keys`, read-only deploy keys.
- GitHub stays on HTTPS: guest git rewrites `git@github.com:` remotes to HTTPS.

`setup` writes the machine-specific config to `local/` (gitignored):

- `local/flake.nix`: your user, home, the VM size and the dev-shell flakes. It calls `lib.mkAgentVm` from this repo. Edit it freely, for example to add `extraModules`. `setup --force` regenerates it.
  - `--vcpu N` and `--mem MiB` set the VM size (default: all CPUs, half the RAM).
  - `--nix-vm DIR|REF` overrides the nix-vm input, for example with a local checkout.
  - A directory argument becomes `git+file://` (a git repo root) or `path:`.
- `local/refuse.txt`: extra workspaces to refuse without `--force`, one absolute path per line. A directory that holds all your repos is a good candidate.

Every launch relocks `local/flake.nix`, so the guest follows the HEADs of local inputs (this repo, local dev shells).

## Usage

The workspace is `$PWD`, or `-w DIR`. Each launch is a fresh VM (about 10 s to boot), wiped on exit.

```sh
agent-vm claude                          # interactive Claude on the VM serial console; the VM powers off when it exits
agent-vm claude -p "run just unit and fix failures"   # headless; output streamed, exit code returned
agent-vm --yolo claude -p "..."          # --dangerously-skip-permissions (opencode: --auto)
agent-vm opencode                        # interactive opencode TUI
agent-vm opencode run "..."              # headless opencode
agent-vm run 'just unit'                 # any command, headless
agent-vm console                         # login shell on the serial console (`poweroff` to leave)
agent-vm --no-secrets ...                # no keyring tokens, opencode auth.json or SSH agent
agent-vm --no-update ...                 # keep the current Claude Code and opencode pins
agent-vm vm list                         # raw nix-vm helper
```

Headless runs stop after `--timeout` seconds (default 4 h).

**Pasting screenshots:** in an interactive `agent-vm claude` or `agent-vm opencode`, Ctrl+V pastes the host clipboard's image.

- The guest's `xclip` is a shim. On request, the launcher reads the host clipboard (`wl-paste` on Wayland, else `xclip`) and passes only an `image/png` through the stage.
- Text paste goes through the terminal as usual. Copying out of the guest uses the terminal too (OSC 52).
- While an interactive session runs, anything in the guest can request the current clipboard image, not only your Ctrl+V.

## Agent config and memory

- **Copied in at every launch** to `~/.cache/agent-vm/run.*/stage` (reflinked on btrfs) and shared at the guest's `~/.agent-vm`. The copy is deleted when the VM exits.
  - In the guest, `~/.claude`, `~/.config/opencode`, `~/.local/share/opencode` and `~/.local/state/opencode` are symlinks into it.
  - from `~/.claude`: `CLAUDE.md`, `skills/`, `agents/`, `commands/`, `hooks/`, `plugins/`, `output-styles/`
  - `settings.json`, with `env`, `sandbox` and `hooks` removed, because host hook binaries are not in the guest
  - a minimal `.claude.json`: onboarding done and the workspace trusted. Your host `~/.claude.json` is never copied.
  - opencode: all of `~/.config/opencode` except `service.json`, plus `~/.local/state/opencode/model.json` (the recently used model)
  - opencode `auth.json`, which holds every opencode provider login. It is copied in only, so token refreshes in the guest never reach the host. `--no-secrets` leaves it out. Literal keys in `opencode.json` still go in.
  - `user.name` and `user.email` from your host git config.
- **Memory (`projects/*/memory`):**
  - Only the workspace's own project memory is staged (the keys for the workspace and the launch directory).
  - After the run the host diffs top-level regular `*.md` files and asks `[y/N]`.
  - Without a TTY, or on any answer other than `y`, the changes are discarded.
- **Claude sessions** (`projects/<key>/*.jsonl` and session dirs) persist per workspace in `~/.local/state/agent-vm/sessions/<key>`, so `agent-vm claude --continue` / `--resume` work in a later VM.
  - They are saved when the launcher exits, including on SIGHUP/SIGTERM. A SIGKILLed launcher loses that run's sessions.
  - Only regular files are kept. They never go into the host's `~/.claude`, so host Claude does not see guest transcripts.
- **opencode sessions** (the guest's `~/.local/share/opencode` minus `auth.json`) persist per workspace in `~/.local/state/agent-vm/opencode/<key>`, saved the same way.
  - The whole directory is replaced on exit, so of two concurrent launches in one workspace only the last to exit keeps its sessions.
- **Guest agent versions follow the host:**
  - Claude Code is pinned by `claude-manifest.json` to the host's `claude --version`.
  - opencode is pinned in `flake.nix` to the host's installed `@opencode-ai/plugin` version, so host plugins keep working.
  - Every launch re-pins both and leaves the change uncommitted in this repo. `--no-update` skips this.
  - A missing host tool or a failed download keeps the old pin and does not stop the launch.
- **Updating:** `agent-vm update-deps` bumps the flake inputs to their latest revisions, re-pins both agents, then builds a bare VM to check.
- **Git in the guest:** HTTPS via `gh` and `GH_TOKEN`; SSH remotes are rewritten to HTTPS. Commits are unsigned; re-sign on the host before merging.
- **After every run** the launcher lists new or replaced `.git` entries and greps their config for dangerous keys.

## What the `agent` VM sees

- **The workspace:** read-write, at the same absolute path.
  - The workspace is passed with `--mount`, arrives at `/mnt/workspace`, and is bind-mounted to its host path.
  - Launching from a parent directory exposes every repo under it.
- **Workspace guard:** refused if it is `$HOME` or an ancestor of it, a dot-dir under `$HOME`, inside a credential dir such as `.ssh`, `.config` or `.cargo`, or listed in `local/refuse.txt`. `--force` skips the guard.
- **Host `/nix/store`:** read-only. Guest builds go to a per-instance 32 GiB overlay disk.
  - The dev shells given to `setup` are baked into the guest closure, so `nix develop` does not refetch them.
  - Other repos' dev shells are downloaded into that overlay disk on each launch.
- **`~/.cargo/target` (`CARGO_TARGET_DIR`):** an overlay.
  - The lower layer is the host's `~/.cargo/target`, served read-only by virtiofsd (`--readonly`). Guest root cannot remount it writable.
  - The upper layer is a per-instance 64 GiB volume. Guest build output never reaches the host, so the guest cannot plant artifacts that a host `cargo` would reuse and execute.
  - Host artifacts give the guest a warm cache.
  - Building on the host while a VM runs changes the lower layer under the overlay. The overlayfs behaviour for that case is undefined.
  - The guest can read every host build artifact in `~/.cargo/target`, including those of other projects.
- **Files the guest writes into the workspace** are owned by your host uid. virtiofsd squashes every guest uid and gid onto yours.
- **Never shared:** the host home, `~/.ssh`, the host's ssh-agent, and hardware keys.
- **Agent SSH key:** reachable only through the dedicated agent. While any keyed launch runs, nix-vm's host relay serves every `agent` VM instance on its vsock port, so root in a concurrent `--no-secrets` guest could reach it too.

## Limits (to do)

- **No read-only `.git` hooks/config yet** (only the post-run tripwire).
- **No secret masking yet.**
- **No egress filtering yet.**
- **The guest can write anything in the workspace** that you may later run on the host: `build.rs`, `justfile`, git hooks. Review the diff before building on the host.

## License

MIT, see [LICENSE](LICENSE).
