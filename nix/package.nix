# The app with its gems (bundlerEnv, from Gemfile.lock and gemset.nix;
# after changing Gemfile.lock run `nix run nixpkgs#bundix` to refresh
# gemset.nix). bin/asxpio is Puma serving config.ru (pass -b and -t like
# to puma); bin/asxpio-monitor is the reachability worker (bin/monitor).
{
  lib,
  stdenvNoCC,
  bundlerEnv,
  makeWrapper,
  ruby_4_0,
  imagemagick,
  version,
}:
let
  root = ../.;
  gems = bundlerEnv {
    name = "asxpio-gems";
    ruby = ruby_4_0;
    gemfile = root + "/Gemfile";
    lockfile = root + "/Gemfile.lock";
    gemset = root + "/gemset.nix";
    groups = [ "default" ];
  };
  share = "$out/share/asxpio";
in
stdenvNoCC.mkDerivation {
  pname = "asxpio";
  inherit version;
  src = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [
      ../asxpio.rb
      ../config.ru
      ../lib
      ../views
      ../public
      ../db
      ../bin/monitor
    ];
  };
  nativeBuildInputs = [ makeWrapper ];
  # The lock lists precompiled pg/ffi/prism for many platforms; Nix builds
  # the source gems, so Bundler must not look for the others. Photos are
  # resized with ImageMagick 7's magick (the image had 6's convert).
  installPhase = ''
    mkdir -p $out/share $out/bin
    cp -r . ${share}
    common=(--chdir ${share} --set-default RACK_ENV production --set BUNDLE_FORCE_RUBY_PLATFORM true
      --set-default BINGO_CONVERT ${imagemagick}/bin/magick)
    makeWrapper ${gems}/bin/puma $out/bin/asxpio "''${common[@]}" \
      --add-flags "--preload ${share}/config.ru"
    makeWrapper ${gems.wrappedRuby}/bin/ruby $out/bin/asxpio-monitor "''${common[@]}" \
      --add-flags ${share}/bin/monitor
  '';
  passthru = { inherit gems; };
  meta.mainProgram = "asxpio";
}
