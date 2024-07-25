{
	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
		flake-utils.url = "github:numtide/flake-utils";
	};

	outputs = {
		self,
		nixpkgs,
		flake-utils,
	}: flake-utils.lib.eachDefaultSystem (system: let

		pkgs = import nixpkgs { inherit system; };

		floatty = import ./default.nix { inherit pkgs; };

	in {
		packages = {
			default = floatty;
			inherit floatty;
		};

		devShells.default = pkgs.callPackage floatty.mkDevShell { };

		checks = {
			package = self.packages.${system}.git-point;
			devShell = self.devShells.${system}.default;
		};
	}); # outputs
}
