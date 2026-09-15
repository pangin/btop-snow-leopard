param(
	[Parameter(Mandatory = $true)]
	[string] $VerifiedManifest,

	[Parameter(Mandatory = $true)]
	[string] $AssetsPath,

	[string] $RepoPath = (Join-Path $PSScriptRoot '..'),

	[string] $GitHubRepo = 'pangin/btop-snow-leopard',

	[switch] $Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath $RepoPath).Path
$manifestPath = (Resolve-Path -LiteralPath $VerifiedManifest).Path
$assetsRoot = (Resolve-Path -LiteralPath $AssetsPath).Path
$utf8NoBom = [Text.UTF8Encoding]::new($false)

function Invoke-Native([string] $Description, [scriptblock] $Command) {
	& $Command
	if ($LASTEXITCODE -ne 0) { throw "$Description failed with exit code $LASTEXITCODE." }
}

function Assert-BinaryArchive([string] $Archive, [string] $ExpectedBinarySha256, [string] $ReleaseTag) {
	$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("btop-release-verify-" + [guid]::NewGuid().ToString('N'))
	try {
		New-Item -ItemType Directory -Path $tempRoot | Out-Null
		& tar -xzf $Archive -C $tempRoot
		if ($LASTEXITCODE -ne 0) { throw "Binary asset extraction failed for $ReleaseTag." }
		$binaries = @(
			Get-ChildItem -LiteralPath $tempRoot -Recurse -File |
				Where-Object { $_.FullName -match '[\\/]bin[\\/]btop$' }
		)
		if ($binaries.Count -ne 1) {
			throw "Binary asset for $ReleaseTag must contain exactly one bin/btop (found $($binaries.Count))."
		}
		$actualBinaryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $binaries[0].FullName).Hash.ToLowerInvariant()
		if ($actualBinaryHash -ne $ExpectedBinarySha256) {
			throw "Unpacked binary SHA256 mismatch for $ReleaseTag."
		}
	}
	finally {
		if (Test-Path -LiteralPath $tempRoot) {
			Remove-Item -LiteralPath $tempRoot -Recurse -Force
		}
	}
}

$rows = @(
	Get-Content -LiteralPath $manifestPath |
		Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
		ForEach-Object {
			$fields = $_ -split "`t"
			if ($fields.Count -lt 6) { throw "Malformed verified-manifest row: $_" }
			[pscustomobject]@{
				UpstreamTag = $fields[0]
				SourceName = $fields[1]
				SourceSha256 = $fields[2]
				BinaryName = $fields[3]
				BinarySha256 = $fields[4]
				BinaryAssetSha256 = $fields[5]
			}
		}
)

foreach ($row in $rows) {
	if ($row.UpstreamTag -notmatch '^v\d+\.\d+\.\d+$') {
		throw "Invalid upstream tag in manifest: $($row.UpstreamTag)"
	}
	$releaseTag = "$($row.UpstreamTag)-snow-leopard.1"
	$version = $row.UpstreamTag.Substring(1)
	$sourceArchive = Join-Path $assetsRoot $row.SourceName
	$binaryArchive = Join-Path $assetsRoot $row.BinaryName
	foreach ($asset in @($sourceArchive, $binaryArchive)) {
		if (-not (Test-Path -LiteralPath $asset -PathType Leaf)) { throw "Release asset is missing: $asset" }
	}
	$actualSourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceArchive).Hash.ToLowerInvariant()
	$actualBinaryAssetHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $binaryArchive).Hash.ToLowerInvariant()
	if ($actualSourceHash -ne $row.SourceSha256) { throw "Source SHA256 mismatch for $releaseTag." }
	if ($actualBinaryAssetHash -ne $row.BinaryAssetSha256) { throw "Binary asset SHA256 mismatch for $releaseTag." }
	Assert-BinaryArchive -Archive $binaryArchive -ExpectedBinarySha256 $row.BinarySha256 -ReleaseTag $releaseTag

	& git -C $repoRoot rev-parse --verify --quiet "refs/tags/$releaseTag" *> $null
	if ($LASTEXITCODE -ne 0) { throw "Local release tag is missing: $releaseTag" }
	if (-not $Apply) {
		[pscustomobject]@{ release = $releaseTag; source = $row.SourceName; binary = $row.BinaryName; status = 'planned' }
		continue
	}

	Invoke-Native "tag push for $releaseTag" { git -C $repoRoot push origin "refs/tags/$releaseTag" }
	& gh release view $releaseTag --repo $GitHubRepo *> $null
	if ($LASTEXITCODE -eq 0) {
		Invoke-Native "asset upload for $releaseTag" {
			gh release upload $releaseTag $sourceArchive $binaryArchive --repo $GitHubRepo --clobber
		}
		[pscustomobject]@{ release = $releaseTag; status = 'updated-assets' }
		continue
	}

	$notesPath = Join-Path ([IO.Path]::GetTempPath()) "$releaseTag-notes.md"
	$notes = @"
Snow Leopard backport of [btop $version](https://github.com/aristocratos/btop/releases/tag/$($row.UpstreamTag)) for 32-bit Intel Macs running Mac OS X 10.6.8.

Built and runtime-tested on Darwin 10.8.0 (`i386`) with MacPorts Clang 16. CPU, memory, disk, network, and process collection were exercised in a real terminal, followed by a clean `q` exit.

Runtime prerequisite:

```sh
sudo /opt/local/bin/port install legacy-support
```

Install from the binary archive:

```sh
tar -xzf $($row.BinaryName)
sudo cp bin/btop /opt/local/bin/btop
sudo mkdir -p /opt/local/share/btop
sudo cp -R themes /opt/local/share/btop/
btop --version
```

Assets:

- `$($row.SourceName)` — prepared backport source, SHA-256 `$($row.SourceSha256)`
- `$($row.BinaryName)` — verified Mach-O i386 package, SHA-256 `$($row.BinaryAssetSha256)`
- unpacked `bin/btop` SHA-256: `$($row.BinarySha256)`

GPU metrics and detailed per-process disk I/O are unavailable on Snow Leopard because the required macOS APIs did not exist in 10.6.
"@
	[IO.File]::WriteAllText($notesPath, $notes, $utf8NoBom)
	try {
		Invoke-Native "GitHub release creation for $releaseTag" {
			gh release create $releaseTag $sourceArchive $binaryArchive --repo $GitHubRepo --verify-tag --latest=false --title "btop $version for Mac OS X Snow Leopard (i386)" --notes-file $notesPath
		}
		[pscustomobject]@{ release = $releaseTag; status = 'published' }
	}
	finally {
		Remove-Item -LiteralPath $notesPath -ErrorAction SilentlyContinue
	}
}
