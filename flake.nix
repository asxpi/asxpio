{
  description = "asxp.io — IE Sergei Poljanski website";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [
          pkgs.ruby_3_4
          pkgs.bundler
          pkgs.openssl
          pkgs.zlib
          pkgs.libyaml
        ];

        shellHook = ''
          export GEM_HOME="$PWD/.gems"
          export PATH="$GEM_HOME/bin:$PATH"
          export BUNDLE_PATH="$GEM_HOME"

          if [ -f .env ]; then
            set -a
            source .env
            set +a
          fi

          if [ ! -f .gems/.bundled ] || [ Gemfile -nt .gems/.bundled ]; then
            echo "Installing gems..."
            bundle install --quiet && mkdir -p .gems && touch .gems/.bundled
          fi

          echo "asxpio dev shell ready"
          echo "  bundle exec rerun -- rackup -p 3000   - start with auto-reload"
        '';
      };
    };
}
