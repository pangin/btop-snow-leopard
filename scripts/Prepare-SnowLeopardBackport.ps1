param(
	[Parameter(Mandatory = $true)]
	[string] $SourcePath,

	[Parameter(Mandatory = $true)]
	[string] $Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$sourceRoot = (Resolve-Path -LiteralPath $SourcePath).Path
$referenceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Read-SourceFile([string] $RelativePath) {
	$path = Join-Path $sourceRoot $RelativePath
	if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
		throw "Required source file is missing: $RelativePath"
	}
	return [IO.File]::ReadAllText($path).Replace("`r`n", "`n")
}

function Write-SourceFile([string] $RelativePath, [string] $Content) {
	$path = Join-Path $sourceRoot $RelativePath
	$parent = Split-Path -Parent $path
	if (-not (Test-Path -LiteralPath $parent)) {
		New-Item -ItemType Directory -Path $parent | Out-Null
	}
	[IO.File]::WriteAllText($path, $Content, $utf8NoBom)
}

function Read-GitFile([string] $Revision, [string] $RelativePath) {
	$content = @(& git -C $referenceRoot show "${Revision}:$RelativePath")
	if ($LASTEXITCODE -ne 0) {
		throw "Could not read $RelativePath from git revision $Revision."
	}
	return ($content -join "`n") + "`n"
}

function Replace-Required([string] $Content, [string] $Old, [string] $New, [string] $Description) {
	if (-not $Content.Contains($Old)) {
		throw "Could not apply required transformation: $Description"
	}
	return $Content.Replace($Old, $New)
}

$parsedVersion = [version]$Version.TrimStart('v')
$isLegacyV1 = $parsedVersion -ge [version]'1.0.0' -and $parsedVersion -lt [version]'1.1.0'

if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'src/osx/btop_collect.cpp'))) {
	if (-not $isLegacyV1) {
		throw "$Version has no supported upstream macOS backend."
	}

	# The official macOS port was merged immediately after v1.0.24 as commit
	# c0e17a6. Transplant that backend while retaining each v1.0.x tag's core.
	foreach ($relative in @(
		'src/osx/btop_collect.cpp',
		'src/osx/sensors.cpp',
		'src/osx/sensors.hpp',
		'src/osx/smc.cpp',
		'src/osx/smc.hpp'
	)) {
		Write-SourceFile $relative (Read-GitFile 'c0e17a6' $relative)
	}
	Write-SourceFile 'Makefile' (Read-GitFile 'c0e17a6' 'Makefile')

	$legacyShared = Read-SourceFile 'src/btop_shared.hpp'
	if (-not $legacyShared.Contains('extern void clean_quit(int sig);')) {
		$legacyShared = Replace-Required $legacyShared "void banner_gen();`n" "void banner_gen();`n`nextern void clean_quit(int sig);`n" 'legacy clean-quit declaration'
		Write-SourceFile 'src/btop_shared.hpp' $legacyShared
	}

	$legacyConfig = Read-SourceFile 'src/btop_config.cpp'
	$configExit = "Global::exit_error_msg = `"Exception during Config::unlock() : `" + (string)e.what();`n`t`t`texit(1);"
	if ($legacyConfig.Contains($configExit)) {
		$legacyConfig = $legacyConfig.Replace($configExit, $configExit.Replace('exit(1);', 'clean_quit(1);'))
		Write-SourceFile 'src/btop_config.cpp' $legacyConfig
	}

	$legacyInput = Read-SourceFile 'src/btop_input.cpp'
	$inputExit = "if (str_to_lower(key) == `"q`") {`n`t`t`t`t`texit(0);"
	if ($legacyInput.Contains($inputExit)) {
		$legacyInput = $legacyInput.Replace($inputExit, $inputExit.Replace('exit(0);', 'clean_quit(0);'))
		Write-SourceFile 'src/btop_input.cpp' $legacyInput
	}

	$legacyMenu = Read-SourceFile 'src/btop_menu.cpp'
	$menuExit = "case Quit:`n`t`t`t`t`texit(0);"
	if ($legacyMenu.Contains($menuExit)) {
		$legacyMenu = $legacyMenu.Replace($menuExit, $menuExit.Replace('exit(0);', 'clean_quit(0);'))
		Write-SourceFile 'src/btop_menu.cpp' $legacyMenu
	}

	$legacyToolsCpp = Read-SourceFile 'src/btop_tools.cpp'
	if (-not $legacyToolsCpp.Contains('#include <ranges>')) {
		$legacyToolsCpp = Replace-Required $legacyToolsCpp '#include <utility>' "#include <utility>`n#include <ranges>" 'legacy ranges declaration'
		Write-SourceFile 'src/btop_tools.cpp' $legacyToolsCpp
	}

	$legacyToolsHpp = Read-SourceFile 'src/btop_tools.hpp'
	if (-not $legacyToolsHpp.Contains('#ifndef HOST_NAME_MAX')) {
		$hostNameFallback = @'
#include <limits.h>
#ifndef HOST_NAME_MAX
	#ifdef __APPLE__
		#define HOST_NAME_MAX 255
	#else
		#define HOST_NAME_MAX 64
	#endif
#endif
'@
		$legacyToolsHpp = Replace-Required $legacyToolsHpp '#include <pthread.h>' ("#include <pthread.h>`n" + $hostNameFallback) 'legacy hostname limit fallback'
		Write-SourceFile 'src/btop_tools.hpp' $legacyToolsHpp
	}
}

