{
	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
		flake-utils.url = "github:numtide/flake-utils";
		crane.url = "github:ipetkov/crane";
	};

	outputs = {
		self,
		nixpkgs,
		flake-utils,
		crane,
	}: flake-utils.lib.eachDefaultSystem (system: let

		pkgs = import nixpkgs { inherit system; };
		craneLib = import crane { inherit pkgs; };

		floatty = import ./default.nix { inherit pkgs craneLib; };

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
