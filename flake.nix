{
	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
		flake-utils.url = "github:numtide/flake-utils";
		crane.url = "github:ipetkov/crane";
		fenix = {
			url = "github:nix-community/fenix";
			inputs.nixpkgs.follows = "nixpkgs";
		};
	};

	outputs = {
		self,
		nixpkgs,
		flake-utils,
		crane,
		fenix,
	}: flake-utils.lib.eachDefaultSystem (system: let

		pkgs = import nixpkgs { inherit system; };
		fenixLib = import fenix { inherit system pkgs; };
		craneLib = import crane { inherit pkgs; };
		craneToolchain = craneLib.overrideToolchain fenixLib.complete.toolchain;

		floatty = import ./default.nix {
			inherit pkgs fenixLib craneLib craneToolchain;
		};

	in {
		packages = {
			default = floatty;
			inherit floatty;
		};

		devShells.default = pkgs.callPackage floatty.mkDevShell { self = floatty; };

		checks = {
			package = self.packages.${system}.floatty;
			devShell = self.devShells.${system}.default;
		};
	}); # outputs
}
