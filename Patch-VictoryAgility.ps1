<#
.SYNOPSIS
    Patch a VIctory fork for Windows 10: D3D12 Agility SDK exports.

.DESCRIPTION
    Windows 10's in-box D3D12 runtime stops at shader model 6.5 and refuses
    the heap-indexed root signatures every translated pipeline uses. This
    tool adds the same fix used in the working forks:

      * apps/.../<the crate named victory>/src/agility.rs
          exports D3D12SDKVersion and D3D12SDKPath from the executable;
      * .../build.rs
          exports them only when D3D12Core.dll is there, and copies the DLL
          to target\<profile>\D3D12\;
      * `mod agility;` in the crate's src/main.rs;
      * D3D12Core.dll at the repository root, for the build script.

    It finds the crate named "victory" anywhere in the workspace, backs up
    what it replaces, and is safe to run twice. Everything it needs is in
    this one file (no other scripts or templates).

.PARAMETER Repo
    The fork's folder (the one with Cargo.toml). Asked for if omitted.

.PARAMETER D3D12Core
    D3D12Core.dll to use (1.620.x for SdkVersion 620). If omitted, the tool
    looks beside this script, in the repository, at VICTORY_D3D12_CORE, and
    in the known local checkouts.

.PARAMETER SdkVersion
    The Agility SDK version written into agility.rs. Taken from the DLL's
    version when it can be read (1.620.x -> 620).

.PARAMETER Profile
    release (default), fast or diag. Used with -Build and for the final
    check of the built executable.

.PARAMETER Build
    Run `cargo build` in the repository after patching.

.PARAMETER Check
    Only report whether the repository is already patched and whether the
    DLL and the built executable's exports are there. Writes nothing.

.PARAMETER Force
    Replace a build.rs that is not this patch's (a backup is kept), and
    refresh the patch's own files.

.PARAMETER NoDllCopy
    Patch only; do not copy D3D12Core.dll into the repository.

.PARAMETER DryRun
    Show what would be written and where, and write nothing.

.EXAMPLE
    .\Patch-VictoryAgility.ps1 D:\VIctoryUnified

.EXAMPLE
    .\Patch-VictoryAgility.ps1 D:\some\victory-fork -D3D12Core C:\SDK\D3D12Core.dll -Build -Profile fast

.EXAMPLE
    .\Patch-VictoryAgility.ps1 -Repo D:\VIctoryUnified -Check
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Repo,
    [string]$D3D12Core,
    [int]$SdkVersion = 620,
    [ValidateSet('release', 'fast', 'diag')][string]$Profile = 'release',
    [switch]$Build,
    [switch]$Check,
    [switch]$Force,
    [switch]$NoDllCopy,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

$AgilityTemplate = @'
//! The D3D12 Agility SDK exports, for Windows 10.
//!
//! Windows 10's in-box D3D12 runtime stops at shader model 6.5 and refuses
//! root signatures that index the descriptor heaps directly (flags 0x400,
//! 0x800, "Unsupported bit-flag set (root signature flags c01)"), which
//! every translated pipeline uses. D3D12 looks for these two exports on the
//! process's executable; when they name a runtime newer than the system's,
//! it loads `D3D12Core.dll` from `D3D12SDKPath` (relative to the executable)
//! instead. `build.rs` exports both only when `D3D12\D3D12Core.dll` is beside
//! the executable at build time: with the exports but no DLL, device
//! creation fails with `D3D12_ERROR_INVALID_REDIST`. Without the exports the
//! in-box runtime is used, as before (Windows 11).
//!
//! Added by victory-agility-patch.
#![allow(non_upper_case_globals)]

/// The runtime's SDK version: the minor number of the
/// `Microsoft.Direct3D.D3D12` NuGet package whose `D3D12Core.dll` goes in
/// `D3D12\` (1.620.x). Keep the two in step.
#[unsafe(no_mangle)]
pub static D3D12SDKVersion: u32 = 620;

