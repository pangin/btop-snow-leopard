param(
	[string] $RepoPath = (Join-Path $PSScriptRoot '..'),

	[string] $GitHubRepo = 'pangin/btop-snow-leopard',

	[string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath $RepoPath).Path

function Invoke-GhJson([string[]] $Arguments, [string] $Description) {
	$json = & gh @Arguments
	if ($LASTEXITCODE -ne 0) { throw "$Description failed with exit code $LASTEXITCODE." }
	return ($json -join "`n") | ConvertFrom-Json
}

function Get-GitHubReleases([string] $Repository) {
	$pages = @(Invoke-GhJson -Arguments @('api', "repos/$Repository/releases?per_page=100", '--paginate', '--slurp') -Description 'GitHub release query')
	$releases = [Collections.Generic.List[object]]::new()
	foreach ($page in $pages) {
		foreach ($release in @($page)) { $releases.Add($release) }
	}
	return @($releases)
}

$upstreamTags = @(
	& git -C $repoRoot tag --list 'v[0-9]*' --sort=version:refname |
		Where-Object {
			$_ -match '^v\d+\.\d+\.\d+$' -and
			([version]$_.Substring(1)) -ge [version]'1.0.0' -and
			([version]$_.Substring(1)) -le [version]'1.4.7'
		}
)
if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate upstream release tags.' }
if ($upstreamTags.Count -ne 55) { throw "Expected 55 upstream release tags, found $($upstreamTags.Count)." }

$releases = Get-GitHubReleases $GitHubRepo
$rows = [Collections.Generic.List[object]]::new()

foreach ($upstreamTag in $upstreamTags) {
	$version = $upstreamTag.Substring(1)
	$escaped = [regex]::Escape($upstreamTag)
	$candidates = @(
		$releases |
			Where-Object { $_.tag_name -match "^$escaped-snow-leopard\.\d+$" } |
			Sort-Object published_at -Descending
	)
	$release = if ($candidates.Count -gt 0) { $candidates[0] } else { $null }
	$expectedAssets = @(
		"btop-$version-snow-leopard-source.tar.gz",
		"btop-$version-snow-leopard-i386.tar.gz"
	)
	$actualAssets = if ($null -ne $release) { @($release.assets | ForEach-Object name) } else { @() }
	$missingAssets = @($expectedAssets | Where-Object { $_ -notin $actualAssets })
	$unexpectedAssets = @($actualAssets | Where-Object { $_ -notin $expectedAssets })
	$status = if ($null -eq $release) {
		'missing-release'
	} elseif ($missingAssets.Count -gt 0) {
		'missing-assets'
	} else {
		'complete'
	}
	$rows.Add([pscustomobject]@{
		upstream = $upstreamTag
		release = if ($null -ne $release) { $release.tag_name } else { '' }
		published_at = if ($null -ne $release) { $release.published_at } else { '' }
		status = $status
		missing_assets = ($missingAssets -join ',')
		unexpected_assets = ($unexpectedAssets -join ',')
		url = if ($null -ne $release) { $release.html_url } else { '' }
	})
}

$rows | Format-Table -AutoSize
$complete = @($rows | Where-Object status -eq 'complete').Count
$missing = @($rows | Where-Object status -ne 'complete').Count
Write-Host "Release audit: $complete/55 complete; $missing incomplete."

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
	$outputParent = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
	if (-not (Test-Path -LiteralPath $outputParent)) {
		New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
	}
	$rows | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutputPath -Encoding utf8
}

if ($missing -ne 0) { exit 1 }
