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

### Excluding files from being associated with github sources

To exclude those files from a private repository:

```powershell
PS> fixpdb -PDBs (gci /repos/my-project/build/Debug/*.pdb).FullName `
           -ExcludePaths /repos/my-private-project-A, /repos/my-private-project-B
```

This is convenient but the debugger often has its own devices. For example in
windbg and cdb:
```windbg
cdb> .srcpath C:\repos\my-private-project-A;C:\repos\my-private-project-B;SVR*
```
will disable source indexing for the private repos and use local sources instead.

### Manually mapping files to github sources

Manually map sources not currently available, for example static lib sources that are not
deployed on installation.

This may be helpful too on frameworks like vcpkg, that do not keep the sources
in git repos.

The mappings can be provided using hashtables:

```powershell
PS> $proto = @{
    Name = "protocolbuffers/protobuf"
    Path = "C:\Users\Stan\.vcpkg\buildtrees\protobuf\src\v5.29.3-74faffde26.clean"
    Commit = "v5.29.3"
    Submodules = @(@{
        Name = "protocolbuffers/protobuf"
        Path = "C:\Users\Stan\.vcpkg\buildtrees\utf8-range\src\v5.29.3-03b5e8031c.clean"
        Commit = "v5.29.3"
      })
  }
PS> $abseil = @{
    Name = "abseil/abseil-cpp"
    Path = "C:\Users\Stan\.vcpkg\buildtrees\abseil\src\20250127.1-a0a219bf72.clean"
    Commit = "20250127.1"
  }
PS> fixpdb -PDBs (gci /repos/my-project/build/Debug/*.pdb).FullName `
           -MappedRepos @($proto, $abseil)
```

Using json strings to define the array of its elements is also possible:

```powershell
PS> $json = @'
[
  {
    "Commit": "v5.29.3",
    "Path": "C:\\Users\\Stan\\.vcpkg\\buildtrees\\protobuf\\src\\v5.29.3-74faffde26.clean",
    "Name": "protocolbuffers/protobuf",
    "Submodules": [
      {
        "Commit": "v5.29.3",
        "Path": "C:\\Users\\Stan\\.vcpkg\\buildtrees\\utf8-range\\src\\v5.29.3-03b5e8031c.clean",
        "Name": "protocolbuffers/protobuf"
      }
    ]
  },
  {
    "Commit": "20250127.1",
    "Path": "C:\\Users\\Stan\\.vcpkg\\buildtrees\\abseil\\src\\20250127.1-a0a219bf72.clean",
    "Name": "abseil/abseil-cpp"
  }
]
'@
PS> fixpdb -PDBs (gci /repos/my-project/build/Debug/*.pdb).FullName -MappedRepos $json
```

## CMake integration

This module can be executed as a post-build step in CMake projects. For example:

```cmake
if(MSVC)
    # Manually hint the github repository URL for source indexing using a json
    set(USER_MAPPINGS [==[-MappedRepos ''[
          {
            "Commit": "v5.29.3",
            "Path": "C:\\Users\\Stan\\.vcpkg\\buildtrees\\protobuf\\src\\v5.29.3-74faffde26.clean",
            "Name": "protocolbuffers/protobuf",
            "Submodules": [
              {
                "Commit": "v5.29.3",
                "Path": "C:\\Users\\Stan\\.vcpkg\\buildtrees\\utf8-range\\src\\v5.29.3-03b5e8031c.clean",
                "Name": "protocolbuffers/protobuf"
              }
            ]
          },
          {
            "Commit": "20250127.1",
            "Path": "C:\\Users\\Stan\\.vcpkg\\buildtrees\\abseil\\src\\20250127.1-a0a219bf72.clean",
            "Name": "abseil/abseil-cpp"
          }
        ]'']==])

    # Exclude a private repository from source indexing (sources require authorization for retrieval)
    set(EXCLUDEPATHS [=[-ExcludePaths "C:\repos\my-project"]=])

    # Avoid escaping issues using base64 encoding
    set(SOURCE_INDEX_CMD
        "Install-Module -Name PdbSourceIndexing -Scope CurrentUser -Force;"
        "Import-Module -Name PdbSourceIndexing;"
        "Update-PdbSourceIndexing -PDBs $Env:TargetPDB ${USER_MAPPINGS} ${EXCLUDEPATHS}"
    )
    string(REPLACE "\n" "" SOURCE_INDEX_CMD "${SOURCE_INDEX_CMD}")
    execute_process(
        COMMAND powershell -NoProfile -Command
            "[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('${SOURCE_INDEX_CMD}'))"
        OUTPUT_VARIABLE SOURCE_INDEX_CMD
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )

    # add post build event
    add_custom_command(
        TARGET my-project POST_BUILD
        COMMENT "Adding source indexing to pdb symbols"
        COMMAND
        "$<IF:$<CONFIG:Debug,RelWithDebInfo>,${CMAKE_COMMAND},exit>"
        -E env
            TargetPDB="$<TARGET_PDB_FILE:my-project>"
            powershell
                -NoProfile
                -EncodedCommand ${SOURCE_INDEX_CMD}
    )
endif()
```

## Requirements and Platform Support

* Supports Windows PowerShell 5.1 (Desktop edition) **with .NET Framework 4.7.1** or later
* Supports PowerShell 7.2 or later ([Core edition](https://docs.microsoft.com/en-us/powershell/scripting/whats-new/differences-from-windows-powershell)) on all supported OS platforms.
* Requires `FullLanguage` [language mode](https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_language_modes)
