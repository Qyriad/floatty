# Unlocked version. For locked inputs, use the flake.
{
	pkgs ? import <nixpkgs> { },

	fenixLib ? let
		fenix = fetchGit {
			url = "https://github.com/nix-community/fenix";
		};
	in import fenix { inherit pkgs; inherit (pkgs) system; },

	craneLib ? let
		crane = fetchGit {
			url = "https://github.com/ipetkov/crane";
		};
	in import crane { inherit pkgs; },

	craneToolchain ? craneLib.overrideToolchain fenixLib.complete.toolchain,

	floatty ? pkgs.callPackage ./package.nix { craneLib = craneToolchain; },
}:

pkgs.callPackage floatty.mkDevShell { self = floatty; }
