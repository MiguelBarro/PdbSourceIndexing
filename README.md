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
    Path = "C:\vcpkg\buildtrees\protobuf\src\v5.29.3-74faffde26.clean"
    Commit = "v5.29.3"
    Submodules = @(@{
        Name = "protocolbuffers/protobuf"
        Path = "C:\vcpkg\buildtrees\utf8-range\src\v5.29.3-03b5e8031c.clean"
        Commit = "v5.29.3"
      }, @{
        Name = "abseil/abseil-cpp"
        Path = "D:\a\PdbSourceIndexing\PdbSourceIndexing\install\x64-windows-static-msvc\include"
        Commit = "20250127.1"
      })
  }
PS> $abseil = @{
    Name = "abseil/abseil-cpp"
    Path = "C:\vcpkg\buildtrees\abseil\src\20250127.1-a0a219bf72.clean"
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
    "Path": "C:\\vcpkg\\buildtrees\\protobuf\\src\\v5.29.3-006fb5062c.clean",
    "Name": "protocolbuffers/protobuf",
    "Submodules": [
      {
        "Commit": "v5.29.3",
        "Path": "C:\\vcpkg\\buildtrees\\utf8-range\\src\\v5.29.3-03b5e8031c.clean",
        "Name": "protocolbuffers/protobuf"
      },
      {
        "Commit": "20250127.1",
        "Path": "D:\\a\\PdbSourceIndexing\\PdbSourceIndexing\\install\\x64-windows-static-msvc\\include",
        "Name": "abseil/abseil-cpp"
      }
    ]
  },
  {
    "Commit": "20250127.1",
    "Path": "C:\\vcpkg\\buildtrees\\abseil\\src\\20250127.1-a0a219bf72.clean",
    "Name": "abseil/abseil-cpp"
  }
]
'@
PS> fixpdb -PDBs (gci /repos/my-project/build/Debug/*.pdb).FullName -MappedRepos $json
```

## CMake integration

This module can be executed as a post-build step in CMake projects. If the sources are associated to github repos then
a plain call to `Update-PDBSourceIndexing` would suffice to modify the `.pdb` files:

```cmake
if(MSVC)
    # Exclude a private repository from source indexing (sources require authorization for retrieval)
    # Exclude framework install dirs where headers are locally available
    set(EXCLUDEPATHS "-ExcludePaths \"${PROJECT_SOURCE_DIR}\", \"${CMAKE_BINARY_DIR}\", \"$ENV{ProgramFiles}\"")

    # Avoid escaping issues using base64 encoding
    set(SOURCE_INDEX_CMD
        "Install-Module -Name PdbSourceIndexing -Scope CurrentUser -Force;"
        "Import-Module -Name PdbSourceIndexing;"
        "Update-PdbSourceIndexing -PDBs $<TARGET_PDB_FILE:my-project> ${EXCLUDEPATHS}"
    )

    # add post build event
    add_custom_command(
        TARGET my-project POST_BUILD
        COMMENT "Adding source indexing to pdb symbols"
        COMMAND
        "$<IF:$<CONFIG:Debug,RelWithDebInfo>, powershell, exit>" -NoProfile -Command ${SOURCE_INDEX_CMD}
    )
endif()
```

### Unconventional use cases

As mentioned above there are use cases were the git repos associated to the sources are not available:
+ Frameworks like [vcpkg](https://learn.microsoft.com/en-us/vcpkg/) do not clone the git repositories to deploy the
  sources.
+ Static Libraries (`.lib`) cannot be *source index* on generation because they do not have a `.pdb` file
  associated to them.
  A `.pdb` file can be generated with `cl.exe /Zi` option but is a partial one that do not provide source info.
  `vcpkg` for example compiles the static libraries with `/Z7` option which does not generate a `.pdb` but embeds into
  the `.lib` file the debug info (source info included).
  When the static lib is linked to an executable or a dynamic library, the linker generates a `.pdb` file taking into
  account that embedded debug info, though often the original sources are no longer available.

### A static library example

Using C binary libraries (`.dll` or `.lib`) is a breeze but using C++ ones is a
[headache](https://devblogs.microsoft.com/oldnewthing/20150911-00/?p=91611).
That's why OS APIs were often writen in C (like [Win32](https://learn.microsoft.com/en-us/windows/win32/)
and led to the creation of specific frameworks like
[COM](https://learn.microsoft.com/en-us/windows/win32/com/the-component-object-model) or
[WinRT](https://learn.microsoft.com/en-us/windows/uwp/cpp-and-winrt-apis/)
on windows to safely interoperate C++ components.

Plain C++ libraries are rarely distributed[^1] but build together with the application in order to prevent compiler and STL
compatibility issues. Using the same compiler and STL version is not guarantee enough, the compiler flags must be
compatible. Here [CMake](https://cmake.org/) simplifies things by providing a comprehensive description of each library
(targets) and propagating the compiler flags to the application.
This strategy implies large build times which are often attenuated using caching mechanisms (either local or cloud).

[^1]: [Conan](https://conan.io/center/recipes/protobuf) makes binaries available but only for limited compiler/language
      versions and release mode.

As an example I have created a github actions [workflow](./.github/workflows/depends.yml) that builds the dependencies
associated to a project that requires `protobuf` and `kafka` libraries. `protobuf` relies on `abseil-cpp` which is
tricky to configure so `vcpkg` is used to solve `CMake` configuration issues.
I customize the `vcpkg` *triplet* to use `msbuild` generator instead of `ninja` and target a specific compiler version[^2]:
```cmake
    set(WINDOWS_USE_MSBUILD ON)
    set(CMAKE_GENERATOR_TOOLSET "v143,host=x64")
```

[^2]: Visual C++ unifies all compiler, linker, STL and runtime versioning under a toolset version
      (e.g. `v143` for Visual Studio 2022, `v142` for Visual Studio 2019, etc.).

The workflow generates an
[artifact](https://github.com/MiguelBarro/PdbSourceIndexing/actions/runs/16053397307/artifacts/3459394681) 
ready for deploy that contains under the folder `x64-windows-static-msvc`: static libraries in Debug/Release mode,
headers and CMake/pkgconfig config files.

It can be installed by extracting the artifact and running the following powershell commands:
```powershell
mv <extraction path>\Windows-14.44.35207-10.0.26100.0\x64-windows-static-msvc $Env:ProgramFiles
Rename-Item -NewName vcpkg-static -Path "$Env:ProgramFiles\x64-windows-static-msvc\"
# Allow CMake to find the packages using symbolic links
"protobuf;absl;rdkafka;utf8_range" -split ";" |
    Join-Path -Path $env:ProgramFiles -ChildPath {$_} | 
    New-Item -ItemType SymbolicLink -Path {$_} -Target $Env:ProgramFiles/vcpkg-static
```

In order to source index the `.pdb` files generated by the project that uses these libraries, a
json file providing the mapping between the source files and the repositories is required.
`Update-PDBSourceIndexing` provides warnings about those directories it cannot associate
to a repository where the user must fill the gap.
Repository versions used are provided by `vcpkg` in the *workflow logs*.

```cmake
if(MSVC AND NOT CMAKE_GENERATOR_TOOLSET)
    # Match dependencies provided by workflow via vcpkg
    set(CMAKE_GENERATOR_TOOLSET "v143,host=x64")
endif()

...

find_package(protobuf CONFIG REQUIRED)
find_package(RdKafka CONFIG REQUIRED)

...

if(MSVC)
    # Manually hint the github repository URL for source indexing using a json
    set(USER_MAPPINGS [==[-MappedRepos ''[
          {
            "Commit": "v5.29.3",
            "Path": "C:\\vcpkg\\buildtrees\\protobuf\\src\\v5.29.3-006fb5062c.clean",
            "Name": "protocolbuffers/protobuf",
            "Submodules": [
              {
                "Commit": "v5.29.3",
                "Path": "C:\\vcpkg\\buildtrees\\utf8-range\\src\\v5.29.3-03b5e8031c.clean",
                "Name": "protocolbuffers/protobuf"
              },
              {
                "Commit": "20250127.1",
                "Path": "D:\\a\\PdbSourceIndexing\\PdbSourceIndexing\\install\\x64-windows-static-msvc\\include",
                "Name": "abseil/abseil-cpp"
              }
            ]
          },
          {
            "Commit": "20250127.1",
            "Path": "C:\\vcpkg\\buildtrees\\abseil\\src\\20250127.1-a0a219bf72.clean",
            "Name": "abseil/abseil-cpp"
          }
        ]'']==])

    # Exclude a private repository from source indexing (sources require authorization for retrieval)
    # Exclude framework install dirs where headers are locally available
    set(EXCLUDEPATHS "-ExcludePaths \"${PROJECT_SOURCE_DIR}\", \"${CMAKE_BINARY_DIR}\", \"$ENV{ProgramFiles}\"")

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
