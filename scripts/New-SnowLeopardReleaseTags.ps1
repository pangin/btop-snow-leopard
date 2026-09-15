param(
	[Parameter(Mandatory = $true)]
	[string] $VerifiedManifest,

	[Parameter(Mandatory = $true)]
	[string] $AssetsPath,

	[string] $RepoPath = (Join-Path $PSScriptRoot '..'),

	[switch] $Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath $RepoPath).Path
$manifestPath = (Resolve-Path -LiteralPath $VerifiedManifest).Path
$assetsRoot = (Resolve-Path -LiteralPath $AssetsPath).Path
$worktreeRoot = Join-Path (Split-Path -Parent $repoRoot) '.btop-snow-leopard-release-worktrees'

function Invoke-Git([string[]] $Arguments, [string] $Description) {
	& git @Arguments
	if ($LASTEXITCODE -ne 0) { throw "$Description failed with exit code $LASTEXITCODE." }
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
			}
		}
)

foreach ($row in $rows) {
	if ($row.UpstreamTag -notmatch '^v\d+\.\d+\.\d+$') {
		throw "Invalid upstream tag in manifest: $($row.UpstreamTag)"
	}
	$sourceArchive = Join-Path $assetsRoot $row.SourceName
	if (-not (Test-Path -LiteralPath $sourceArchive -PathType Leaf)) {
		throw "Prepared source archive is missing: $sourceArchive"
	}
	$actualSourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceArchive).Hash.ToLowerInvariant()
	if ($actualSourceHash -ne $row.SourceSha256) {
		throw "Source SHA256 mismatch for $($row.UpstreamTag)."
	}

	$releaseTag = "$($row.UpstreamTag)-snow-leopard.1"
	& git -C $repoRoot rev-parse --verify --quiet "refs/tags/$releaseTag" *> $null
	if ($LASTEXITCODE -eq 0) {
		[pscustomobject]@{ upstream = $row.UpstreamTag; release = $releaseTag; status = 'existing' }
		continue
	}
	if (-not $Apply) {
		[pscustomobject]@{ upstream = $row.UpstreamTag; release = $releaseTag; status = 'planned' }
		continue
	}

	New-Item -ItemType Directory -Force -Path $worktreeRoot | Out-Null
	$worktree = Join-Path $worktreeRoot $releaseTag
	if (Test-Path -LiteralPath $worktree) {
		throw "Release worktree path already exists: $worktree"
	}

	$registered = $false
	try {
		Invoke-Git -Arguments @('-C', $repoRoot, 'worktree', 'add', '--detach', $worktree, $row.UpstreamTag) -Description "worktree creation for $releaseTag"
		$registered = $true
		# Make the commit tree match the verified archive exactly.  Overlaying the
		# archive alone can leave files that the backport intentionally removed.
		Invoke-Git -Arguments @('-C', $worktree, 'rm', '-r', '-q', '--ignore-unmatch', '--', '.') -Description "tracked-file cleanup for $releaseTag"
		& tar -xzf $sourceArchive -C $worktree
		if ($LASTEXITCODE -ne 0) { throw "Source extraction failed for $releaseTag." }
		Invoke-Git -Arguments @('-C', $worktree, 'add', '-A') -Description "staging for $releaseTag"
		Invoke-Git -Arguments @('-C', $worktree, 'update-index', '--chmod=+x', 'build-snow-leopard.sh') -Description "executable-bit setup for $releaseTag"
		$version = $row.UpstreamTag.Substring(1)
		Invoke-Git -Arguments @('-C', $worktree, 'commit', '-m', "Backport btop $version to Mac OS X Snow Leopard") -Description "commit for $releaseTag"
		$commit = (& git -C $worktree rev-parse HEAD).Trim()
		if ($LASTEXITCODE -ne 0) { throw "Could not resolve commit for $releaseTag." }
		Invoke-Git -Arguments @('-C', $repoRoot, 'tag', '-a', $releaseTag, $commit, '-m', "btop $version for Mac OS X Snow Leopard") -Description "tag creation for $releaseTag"
		[pscustomobject]@{ upstream = $row.UpstreamTag; release = $releaseTag; commit = $commit; status = 'created' }
	}
	finally {
		if ($registered) {
			& git -C $repoRoot worktree remove --force $worktree
			if ($LASTEXITCODE -ne 0) {
				Write-Warning "Could not remove release worktree: $worktree"
			}
		}
	}
}
