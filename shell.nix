# Unlocked version. For locked inputs, use the flake.
{
	pkgs ? import <nixpkgs> { },
	floatty ? pkgs.callPackage ./package.nix { },
}:

pkgs.callPackage floatty.mkDevShell { }