/// A C string pointer D3D12 reads once at device creation.
#[repr(transparent)]
pub struct SdkPath(*const std::ffi::c_char);

// SAFETY: points at a static, immutable C string.
unsafe impl Sync for SdkPath {}

/// Where `D3D12Core.dll` is, relative to the executable.
#[unsafe(no_mangle)]
pub static D3D12SDKPath: SdkPath = SdkPath(c".\\D3D12\\".as_ptr());
'@

$BuildTemplate = @'
//! Build script: D3D12 Agility SDK exports for Windows 10.
//!
//! D3D12 finds D3D12SDKVersion/D3D12SDKPath on the executable and then loads
//! `D3D12Core.dll` from `D3D12\` beside it. The exports are added only when
//! the DLL is (or can be copied) there: with the exports but no DLL, device
//! creation fails with D3D12_ERROR_INVALID_REDIST. Without them the in-box
//! runtime is used (fine on Windows 11).
//!
//! Added by victory-agility-patch. It looks for D3D12Core.dll in
//! `D3D12/`, the repo root, or `VICTORY_D3D12_CORE`.

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    victory_agility_exports();
}

// --- victory-agility-patch (generated) -------------------------------------
// Windows 10's in-box D3D12 stops at SM 6.5 and refuses the heap-indexed
// root-signature flags that every translated pipeline uses. Export the
// Agility SDK entry points when D3D12Core.dll is beside the executable.
fn victory_agility_exports() {
    let out = std::path::PathBuf::from(
        std::env::var_os("OUT_DIR").expect("cargo sets OUT_DIR"),
    );
    let profile = match out.ancestors().nth(3) {
        Some(profile) => profile,
        None => return,
    };
    let dir = profile.join("D3D12");
    let core = dir.join("D3D12Core.dll");
    if !core.is_file() {
        if let Some(src) = victory_find_d3d12_core(profile) {
            println!("cargo:rerun-if-changed={}", src.display());
            if std::fs::create_dir_all(&dir).is_ok() && std::fs::copy(&src, &core).is_ok() {
                println!(
                    "cargo:warning=D3D12Core.dll copied from {} (Windows 10 Agility SDK)",
                    src.display()
                );
            }
        }
    }
    if dir.is_dir() {
        println!("cargo:rerun-if-changed={}", dir.display());
    }
    if !core.is_file() {
        println!(
            "cargo:warning=no D3D12\\D3D12Core.dll beside victory.exe: Windows 10 will refuse \
             heap-indexed root signatures (its in-box D3D12 is SM 6.5)"
        );
        return;
    }
    println!("cargo:rerun-if-changed={}", core.display());
    if std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc") {
        println!("cargo:rustc-link-arg-bins=/EXPORT:D3D12SDKVersion,DATA");
        println!("cargo:rustc-link-arg-bins=/EXPORT:D3D12SDKPath,DATA");
    }
}

fn victory_find_d3d12_core(profile: &std::path::Path) -> Option<std::path::PathBuf> {
    if let Some(p) = std::env::var_os("VICTORY_D3D12_CORE") {
        let p = std::path::PathBuf::from(p);
        if p.is_file() {
            return Some(p);
        }
    }
    let mut roots = Vec::new();
    if let Some(m) = std::env::var_os("CARGO_MANIFEST_DIR") {
        roots.push(std::path::PathBuf::from(m));
    }
    roots.push(profile.to_path_buf());
    for root in &roots {
        for at in root.ancestors() {
            for rel in [
                "D3D12/D3D12Core.dll",
                "D3D12Core.dll",
                "cool_fox/D3D12/D3D12Core.dll",
                "deps/D3D12Core.dll",
                ".d3d12/D3D12Core.dll",
            ] {
                let p = at.join(rel);
                if p.is_file() {
                    return Some(p);
                }
            }
        }
    }
    None
}
// --- end victory-agility-patch ---------------------------------------------
'@