foreach ($smcFile in @('src/osx/smc.cpp', 'src/osx/smc.hpp')) {
	$referencePath = Join-Path $referenceRoot $smcFile
	if (-not (Test-Path -LiteralPath $referencePath -PathType Leaf)) {
		throw "Snow Leopard SMC reference file is missing: $referencePath"
	}
	$referenceContent = [IO.File]::ReadAllText($referencePath).Replace("`r`n", "`n")
	Write-SourceFile $smcFile $referenceContent
}

$btop = Read-SourceFile 'src/btop.cpp'
if ($isLegacyV1) {
	$timedJoin = @'
	if (Global::_runner_started) {
		struct timespec ts;
		ts.tv_sec = 5;
		if (pthread_timedjoin_np(Runner::runner_id, NULL, &ts) != 0) {
			Logger::error("Failed to join _runner thread!");
			pthread_cancel(Runner::runner_id);
		}
	}
'@
	if ($btop.Contains($timedJoin)) {
		$darwinJoin = @'
	if (Global::_runner_started) {
#ifdef __APPLE__
		if (pthread_join(Runner::runner_id, NULL) != 0) {
			Logger::error("Failed to join _runner thread!");
			pthread_cancel(Runner::runner_id);
		}
#else
		struct timespec ts;
		ts.tv_sec = 5;
		if (pthread_timedjoin_np(Runner::runner_id, NULL, &ts) != 0) {
			Logger::error("Failed to join _runner thread!");
			pthread_cancel(Runner::runner_id);
		}
#endif
	}
'@
		$btop = $btop.Replace($timedJoin, $darwinJoin)
	}

	$quickExit = @'
	if (Tools::active_locks > 0) {
		quick_exit((sig != -1 ? sig : 0));
	}
'@
	if ($btop.Contains($quickExit)) {
		$btop = $btop.Replace($quickExit, "#ifndef __APPLE__`n" + $quickExit + "`n#endif")
	}

	$mutexCtor = 'thread_lock(pthread_mutex_t& mtx) : pt_mutex(mtx) { status = pthread_mutex_lock(&pt_mutex); }'
	if ($btop.Contains($mutexCtor)) {
		$btop = $btop.Replace($mutexCtor, 'thread_lock(pthread_mutex_t& mtx) : pt_mutex(mtx) { pthread_mutex_init(&pt_mutex, NULL); status = pthread_mutex_lock(&pt_mutex); }')
	}

	$ttyDetection = @'
	else if (not Global::arg_tty and Term::current_tty.starts_with("/dev/tty")) {
		Config::set("tty_mode", true);
		Logger::info("Real tty detected: setting 16 color mode and using tty friendly graph symbols");
	}
'@
	if ($btop.Contains($ttyDetection)) {
		$btop = $btop.Replace($ttyDetection, "#ifndef __APPLE__`n" + $ttyDetection + "`n#endif")
	}
	Write-SourceFile 'src/btop.cpp' $btop
}

