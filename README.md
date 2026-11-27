# victory-agility-patcher

A standalone PowerShell tool that patches a VIctory fork for **Windows 10**:
it exports the D3D12 Agility SDK entry points from the `victory` executable and
places `D3D12Core.dll` beside it, so the fork loads a shader-model-6.6 runtime
instead of Windows 10's in-box shader-model-6.5 one.

Windows 10's in-box D3D12 refuses the heap-indexed root signatures that every
translated pipeline uses (`Unsupported bit-flag set (root signature flags
c01)`); with these exports the runtime loads the Agility DLL from `D3D12\`
next to the executable instead. Windows 11 is unaffected: without the DLL the
exports are not added and the in-box runtime is used.

## Requirements

- Windows 10/11 x64 and PowerShell 5.1 or newer
- A VIctory fork with a Cargo workspace and a crate named `victory`
  (`apps/victory`, `crates/victory`, or the workspace root)
- The Rust toolchain and MSVC build tools, if you want the tool to build
- `D3D12Core.dll` from the **Microsoft.Direct3D.D3D12 1.620.x** NuGet package
  (the Agility SDK). It is not included here. Put it beside the script, in the
  repository, set `VICTORY_D3D12_CORE`, or pass `-D3D12Core`.

## Usage

```powershell
# Patch any fork; the crate named "victory" is found automatically.
.\Patch-VictoryAgility.ps1 D:\some\victory-fork

# Give the SDK DLL explicitly, and build in the same run.
.\Patch-VictoryAgility.ps1 D:\some\fork -D3D12Core C:\SDK\D3D12Core.dll -Build -Profile fast

# Just check an existing checkout (files, DLL, built exe exports).
.\Patch-VictoryAgility.ps1 D:\some\fork -Check

# Show what would be written.
.\Patch-VictoryAgility.ps1 D:\some\fork -DryRun
```

Options: `-SdkVersion` (derived from the DLL's version when it can be read),
`-Profile release|fast|diag` for `-Build` and the final check, `-Force` to
replace a foreign `build.rs` (backed up first) or refresh the patch, and
`-NoDllCopy`.

## What it changes

In the detected crate:

- `src/agility.rs` — exports `D3D12SDKVersion` and `D3D12SDKPath`, which
  D3D12 reads from the executable at device creation;
- `build.rs` — exports those symbols only when `D3D12Core.dll` is available,
  and copies it to `target\<profile>\D3D12\`;
- `src/main.rs` — inserts `mod agility;` after the crate documentation;
- the fork's root — `D3D12Core.dll`, for the build script.

Existing files are backed up (`*.agility-bak-<timestamp>`,
`build.rs.bak-<timestamp>`), and running the tool twice is safe: it reports
“already patched” and does not duplicate the module.

The patch is the same one used in the working 8 GB NVIDIA Scarlett forks
(`victory-agility-patch`). The build script and the exports are small; the
tool has no dependencies beyond PowerShell.

## Verify

```powershell
.\Patch-VictoryAgility.ps1 D:\some\fork -Check
```

For a built exe, the check looks for:

```
D3D12SDKPath = D3D12SDKPath
D3D12SDKVersion = D3D12SDKVersion
```

It also checks that `target\<profile>\D3D12\D3D12Core.dll` exists beside the
executable. `dumpbin` from the MSVC tools is used for the export check when it
can be found.

## License

GPL-3.0-or-later. The `build.rs`/`agility.rs` patch comes from the VIctory /
victory-scarlett forks, which are GPL-3.0-or-later.

This repository contains no game files, code, assets, keys or download links.
