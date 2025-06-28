# PdbSourceIndexing

A [PowerShell](#requirements-and-platform-support) module to modify pdb files SRCSVR data stream to directly reference the sources in Github.

## Description

The module Simplifies debugging by downloading required sources from github.

This is convenient because only headers are often distributed with the binaries. With the modified PDB is possible to access all involved sources from the cloud.

The Cmdlet relies on Git to find out github repos and subrepos with the proper version.

For more information on how source indexing works check:
+ [Source indexing is underused awesomeness. Bruce Dawson 2011](https://randomascii.wordpress.com/2011/11/11/source-indexing-is-underused-awesomeness/)
+ [Use The Source, Luke. MSDN magazine August 2006](https://learn.microsoft.com/en-us/archive/msdn-magazine/2006/august/source-server-helps-you-kill-bugs-dead-in-visual-studio-2005)
+ Source Server docs: [here](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/srcsrv) and
  [here](https://learn.microsoft.com/en-us/windows/win32/debug/source-server-and-source-indexing).

Note that the debugger must be set up to use the source server:
+ [Visual Studio](https://learn.microsoft.com/en-us/visualstudio/debugger/specify-symbol-dot-pdb-and-source-files-in-the-visual-studio-debugger?view=vs-2022#other-symbol-options-for-debugging)
+ [WinDbg](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/using-a-source-server)

## Installation

The latest release can found in the [PowerShell Gallery](https://www.powershellgallery.com/packages/PdbSourceIndexing/) or the [GitHub releases page](https://github.com/MiguelBarro/PdbSourceIndexing/releases). Installing is easiest from the gallery using `Install-Module`.
See [Installing PowerShellGet](https://docs.microsoft.com/en-us/powershell/scripting/gallery/installing-psget) if you run into problems with it.

```powershell
# install for all users (requires elevation)
Install-Module -Name PdbSourceIndexing -Scope AllUsers

# install for current user
Install-Module -Name PdbSourceIndexing -Scope CurrentUser
```

## Quick Start

After build locate the `.pdb` files and call the `Update-PdbSourceIndexing` cmdlet.
Is possible to hint the pdb introspection tools path if they are in an unusual place.

```powershell
PS> Update-PdbSourceIndexing -PDBs (gci /repos/my-project/build/Debug/*.pdb) `
                             -ToolsPath "${Env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\srcsrv"
```

It's possible to use the pipeline to modify the `.pdb` files and let the Cmdlet to introspect the tools path.

```powershell
PS> gci /repos/my-project/build/Debug/*.pdb | Update-PdbSourceIndexing
```

There is too a cmdlet alias.

```powershell
PS> gci /repos/my-project/build/Debug/*.pdb | fixpdb
```

> [!NOTE]
> Modify the `.pdb` files before debugging. Otherwise the original `.pdb` files may be cached and
the modified ones would not be used by the debugger.

> [!NOTE]
> Source indexing only works with public github repositories. Private repositories require the
use of short live tokens on the *API REST calls* which makes it impractical to use.
Long term tokens cannot be used because `SRCSVR` does not support *http* headers customization.

## Requirements and Platform Support

* Supports Windows PowerShell 5.1 (Desktop edition) **with .NET Framework 4.7.1** or later
* Supports PowerShell 7.2 or later ([Core edition](https://docs.microsoft.com/en-us/powershell/scripting/whats-new/differences-from-windows-powershell)) on all supported OS platforms.
* Requires `FullLanguage` [language mode](https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_language_modes)
