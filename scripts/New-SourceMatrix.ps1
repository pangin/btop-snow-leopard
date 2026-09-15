param(
	[string[]] $Tags,

	[Parameter(Mandatory = $true)]
	[string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$transformer = Join-Path $PSScriptRoot 'Prepare-SnowLeopardBackport.ps1'
$outputRoot = [IO.Path]::GetFullPath($OutputPath)
$stagingRoot = Join-Path $outputRoot '.staging'

New-Item -ItemType Directory -Force -Path $outputRoot, $stagingRoot | Out-Null

if (-not $Tags -or $Tags.Count -eq 0) {
	$Tags = @(
		git -C $repoRoot tag --list 'v*' --sort=version:refname |
			Where-Object { $_ -notlike '*snow-leopard*' } |
			Where-Object {
				$number = [version]($_.Substring(1))
				$number -ge [version]'1.0.0' -and $number -le [version]'1.4.6'
			}
	)
}

function Assert-NativeSuccess([string] $Description) {
	if ($LASTEXITCODE -ne 0) { throw "$Description failed with exit code $LASTEXITCODE." }
}

function Assert-PreparedTree([string] $Path, [string] $Tag) {
	$btop = [IO.File]::ReadAllText((Join-Path $Path 'src/btop.cpp'))
	$expectedVersion = $Tag.Substring(1)
	if (-not $btop.Contains("Version = `"$expectedVersion`"")) {
		throw "$Tag no longer reports its upstream release version."
	}
	if ($btop.Contains('}#endif')) {
		throw "$Tag has a malformed preprocessor guard."
	}
	if ($btop.Contains('std::setlocale') -and -not $btop.Contains('#include <clocale>')) {
		throw "$Tag has no C++ locale declaration include."
	}
	if ($btop.Contains('sem_init(&do_work') -and $btop.Contains('#if __GNUC__ < 11')) {
		throw "$Tag still selects Darwin's unsupported unnamed POSIX semaphore under Clang."
	}
	if ($btop.Contains('std::binary_semaphore') -and -not $btop.Contains('#include <semaphore>')) {
		throw "$Tag uses std::binary_semaphore without a top-level semaphore include."
	}

	$osxPath = Join-Path $Path 'src/osx/btop_collect.cpp'
	$osx = [IO.File]::ReadAllText($osxPath)
	if ($osx.Contains('p.external_page_count')) { throw "$Tag still uses external_page_count." }
	if (-not $osx.Contains('#if defined(RUSAGE_INFO_CURRENT)')) { throw "$Tag has no process-I/O guard." }
	if (-not $osx.Contains('static_cast<std::uint64_t>(vfs.f_blocks)')) { throw "$Tag has no disk-total widening." }
	if (-not $osx.Contains('static_cast<std::uint64_t>(vfs.f_bfree)')) { throw "$Tag has no disk-free widening." }
	$sensors = [IO.File]::ReadAllText((Join-Path $Path 'src/osx/sensors.cpp'))
	if ($sensors.Contains('#include <IOKit/hidsystem/IOHIDEventSystemClient.h>') -and
		-not $sensors.Contains('__MAC_OS_X_VERSION_MIN_REQUIRED')) {
		throw "$Tag exposes the newer-macOS IOHID sensor API to the Snow Leopard SDK."
	}
	$smc = [IO.File]::ReadAllText((Join-Path $Path 'src/osx/smc.cpp'))
	if (-not $smc.Contains('IOServiceGetMatchingServices(0, matchingDictionary, &iterator)') -or
		-not $smc.Contains('getSMCTemp')) {
		throw "$Tag does not contain the verified Snow Leopard Intel SMC implementation."
	}
	$input = [IO.File]::ReadAllText((Join-Path $Path 'src/btop_input.cpp'))
	if ($input.Contains('cin.rdbuf()->in_avail()')) {
		throw "$Tag still uses unreliable stream-buffer terminal polling."
	}

	$makefile = [IO.File]::ReadAllText((Join-Path $Path 'Makefile'))
	if ($makefile.Contains('-std=c++23')) { throw "$Tag still requires the unsupported C++23 flag spelling." }
	if ($makefile.Contains(' -lIOReport')) { throw "$Tag still links the unavailable IOReport library." }

	foreach ($relative in @('src/btop_tools.hpp', 'src/main.cpp')) {
		$file = Join-Path $Path $relative
		if (Test-Path -LiteralPath $file -PathType Leaf) {
			if ([IO.File]::ReadAllText($file).Contains('std::ranges::to')) {
				throw "$Tag still uses ranges::to in $relative."
			}
		}
	}

	if (-not (Test-Path -LiteralPath (Join-Path $Path 'build-snow-leopard.sh') -PathType Leaf)) {
		throw "$Tag has no Snow Leopard build script."
	}
}

$results = [Collections.Generic.List[object]]::new()

foreach ($tag in $Tags) {
	if ($tag -notmatch '^v\d+\.\d+\.\d+$') { throw "Invalid release tag: $tag" }
	$stage = Join-Path $stagingRoot ("{0}-{1}" -f $tag, [guid]::NewGuid().ToString('N'))
	$source = Join-Path $stage 'source'
	$upstreamTar = Join-Path $stage 'upstream.tar'
	$archiveName = "btop-$($tag.Substring(1))-snow-leopard-source.tar.gz"
	$archivePath = Join-Path $outputRoot $archiveName
	$completed = $false

	New-Item -ItemType Directory -Path $source | Out-Null
	try {
		& git -C $repoRoot archive --format=tar --output=$upstreamTar $tag
		Assert-NativeSuccess "git archive for $tag"
		& tar -xf $upstreamTar -C $source
		Assert-NativeSuccess "tar extraction for $tag"
		Remove-Item -LiteralPath $upstreamTar

		$null = & $transformer -SourcePath $source -Version $tag
		Assert-PreparedTree $source $tag

		& tar -czf $archivePath -C $source .
		Assert-NativeSuccess "source packaging for $tag"
		$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
		$results.Add([pscustomobject]@{
			version = $tag
			archive = $archiveName
			sha256 = $hash
			status = 'prepared'
		})
		$completed = $true
	}
	finally {
		if ($completed -and (Test-Path -LiteralPath $stage)) {
			$resolvedStage = (Resolve-Path -LiteralPath $stage).Path
			$resolvedStagingRoot = (Resolve-Path -LiteralPath $stagingRoot).Path
			if (-not $resolvedStage.StartsWith($resolvedStagingRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
				throw "Refusing to remove staging path outside its root: $resolvedStage"
			}
			Remove-Item -LiteralPath $resolvedStage -Recurse -Force
		}
	}
}

$manifestPath = Join-Path $outputRoot 'source-manifest.json'
$manifest = $results | ConvertTo-Json -Depth 3
[IO.File]::WriteAllText($manifestPath, $manifest + "`n", $utf8NoBom)

$tabManifestPath = Join-Path $outputRoot 'source-manifest.tsv'
$tabManifest = @($results | ForEach-Object {
	"$($_.version)`t$($_.archive)`t$($_.sha256)"
}) -join "`n"
[IO.File]::WriteAllText($tabManifestPath, $tabManifest + "`n", $utf8NoBom)
$results