if ($btop.Contains('std::setlocale') -and -not $btop.Contains('#include <clocale>')) {
	$btop = Replace-Required $btop '#include <csignal>' "#include <csignal>`n#include <clocale>" 'C++ locale declarations on the Snow Leopard SDK'
	Write-SourceFile 'src/btop.cpp' $btop
}

# Clang defines __GNUC__ as 4, which made early btop releases select their
# sem_init() fallback. Darwin does not implement unnamed POSIX semaphores, so
# that fallback spins the Runner thread continuously. Use Clang's working C++20
# binary_semaphore path and keep standard-library includes outside namespaces.
if ($btop.Contains('sem_init(&do_work') -and $btop.Contains('#if __GNUC__ < 11')) {
	$semaphoreIncludes = @'
#if !defined(__clang__) && __GNUC__ < 11
	#include <semaphore.h>
#else
	#include <semaphore>
#endif

'@
	$btop = Replace-Required $btop '#include <btop_shared.hpp>' ($semaphoreIncludes + '#include <btop_shared.hpp>') 'top-level semaphore includes'
	$btop = Replace-Required $btop "#if __GNUC__ < 11`n`t#include <semaphore.h>`n`tsem_t do_work;" "#if !defined(__clang__) && __GNUC__ < 11`n`tsem_t do_work;" 'Clang binary-semaphore selection'
	$btop = Replace-Required $btop "#else`n`t#include <semaphore>`n`tstd::binary_semaphore do_work(0);" "#else`n`tstd::binary_semaphore do_work(0);" 'namespace-safe C++ semaphore include'
	Write-SourceFile 'src/btop.cpp' $btop
}

$shared = Read-SourceFile 'src/btop_shared.hpp'
if ($shared.Contains('#include <net/if.h>') -and -not $shared.Contains('#include <sys/socket.h>')) {
	$shared = Replace-Required $shared "#include <net/if.h>" "#include <sys/socket.h>`n#include <net/if.h>" 'Snow Leopard socket header ordering'
	Write-SourceFile 'src/btop_shared.hpp' $shared
}

$osx = Read-SourceFile 'src/osx/btop_collect.cpp'
$osx = Replace-Required $osx 'p.external_page_count * Shared::pageSize' 'p.inactive_count * Shared::pageSize' 'Snow Leopard cached-memory field'
$osx = Replace-Required $osx 'disk.total = vfs.f_blocks * vfs.f_frsize;' 'disk.total = static_cast<std::uint64_t>(vfs.f_blocks) * static_cast<std::uint64_t>(vfs.f_frsize);' 'i386 disk-total widening'
$osx = Replace-Required $osx 'disk.free = vfs.f_bfree * vfs.f_frsize;' 'disk.free = static_cast<std::uint64_t>(vfs.f_bfree) * static_cast<std::uint64_t>(vfs.f_frsize);' 'i386 disk-free widening'

$rusageOld = @'
		rusage_info_current rusage;
		if (proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, (void **)&rusage) == 0) {
			// this fails for processes we don't own - same as in Linux
			detailed.io_read = floating_humanizer(rusage.ri_diskio_bytesread);
			detailed.io_write = floating_humanizer(rusage.ri_diskio_byteswritten);
		}
'@
$rusageNew = @'
#if defined(RUSAGE_INFO_CURRENT)
		rusage_info_current rusage;
		if (proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, (void **)&rusage) == 0) {
			// this fails for processes we don't own - same as in Linux
			detailed.io_read = floating_humanizer(rusage.ri_diskio_bytesread);
			detailed.io_write = floating_humanizer(rusage.ri_diskio_byteswritten);
		}
#else
		detailed.io_read = "N/A";
		detailed.io_write = "N/A";
