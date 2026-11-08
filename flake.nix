{
  description = "agent-vm: coding-agent sandboxes on nix-vm microVMs (non-NixOS Linux host)";

  inputs = {
    nix-vm.url = "github:majchrzamemil/nix-vm";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    microvm.url = "github:microvm-nix/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
    nix-vm.inputs.nixpkgs.follows = "nixpkgs";
    nix-vm.inputs.home-manager.follows = "home-manager";
    nix-vm.inputs.microvm.follows = "microvm";
  };

  outputs =
    inputs@{ nix-vm, ... }:
    {
      # Called from the config flake `agent-vm setup` writes; returns the fleet's packages
      # (`microvm-agent` and the `nix-vm` helper).
      lib.mkAgentVm =
        {
          user,
          home ? "/home/${user}",
          configDir,
          vcpu ? 4,
          mem ? 8192,
          devShells ? [ ],
          extraModules ? [ ],
          # Extra keyring keys (`service agent-vm key NAME`), injected as env var NAME.
          extraSecrets ? [ ],
        }:
        let
          workspaceMount = "/mnt/workspace";
          # Per-launch stage the launcher builds on the host (config copies, workspace path, flags).
          stage = "${home}/.agent-vm";
          # Same path as the host's cargo target-dir, so host artifacts stay fresh.
          cargoTarget = "${home}/.cargo/target";
          hostCargoTarget = "/mnt/host-cargo-target";

          # Host target is the read-only lower layer; guest writes land on a per-instance volume and
          # never reach the host, so the guest cannot plant artifacts the host would later execute.
          cargoTargetOverlay =
            { pkgs, ... }:
            {
              microvm.volumes = [
                {
                  image = "cargo-target.img";
                  mountPoint = "/var/lib/cargo-target";
                  size = 65536;
                }
              ];
              environment.variables.CARGO_TARGET_DIR = cargoTarget;
              systemd.services.cargo-target-overlay = {
                wantedBy = [ "multi-user.target" ];
                before = [ "multi-user.target" ];
                unitConfig.RequiresMountsFor = [
                  "/var/lib/cargo-target"
                  hostCargoTarget
                ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                };
                path = [ pkgs.util-linux ];
                script = ''
                  install -d -o ${user} -g users /var/lib/cargo-target/upper ${home}/.cargo ${cargoTarget}
                  install -d /var/lib/cargo-target/work
                  mount -t overlay overlay \
                    -o lowerdir=${hostCargoTarget},upperdir=/var/lib/cargo-target/upper,workdir=/var/lib/cargo-target/work \
                    ${cargoTarget}
                '';
              };
            };

          # Claude and opencode run from config copies in the stage, linked to their usual paths.
          # Interactive launches drop `tty` (serial console has no window size, so `resize` asks the
          # terminal) and optionally `cmd`, auto-run once; the VM powers off after.
          agentModule =
            { pkgs, ... }:
            let
              claude-code = pkgs.claude-code.override {
                manifest = builtins.fromJSON (builtins.readFile ./claude-manifest.json);
              };
              # Pinned to a release so host plugins built against @opencode-ai/plugin keep working.
              opencode = pkgs.stdenv.mkDerivation rec {
                pname = "opencode";
                version = "1.19.5";
                src = pkgs.fetchurl {
                  url = "https://github.com/anomalyco/opencode/releases/download/v${version}/opencode-linux-x64.tar.gz";
                  hash = "sha256-WIMQozb6O53zaz8CJbJvZ51FPvqtDPPWbDZR7z7BZHo=";
                };
                sourceRoot = ".";
                dontStrip = true; # bun single-file binary: stripping drops the embedded app
                nativeBuildInputs = [ pkgs.autoPatchelfHook ];
                installPhase = "install -Dm755 opencode $out/bin/opencode";
              };
            in
            {
              systemd.tmpfiles.rules = [
                "d ${home}/.config 0755 ${user} users -"
                "d ${home}/.local 0755 ${user} users -"
                "d ${home}/.local/share 0755 ${user} users -"
                "L+ ${home}/.claude - - - - ${stage}/claude"
                "L+ ${home}/.config/opencode - - - - ${stage}/opencode/config"
                "L+ ${home}/.local/share/opencode - - - - ${stage}/opencode/data"
                "d ${home}/.local/state 0755 ${user} users -"
                "L+ ${home}/.local/state/opencode - - - - ${stage}/opencode/state"
              ];
              environment.variables.OPENCODE_DISABLE_AUTOUPDATE = "1";
              environment.systemPackages = [
                claude-code
                opencode
                pkgs.gh
                pkgs.jq
                pkgs.ripgrep
                pkgs.just
              ];
              environment.variables.CLAUDE_CONFIG_DIR = "${home}/.claude";
              programs.git = {
                enable = true;
                config = {
                  # Identity comes from the host's git config, written by the launcher.
                  include.path = "${stage}/gitconfig";
                  safe.directory = "*";
                  credential."https://github.com".helper = "!gh auth git-credential";
                  url."https://github.com/".insteadOf = [
                    "git@github.com:"
                    "ssh://git@github.com/"
                  ];
                };
              };
              environment.loginShellInit = ''
                # Only for a human at the console: `vm run` types its command right after login, and
                # resize would swallow it while waiting for the terminal's reply.
                if [ "$(tty)" = /dev/ttyS0 ] && [ -f ${stage}/tty ]; then
                  ${pkgs.busybox}/bin/resize >/dev/null 2>&1 || true
                  if [ -f ${stage}/cmd ] && [ -z "''${AGENT_VM_STARTED:-}" ]; then
                    export AGENT_VM_STARTED=1
                    agent_vm_cmd=$(cat ${stage}/cmd)
                    rm -f ${stage}/cmd
                    # Ctrl-C on a hung agent would otherwise abort this profile before poweroff.
                    trap : INT
                    bash -c "$agent_vm_cmd"
                    sudo poweroff
                  fi
                fi
              '';
            };

          # The workspace arrives at a fixed guest path; bind it to the host's absolute path (written
          # by the launcher into the stage) so paths, git worktrees and Claude memory keys match.
          # Ordered before the console login, which cds into it.
          workspaceBind =
            { pkgs, ... }:
            {
              systemd.services.agent-vm-workspace = {
                wantedBy = [ "multi-user.target" ];
                before = [
                  "multi-user.target"
                  "getty.target"
                  "serial-getty@ttyS0.service"
                ];
                unitConfig.RequiresMountsFor = [
                  stage
                  workspaceMount
                ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                };
                path = [ pkgs.util-linux ];
                script = ''
                  ws=$(cat ${stage}/ws 2>/dev/null) || exit 0
                  case "$ws" in
                    ${home}/*) runuser -u ${user} -- mkdir -p "$ws" ;;
                    /*) mkdir -p "$ws" ;;
                    *) echo "bad workspace path: $ws" >&2; exit 1 ;;
                  esac
                  mount --bind ${workspaceMount} "$ws"
                '';
              };
            };

          # Guest nix only trusts its own closure; bake the dev shells in so `nix develop` serves
          # them from the host store instead of refetching.
          devShellClosure = {
            system.extraDependencies = map (s: s.inputDerivation) devShells;
          };

          keyringSecret = name: {
            command = "secret-tool lookup service agent-vm key ${name}";
            target.envName = name;
          };

          host = nix-vm.lib.mkStandaloneHost {
            inherit inputs;
            modules = [
              {
                custom.username = user;
                # path: so nix sees the config flake even inside a git checkout that ignores it.
                custom.flakeDir = "path:${configDir}";
                custom.microvms.agent = {
                  hypervisor = "qemu";
                  inherit vcpu mem;
                  forwardSshAgent = false;
                  launchMountPoint = workspaceMount; # source = the launcher's --mount
                  trust.default = [
                    "shares"
                    "secrets"
                  ];
                  allowUnfree = true; # claude-code
                  secrets = map keyringSecret (
                    [
                      "CLAUDE_CODE_OAUTH_TOKEN"
                      "GH_TOKEN"
                    ]
                    ++ extraSecrets
                  );
                  # The launcher exports AGENT_VM_STAGE; without it the share is empty.
                  hostPreLaunch = ''
                    if [ -n "''${AGENT_VM_STAGE:-}" ]; then ln -sfn "$AGENT_VM_STAGE" agent; fi
                  '';
                  storeOverlayBacking = "disk";
                  storeSize = 32768;
                  extraShares = [
                    {
                      source = "agent";
                      mountPoint = stage;
                      tag = "agent";
                    }
                    {
                      source = cargoTarget;
                      mountPoint = hostCargoTarget;
                      tag = "host-cargo-target";
                      readOnly = true;
                    }
                  ];
                  extraModules = [
                    cargoTargetOverlay
                    agentModule
                    workspaceBind
                    devShellClosure
                  ]
                  ++ extraModules;
                };
              }
            ];
          };
        in
        (nix-vm.lib.mkMicrovmFleet {
          inherit inputs;
          hosts.host = {
            system = "x86_64-linux";
            class = "nixos";
          };
          builtHosts.host = host;
          includeBuilder = false;
        }).packages;
    };
}
