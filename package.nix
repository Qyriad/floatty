{
	lib,
	stdenv,
	zig,
}: let
	inherit (stdenv) hostPlatform;
	isLinuxClang = hostPlatform.isLinux && stdenv.cc.isClang;
in stdenv.mkDerivation (self: {
	pname = "floatty";
	version = "0.0.1";

	strictDeps = true;
	__structuredAttrs = true;

	src = lib.fileset.toSource {
		root = ./.;
		fileset = lib.fileset.unions [
				./build.zig.zon
				./src
				./build.zig
		];
	};

	nativeBuildInputs = [
		zig
	];

	dontStrip = true;

	zigFlags = [
		"-O" "ReleaseSafe"
		"--verbose-link"
		#"--verbose-cc"
		"-fno-strip"
		"-fPIE"
		"-fno-omit-frame-pointer"
		"-fsanitize-c"
		"-ferror-tracing"
		"-fentry"
		"-z" "defs"
		"-fstack-report"
		"-lc"
		#"--verbose-cimport"
	];

	preConfigure = ''
		export ZIG_GLOBAL_CACHE_DIR="$PWD/.cache"
		mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
	'';

	buildPhase = ''
		runHook preBuild
		zig build-exe "''${zigFlags[@]}" src/main.zig "-femit-bin=./floatty"
		runHook postBuild
	'';

	installPhase = ''
		runHook preInstall
		mkdir -p "$out/bin"
		mv -v floatty "$out/bin"
		runHook postInstall
	'';

	passthru.mkDevShell = {
		mkShell,
		clang-tools,
		zls,
	}: mkShell {
		inputsFrom = [ self.finalPackage ];
		packages = [ clang-tools zls ];
	};

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