#endif
'@
$osx = Replace-Required $osx $rusageOld $rusageNew 'Snow Leopard process I/O fallback'
$osx = $osx.Replace('kIOMainPortDefault', 'kIOMasterPortDefault')
Write-SourceFile 'src/osx/btop_collect.cpp' $osx

$sensors = Read-SourceFile 'src/osx/sensors.cpp'
if ($sensors.Contains('#include <IOKit/hidsystem/IOHIDEventSystemClient.h>') -and
	-not $sensors.Contains('__MAC_OS_X_VERSION_MIN_REQUIRED')) {
	$sensorStart = "#include `"sensors.hpp`"`n`n#include <CoreFoundation/CoreFoundation.h>"
	$guardedStart = "#include <Availability.h>`n#include `"sensors.hpp`"`n`n#if __MAC_OS_X_VERSION_MIN_REQUIRED > 101504`n#include <CoreFoundation/CoreFoundation.h>"
	$sensors = Replace-Required $sensors $sensorStart $guardedStart 'newer-macOS IOHID sensor guard'
	$sensors = $sensors.TrimEnd([char[]]"`n") + @'

#else
long long Cpu::ThermalSensors::getSensors() {
	return 0ll;
}
#endif
'@
	Write-SourceFile 'src/osx/sensors.cpp' $sensors
}

