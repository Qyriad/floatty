{
	lib,
	craneLib,
	stdenv,
	libiconv,
}: let
	inherit (stdenv) hostPlatform;

	craneLib' = craneLib.overrideScope (finalCrane: prevCrane: {
		mkCargoDerivation = prevCrane.mkCargoDerivation.override { inherit stdenv; };
	});

	commonArgs = {
		src = lib.fileset.toSource {
			root = ./.;
			fileset = lib.fileset.unions [
				./src
				./Cargo.toml
				./Cargo.lock
			];
		};

		strictDeps = true;
		__structuredAttrs = true;

		buildInputs = lib.optionals hostPlatform.isDarwin [
			libiconv
		];
	};

	cargoArtifacts = craneLib'.buildDepsOnly commonArgs;

in craneLib'.buildPackage (commonArgs // {

	inherit cargoArtifacts;

	passthru.mkDevShell = {
		self,
		rust-analyzer,
	}: craneLib.devShell {
		inputsFrom = [ self ];
		packages = [ rust-analyzer ];
	};

	passthru.clippy = craneLib'.cargoClippy (commonArgs // {
		inherit cargoArtifacts;
	});

	meta = {
		homepage = "https://github.com/Qyriad/floatty";
		#description = "";
		maintainers = with lib.maintainers; [ qyriad ];
		license = with lib.licenses; [ mit ];
		sourceProvenance = with lib.sourceTypes; [ fromSource ];
		platforms = with lib.platforms; all;
		mainProgram = "floatty";
	};
})

