{
  lib,
  rustPlatform,
  pkg-config,
  makeWrapper,
  openssl,
  nix,
  systemd,
  ...
}:

rustPlatform.buildRustPackage rec {
  pname = "nixos-autodeploy";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    filter =
      name: type:
      !(
        type == "directory"
        && builtins.elem (baseNameOf name) [
          "target"
          ".idea"
          ".direnv"
        ]
      )
      && !(builtins.elem (baseNameOf name) [
        "flake.nix"
        "flake.lock"
        "module.nix"
        "package.nix"
        "test.nix"
      ]);
    src = lib.cleanSource ./.;
  };

  nativeBuildInputs = [
    pkg-config
    makeWrapper
  ];

  buildInputs = [
    openssl.dev
  ];

  cargoLock = {
    lockFile = ./Cargo.lock;
  };

  postInstall = ''
    wrapProgram $out/bin/nixos-autodeploy \
        --prefix PATH : ${
          lib.makeBinPath [
            nix
            systemd
          ]
        }
  '';

  meta = with lib; {
    description = "A robust NixOS system auto-deployment";
    homepage = "https://github.com/hlsb-fulda/nixos-autodeploy-rs";
    license = licenses.mit;
    maintainers = with maintainers; [ fooker ];
    platforms = platforms.linux;
    mainProgram = "nixos-autodeploy";
  };
}
