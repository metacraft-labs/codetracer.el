{
  description = "codetracer.el — Emacs front-end for CodeTracer, over the CodeTracer pane server";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/devops-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
  };

  outputs =
    inputs@{ flake-parts, nixos-modules, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        nixos-modules.modules.flake.git-hooks
      ];

      # The Apache-2.0 text's fixed indentation is not ours to reformat.
      mcl.gitHooks.editorconfigExcludes = [ "^LICENSE$" ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        { pkgs, config, ... }:
        let
          # Emacs 29 is the oldest release the package supports (its
          # `Package-Requires'); the dev shell uses the current one.
          emacs = pkgs.emacs-nox;
        in
        {
          # The mcl-standard-hooks set is installed by the imported git-hooks
          # module. The entries below are this repository's own: `just lint`
          # and the license check.
          pre-commit.settings.hooks = {
            lint = {
              enable = true;
              name = "just lint";
              entry = "just lint";
              language = "system";
              pass_filenames = false;
            };
            check-license = {
              enable = true;
              name = "Check License File";
              entry = "bash -c 'test -f LICENSE || { echo \"Error: no LICENSE file in the repository root\"; exit 1; }'";
              files = "^$";
              pass_filenames = false;
              always_run = true;
            };
          };

          devShells.default = pkgs.mkShell {
            inputsFrom = [ config.pre-commit.devShell ];
            packages = [
              emacs
              pkgs.just
              pkgs.git
              pkgs.nixfmt
            ];
            shellHook = ''
              echo "codetracer.el dev shell — $(emacs --version | head -1)"
            ''
            + config.mcl.gitHooks.installationScript;
          };

          # The package, byte-compiled, as `emacsPackages` packages are
          # (`programs.emacs.extraPackages`).
          packages.default = emacs.pkgs.trivialBuild {
            pname = "codetracer";
            version = "0.1.0";
            src = ./.;
            packageRequires = [ ];
          };

          # The unit tests, which need nothing but Emacs.
          checks.unit = pkgs.runCommand "codetracer-el-unit" { nativeBuildInputs = [ emacs ]; } ''
            cd ${./.}
            emacs --batch -Q -L . -L test -l test/codetracer-test.el \
              --eval '(ert-run-tests-batch-and-exit (quote (tag unit)))'
            touch $out
          '';
        };
    };
}