$toolsCpp = Read-SourceFile 'src/btop_tools.cpp'
$openOld = 'auto dev_tty = open("/dev/tty", O_RDONLY | O_CLOEXEC);'
if ($toolsCpp.Contains($openOld)) {
	$openNew = @'
auto dev_tty = open("/dev/tty", O_RDONLY
#if defined(O_CLOEXEC)
				| O_CLOEXEC
#endif
			);
			if (dev_tty != -1) {
#if !defined(O_CLOEXEC)
				const auto descriptor_flags = fcntl(dev_tty, F_GETFD);
				if (descriptor_flags != -1) fcntl(dev_tty, F_SETFD, descriptor_flags | FD_CLOEXEC);
#endif
'@
	$openWithFollowingIf = $openOld + "`n`t`t`tif (dev_tty != -1) {"
	$toolsCpp = Replace-Required $toolsCpp $openWithFollowingIf $openNew 'O_CLOEXEC fallback'
	Write-SourceFile 'src/btop_tools.cpp' $toolsCpp
}

$input = Read-SourceFile 'src/btop_input.cpp'
if ($input.Contains('cin.rdbuf()->in_avail()')) {
	if (-not $input.Contains('#include <thread>')) {
		$input = Replace-Required $input '#include <vector>' "#include <vector>`n#include <thread>`n#include <mutex>" 'threaded terminal-input includes'
	}
	$inputThread = @'
	struct InputThr {
		InputThr() : thr(run, this) {
		}

		static void run(InputThr* that) {
			that->runImpl();
		}

		void runImpl() {
			char ch = 0;
			while (cin.get(ch)) {
				std::lock_guard<std::mutex> guard(lock);
				current.push_back(ch);
				if (current.size() > 100) current.clear();
			}
		}

		size_t avail() {
			std::lock_guard<std::mutex> guard(lock);
			return current.size();
		}

		std::string get() {
			std::string result;
			{
				std::lock_guard<std::mutex> guard(lock);
				result.swap(current);
			}
			return result;
		}

		static InputThr& instance() {
			// Intentional leak: the reader owns a blocking terminal read until process exit.
			static InputThr* input = new InputThr();
			return *input;
		}

		std::string current;
		std::mutex lock;
		std::thread thr;
	};
'@
	$input = Replace-Required $input "`tbool poll(int timeout) {" ($inputThread + "`n`n`tbool poll(int timeout) {") 'threaded terminal-input reader'
	$input = $input.Replace('return cin.rdbuf()->in_avail() > 0;', 'return InputThr::instance().avail() > 0;')
	$input = $input.Replace('if (cin.rdbuf()->in_avail() > 0) return true;', 'if (InputThr::instance().avail() > 0) return true;')
	$getPattern = '(?m)^\t\tstring key;\n\t\twhile \(cin\.rdbuf\(\)->in_avail\(\) > 0 and key\.size\(\) < 100\) key \+= cin\.get\(\);\n\t\tif \(cin\.rdbuf\(\)->in_avail\(\) > 0\) [^\n]+;'
	$updatedGet = [regex]::Replace($input, $getPattern, "`t`tstring key = InputThr::instance().get();", 1)
	if ($updatedGet -eq $input) { throw 'Could not replace stream-buffer terminal-input retrieval.' }
	$input = $updatedGet
	$input = $input.Replace('while (cin.rdbuf()->in_avail() < 1)', 'while (InputThr::instance().avail() < 1)')
	$clearPattern = '(?ms)^\tvoid clear\(\) \{.*?^\t\}\n\n^\tvoid process'
	$clearReplacement = "`tvoid clear() {`n`t`t// Input is owned by InputThr.`n`t}`n`n`tvoid process"
	$updatedInput = [regex]::Replace($input, $clearPattern, $clearReplacement, 1)
	if ($updatedInput -eq $input) { throw 'Could not replace the stream-buffer input clear function.' }
	if ($updatedInput.Contains('cin.rdbuf()->in_avail()')) { throw 'Stream-buffer input polling remains after transformation.' }
	Write-SourceFile 'src/btop_input.cpp' $updatedInput
}

$makefile = Read-SourceFile 'Makefile'
$makefile = $makefile.Replace('-std=c++23', '-std=c++2b')
$makefile = $makefile.Replace(' -lIOReport', '')
Write-SourceFile 'Makefile' $makefile

$toolsHpp = Read-SourceFile 'src/btop_tools.hpp'
if ($toolsHpp.Contains('std::ranges::to<std::vector<std::string>>()')) {
	$splitPattern = '(?ms)^\tconstexpr auto ssplit\(std::string_view str, char delim = '' ''\) \{.*?^\t\}'
	$splitReplacement = @'
	inline auto ssplit(std::string_view str, char delim = ' ') {
		std::vector<std::string> result;
		for (std::size_t start = 0; start <= str.size();) {
			const auto end = str.find(delim, start);
			const auto length = (end == std::string_view::npos ? str.size() : end) - start;
			if (length > 0) result.emplace_back(str.substr(start, length));
			if (end == std::string_view::npos) break;
			start = end + 1;
		}
		return result;
	}
'@
	$updated = [regex]::Replace($toolsHpp, $splitPattern, $splitReplacement, 1)
	if ($updated -eq $toolsHpp) { throw 'Could not replace the ranges::to string splitter.' }
	Write-SourceFile 'src/btop_tools.hpp' $updated
}

$mainPath = Join-Path $sourceRoot 'src/main.cpp'
if (Test-Path -LiteralPath $mainPath -PathType Leaf) {
	$main = Read-SourceFile 'src/main.cpp'
	$mainOld = 'return btop_main(std::views::counted(std::next(argv), argc - 1) | std::ranges::to<std::vector<std::string_view>>());'
	if ($main.Contains($mainOld)) {
		$mainNew = @'
std::vector<std::string_view> args;
	args.reserve(argc > 1 ? static_cast<std::size_t>(argc - 1) : 0);
	for (int i = 1; i < argc; ++i) args.emplace_back(argv[i]);
	return btop_main(args);
'@
		$main = Replace-Required $main $mainOld $mainNew 'ranges::to command-line conversion'
		Write-SourceFile 'src/main.cpp' $main
	}
}

$config = Read-SourceFile 'src/btop_config.cpp'
if ($config.Contains('static constexpr auto get_xdg_state_dir()')) {
	$config = $config.Replace('static constexpr auto get_xdg_state_dir()', 'static auto get_xdg_state_dir()')
	Write-SourceFile 'src/btop_config.cpp' $config
}

# iTerm2 2.x, the last iTerm2 for Mac OS X 10.6, cannot display 24-bit color:
# it applies the R;G;B of SGR 38;2;R;G;B as plain attributes (0 reset, 1 bold,
# 4 underline, 7 inverse). Detect it and force btop's 256-color path, both at
# startup and when the truecolor option is toggled in the options menu.
function Replace-SingleLine([string] $Content, [string] $Pattern, [string] $Replacement, [string] $Description) {
	$found = [regex]::Matches($Content, $Pattern).Count
	if ($found -ne 1) {
		throw "Could not apply required transformation: $Description (expected 1 match, found $found)"
	}
	return [regex]::Replace($Content, $Pattern, $Replacement)
}

$legacyItermForce = '${1}if (Term::legacy_iterm2()) Config::set("lowcolor", true);'

$toolsHpp = Read-SourceFile 'src/btop_tools.hpp'
if (-not $toolsHpp.Contains('bool legacy_iterm2();')) {
	$toolsHpp = Replace-Required $toolsHpp "`tvoid restore();`n}" "`tvoid restore();`n`n`t//* Returns true under iTerm2 2.x, which cannot display 24-bit color`n`tbool legacy_iterm2();`n}" 'iTerm2 2.x detection declaration'
	Write-SourceFile 'src/btop_tools.hpp' $toolsHpp
}

$toolsCpp = Read-SourceFile 'src/btop_tools.cpp'
if (-not $toolsCpp.Contains('bool legacy_iterm2() {')) {
	if (-not $toolsCpp.Contains('#include <cstdlib>')) {
		$toolsCpp = Replace-Required $toolsCpp '#include <utility>' "#include <utility>`n#include <cstdlib>" 'getenv declaration'
	}
	$legacyItermDefinition = @'

	bool legacy_iterm2() {
		//? iTerm2 2.x, the last iTerm2 for Mac OS X 10.6, sets TERM_PROGRAM=iTerm.app without
		//? TERM_PROGRAM_VERSION; 3.x sets both. 2.x reads SGR 38/48 only as 38;5;N and applies
		//? the R;G;B of 38;2;R;G;B as plain attributes (0 reset, 1 bold, 4 underline, 7 inverse).
		const char* program = std::getenv("TERM_PROGRAM");
		const char* version = std::getenv("TERM_PROGRAM_VERSION");
		return program != nullptr and std::string_view(program) == "iTerm.app"
			and (version == nullptr or version[0] == '\0');
	}
'@
	$toolsCpp = Replace-SingleLine $toolsCpp '(?m)^\}\n\n(?=//\? -+ FUNCTIONS)' ($legacyItermDefinition.Replace('$', '$$') + "`n}`n`n") 'iTerm2 2.x detection'
	Write-SourceFile 'src/btop_tools.cpp' $toolsCpp
}

$btop = Read-SourceFile 'src/btop.cpp'
if (-not $btop.Contains('Term::legacy_iterm2()')) {
	$startupPattern = '(?m)^(\t+)(Config::set\("lowcolor", \((?:Global::arg_)?low_color \? true : not Config::getB\("truecolor"\)\)\);)$'
	$btop = Replace-SingleLine $btop $startupPattern ('${1}${2}' + "`n" + $legacyItermForce) 'iTerm2 2.x startup color mode'
	Write-SourceFile 'src/btop.cpp' $btop
}

$menu = Read-SourceFile 'src/btop_menu.cpp'
if (-not $menu.Contains('Term::legacy_iterm2()')) {
	$togglePattern = '(?m)^(\t+)(Config::flip\("lowcolor"\);)$'
	$menu = Replace-SingleLine $menu $togglePattern ('${1}${2}' + "`n" + $legacyItermForce) 'iTerm2 2.x truecolor toggle'
	Write-SourceFile 'src/btop_menu.cpp' $menu
}

# The main menu builds its six label colors without consulting lowcolor, so it
# sent 24-bit SGR even under --low-color. Pass the color mode like the rest of
# btop does.
$menu = Read-SourceFile 'src/btop_menu.cpp'
$mainMenuColorPattern = 'Theme::hex_to_color\((Global::Banner_src\.at\([024]\)\.at\(0\)|"#(?:CC|AA|80)")\)'
$found = [regex]::Matches($menu, $mainMenuColorPattern).Count
if ($found -gt 0) {
	if ($found -ne 6) {
		throw "Could not apply required transformation: main menu low-color labels (expected 6 matches, found $found)"
	}
	$menu = [regex]::Replace($menu, $mainMenuColorPattern, 'Theme::hex_to_color(${1}, Config::getB("lowcolor"))')
	Write-SourceFile 'src/btop_menu.cpp' $menu
}
elseif (-not $menu.Contains('Theme::hex_to_color("#CC", Config::getB("lowcolor"))')) {
	throw 'Could not apply required transformation: main menu low-color labels (no known form found)'
}

$buildScript = @'
#!/bin/sh

set -eu

MACPORTS_PREFIX=${MACPORTS_PREFIX:-/opt/local}
LLVM_PREFIX=${LLVM_PREFIX:-$MACPORTS_PREFIX/libexec/llvm-16}
CXX=${CXX:-$MACPORTS_PREFIX/bin/clang++-mp-16}
GMAKE=${GMAKE:-$MACPORTS_PREFIX/bin/gmake}
SNOW_LEOPARD_LDFLAGS="-nostdlib++ $LLVM_PREFIX/lib/libc++/libc++.a $LLVM_PREFIX/lib/libc++/libc++abi.a -L$MACPORTS_PREFIX/lib -lMacportsLegacySupport"

exec "$GMAKE" -j1 \
	CXX="$CXX" \
	GPU_SUPPORT=false \
	ARCH=i386 \
	THREADS=1 \
	OPTFLAGS=-O1 \
	FORTIFY_SOURCE=false \
	LDFLAGS="$SNOW_LEOPARD_LDFLAGS" \
	"$@"
'@
Write-SourceFile 'build-snow-leopard.sh' $buildScript

$notes = @'
# Mac OS X Snow Leopard backport

This source tree backports btop @VERSION@ to Mac OS X 10.6.8 on 32-bit Intel
Macs. Build it with MacPorts Clang 16, GNU Make, and LegacySupport:

```sh
sudo /opt/local/bin/port install clang-16 gmake legacy-support
sh ./build-snow-leopard.sh
./bin/btop --version
```

The build statically links the modern libc++ and libc++abi archives included
with Clang 16. GPU metrics and detailed per-process disk I/O are unavailable on
Snow Leopard. The source also includes fixes for the 10.6 VM API, socket header
ordering, `O_CLOEXEC`, Clang runner signalling and terminal input, and 32-bit
disk-size overflow where applicable. Under iTerm2 2.x (`TERM_PROGRAM=iTerm.app`
without `TERM_PROGRAM_VERSION`) it uses 256 colors, because that terminal
cannot display 24-bit color, and the main menu honors `--low-color`.

@BACKEND_PROVENANCE@
'@
$notes = $notes.Replace('@VERSION@', $Version)
$backendProvenance = if ($isLegacyV1) {
	'This v1.0.x tree retains the selected upstream release core and transplants the official macOS backend merged immediately after v1.0.24 in upstream commit `c0e17a6`.'
}
else {
	'This release already contained an upstream macOS backend; only Snow Leopard compatibility changes are applied.'
}
$notes = $notes.Replace('@BACKEND_PROVENANCE@', $backendProvenance)
Write-SourceFile 'SNOW_LEOPARD.md' $notes

$readme = Read-SourceFile 'README.md'
if (-not $readme.Contains('SNOW_LEOPARD.md')) {
	$firstNewline = $readme.IndexOf("`n")
	if ($firstNewline -lt 0) { throw 'README.md has no first line.' }
	$notice = "`n> **Snow Leopard backport:** This tree contains the tested btop $Version port for`n> Mac OS X 10.6.8 i386. See [SNOW_LEOPARD.md](SNOW_LEOPARD.md).`n"
	$readme = $readme.Insert($firstNewline + 1, $notice)
	Write-SourceFile 'README.md' $readme
}

[pscustomobject]@{
	Version = $Version
	SourcePath = $sourceRoot
	Status = 'prepared'
} | ConvertTo-Json -Compress