function Write-Step([string]$Text) { Write-Host "  $Text" }
function Write-Ok([string]$Text) { Write-Host "  [ok] $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "  [!] $Text" -ForegroundColor Yellow }

function Find-VictoryPackages([string]$Root) {
    $toms = Get-ChildItem -LiteralPath $Root -Recurse -Filter Cargo.toml -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/]target[\\/]' }
    $found = @()
    foreach ($t in $toms) {
        $text = Get-Content -LiteralPath $t.FullName -Raw
        if ($text -match '(?m)^\s*name\s*=\s*"victory"\s*$' -and
            (Test-Path -LiteralPath (Join-Path $t.DirectoryName 'src\main.rs'))) {
            $found += $t.DirectoryName
        }
    }
    return $found
}

function Find-AgilityDll([string]$Repository, [string]$Explicit) {
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) {
            throw "No D3D12Core.dll at $Explicit"
        }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }
    if ($env:VICTORY_D3D12_CORE -and (Test-Path -LiteralPath $env:VICTORY_D3D12_CORE -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $env:VICTORY_D3D12_CORE).Path
    }
    $candidates = @(
        (Join-Path $PSScriptRoot 'D3D12Core.dll'),
        (Join-Path $PSScriptRoot 'agility\D3D12Core.dll'),
        (Join-Path $PSScriptRoot 'D3D12\D3D12Core.dll'),
        (Join-Path $Repository 'D3D12Core.dll'),
        (Join-Path $Repository 'D3D12\D3D12Core.dll'),
        (Join-Path $Repository 'deps\D3D12Core.dll'),
        (Join-Path $Repository '.d3d12\D3D12Core.dll'),
        'D:\yaekai-victory-scarlett-3070\target\diag\D3D12\D3D12Core.dll',
        'D:\VIctoryUnified\target\fast\D3D12\D3D12Core.dll',
        'D:\VIctoryUnified-v1.0\bin\D3D12\D3D12Core.dll'
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $c).Path
        }
    }
    return $null
}

function Get-DllSdkVersion([string]$Path) {
    $vi = (Get-Item -LiteralPath $Path).VersionInfo
    if ($vi.FileVersion -match '^\d+\.(\d+)\.') { return [int]$Matches[1] }
    return $null
}

