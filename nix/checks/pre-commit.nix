{
  perSystem =
    { config, pkgs, ... }:
    {
      # impl: https://github.com/cachix/git-hooks.nix/blob/master/flake-module.nix
      pre-commit = {
        # Disable `checks` flake output
        check.enable = false;

        # Enable commonly used formatters
        settings = {
          # Use Rust-based alternative to pre-commit:
          # https://github.com/j178/prek
          package = pkgs.prek;

          excludes = [ "^.*\\.age$" ];

          hooks = {
            # Basic whitespace formatting
            end-of-file-fixer.enable = true;
            editorconfig-checker.enable = true;

            # *.nix formatting
            nixfmt.enable = true;

            # *.d / *.di formatting
            dfmt = {
              enable = true;
              name = "dfmt";
              description = "Format D source files with dfmt";
              entry = "${pkgs.dformat}/bin/dfmt --inplace";
              files = "\\.di?$";
              language = "system";
              pass_filenames = true;
            };
          };
        };
      };
    };
}
