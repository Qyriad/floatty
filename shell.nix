# Unlocked version. For locked inputs, use the flake.
{
	pkgs ? import <nixpkgs> { },
	crane ? fetchGit {
			url = "https://github.com/ipetkov/crane";
	},
	craneLib ? import crane { inherit pkgs; },
	floatty ? pkgs.callPackage ./package.nix { inherit craneLib; },
}:

pkgs.callPackage floatty.mkDevShell { self = floatty; }