function Add-AgilityModule([string]$MainPath) {
    $lines = [System.IO.File]::ReadAllLines($MainPath)
    $at = 0
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $t = $lines[$i].Trim()
        if ($t -eq '' -or $t.StartsWith('//!') -or $t.StartsWith('#![')) { $at = $i + 1; continue }
        break
    }
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $at; $i++) { $out.Add($lines[$i]) }
    $out.Add('mod agility;')
    $out.Add('')
    for ($i = $at; $i -lt $lines.Length; $i++) { $out.Add($lines[$i]) }
    [System.IO.File]::WriteAllLines($MainPath, $out, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-Dumpbin {
    $cmd = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $roots = @(
        'C:\Program Files (x86)\Microsoft Visual Studio',
        'C:\Program Files\Microsoft Visual Studio'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $found = Get-ChildItem -LiteralPath $root -Recurse -Filter dumpbin.exe -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'Hostx64\\x64' } | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

# ---------------------------------------------------------------- arguments
if (-not $Repo) {
    $Repo = Read-Host 'Fork folder (the one with Cargo.toml)'
    if (-not $Repo) { throw 'No repository given.' }
}
$repoPath = (Resolve-Path -LiteralPath $Repo).Path
if (-not (Test-Path -LiteralPath (Join-Path $repoPath 'Cargo.toml'))) {
    throw "Not a Cargo workspace: $repoPath"
}

$packages = @(Find-VictoryPackages $repoPath)
if ($packages.Count -eq 0) { throw "No crate named 'victory' with src/main.rs under $repoPath." }
if ($packages.Count -gt 1) { throw "More than one 'victory' crate: $($packages -join ', ')" }
$pkg = $packages[0]
$mainPath = Join-Path $pkg 'src\main.rs'
$agilityPath = Join-Path $pkg 'src\agility.rs'
$buildPath = Join-Path $pkg 'build.rs'

Write-Host "VIctory fork: $repoPath"
Write-Step "crate: $pkg"

$dllPath = Find-AgilityDll $repoPath $D3D12Core
$dllSdk = $null
if ($dllPath) {
    $dllSdk = Get-DllSdkVersion $dllPath
    $vi = (Get-Item -LiteralPath $dllPath).VersionInfo
    Write-Step "D3D12Core.dll: $dllPath (version $($vi.FileVersion))"
    if ($dllSdk -and -not $PSBoundParameters.ContainsKey('SdkVersion')) {
        $SdkVersion = $dllSdk
    } elseif ($dllSdk -and $dllSdk -ne $SdkVersion) {
        Write-Warn "The DLL is SDK $dllSdk but SdkVersion $SdkVersion was asked; the runtime must match the DLL."
    }
} else {
    Write-Warn 'No D3D12Core.dll found: the patch is written, but on Windows 10 the build will not export the SDK entry points without one.'
    Write-Warn 'Put it beside this script (D3D12Core.dll or agility\D3D12Core.dll), in the repo, or pass -D3D12Core.'
}
Write-Step "SDK version: $SdkVersion"

# ---------------------------------------------------------------- state
$main = Get-Content -LiteralPath $mainPath -Raw
$hasMod = $main -match '(?m)^\s*mod\s+agility\s*;'
$hasAgility = (Test-Path -LiteralPath $agilityPath) -and
    ((Get-Content -LiteralPath $agilityPath -Raw) -match 'D3D12SDKVersion')
$hasBuild = (Test-Path -LiteralPath $buildPath) -and
    ((Get-Content -LiteralPath $buildPath -Raw) -match 'victory-agility-patch')
$patched = $hasMod -and $hasAgility -and $hasBuild

if ($Check) {
    Write-Host 'Check:'
    Write-Step "src/agility.rs: $(if ($hasAgility) { 'patched' } else { 'missing' })"
    Write-Step "build.rs: $(if ($hasBuild) { 'patched' } else { 'missing or foreign' })"
    Write-Step "main.rs mod agility: $(if ($hasMod) { 'yes' } else { 'no' })"
    $rootDll = Join-Path $repoPath 'D3D12Core.dll'
    Write-Step "D3D12Core.dll at repo root: $(if (Test-Path -LiteralPath $rootDll) { 'yes' } else { 'no' })"
    $exe = Join-Path $repoPath "target\$Profile\victory.exe"
    Write-Step "built exe: $(if (Test-Path -LiteralPath $exe) { $exe } else { 'not built' })"
    if (Test-Path -LiteralPath $exe) {
        $dumpbin = Get-Dumpbin
        if ($dumpbin) {
            $exports = & $dumpbin /exports $exe 2>&1 | Select-String 'D3D12SDK'
            if ($exports) {
                $exports | ForEach-Object { Write-Ok $_.Line.Trim() }
            } else {
                Write-Warn 'the executable has no D3D12SDK exports (built without the DLL beside it?)'
            }
        } else {
            Write-Warn 'dumpbin not found; cannot check the exports here.'
        }
    }
    if ($patched) { Write-Ok 'patched' } else { Write-Warn 'not fully patched' }
    exit 0
}

if ($main -match '#!\[forbid\(unsafe_code\)\]') {
    throw "src/main.rs forbids unsafe code; the Agility exports need a small unsafe impl. Patch by hand."
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$wrote = @()

if ($hasMod -and $hasAgility -and $hasBuild -and -not $Force) {
    Write-Ok 'already patched (use -Force to refresh the files)'
} else {
    if (-not $DryRun) {
        if (-not $hasMod -or $Force) {
            if ($hasMod) {
                Write-Step 'mod agility; already in main.rs'
            } else {
                Copy-Item -LiteralPath $mainPath -Destination "$mainPath.agility-bak-$stamp" -Force
                Add-AgilityModule $mainPath
                $wrote += $mainPath
                Write-Step "src/main.rs: inserted 'mod agility;' (backup: $(Split-Path $mainPath -Leaf).agility-bak-$stamp)"
            }
        }
        $agilityText = $AgilityTemplate -replace '(D3D12SDKVersion: u32 = )\d+', ('${1}' + $SdkVersion)
        [System.IO.File]::WriteAllText($agilityPath, $agilityText, (New-Object System.Text.UTF8Encoding($false)))
        $wrote += $agilityPath
        Write-Step 'src/agility.rs: written'
        if (Test-Path -LiteralPath $buildPath) {
            $existing = Get-Content -LiteralPath $buildPath -Raw
            if ($existing -notmatch 'victory-agility-patch') {
                if (-not $Force) {
                    throw "build.rs exists and is not this patch's: $buildPath (use -Force to back it up and replace)"
                }
                Copy-Item -LiteralPath $buildPath -Destination "$buildPath.bak-$stamp" -Force
                Write-Step "build.rs: foreign file backed up as build.rs.bak-$stamp"
            }
        }
        Set-Content -LiteralPath $buildPath -Value $BuildTemplate -Encoding UTF8
        # (Windows PowerShell 5.1 has no utf8NoBOM; rewrite without a BOM.)
        $buildText = [System.IO.File]::ReadAllText($buildPath)
        [System.IO.File]::WriteAllText($buildPath, $buildText, (New-Object System.Text.UTF8Encoding($false)))
        $wrote += $buildPath
        Write-Step 'build.rs: written'
    } else {
        Write-Step "would write: $agilityPath"
        Write-Step "would write: $buildPath"
        if (-not $hasMod) { Write-Step "would insert 'mod agility;' in: $mainPath" }
    }
}

if ($dllPath -and -not $NoDllCopy) {
    $dest = Join-Path $repoPath 'D3D12Core.dll'
    if (-not $DryRun) {
        Copy-Item -LiteralPath $dllPath -Destination $dest -Force
        Write-Step "D3D12Core.dll: copied to $dest"
    } else {
        Write-Step "would copy D3D12Core.dll to $dest"
    }
}

if ($Build -and -not $DryRun) {
    Write-Host "Building ($Profile) ..."
    Push-Location $repoPath
    try {
        $locked = @()
        if (Test-Path -LiteralPath (Join-Path $repoPath 'Cargo.lock')) { $locked = @('--locked') }
        if ($Profile -eq 'release') {
            $cargoArgs = @('build', '--release') + $locked + @('-p', 'victory')
        } elseif ($Profile -eq 'diag') {
            $cargoArgs = @('build', '--profile', 'diag', '--features', 'diagnostics') + $locked + @('-p', 'victory')
        } else {
            $cargoArgs = @('build', '--profile', 'fast') + $locked + @('-p', 'victory')
        }
        & cargo @cargoArgs
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed ($LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
}

if ($DryRun) {
    Write-Host 'Dry run: nothing written.'
    exit 0
}

# ---------------------------------------------------------------- verify
$exe = Join-Path $repoPath "target\$Profile\victory.exe"
$dllBeside = Join-Path $repoPath "target\$Profile\D3D12\D3D12Core.dll"
Write-Host 'Result:'
Write-Step "patched files: $($wrote.Count)"
if (Test-Path -LiteralPath $exe) {
    Write-Step "exe: $exe"
    Write-Step "D3D12\D3D12Core.dll beside it: $(if (Test-Path -LiteralPath $dllBeside) { 'yes' } else { 'no (build did not find the DLL)' })"
    $dumpbin = Get-Dumpbin
    if ($dumpbin) {
        $exports = & $dumpbin /exports $exe 2>&1 | Select-String 'D3D12SDK'
        if ($exports) {
            $exports | ForEach-Object { Write-Ok $_.Line.Trim() }
        } else {
            Write-Warn 'the executable has no D3D12SDK exports'
        }
    }
} else {
    Write-Step "build it: cargo build --release --locked -p victory"
}
Write-Host "Done."
