<#
.Synopsis
Source index PDB files to allow debuggers reference sources on github.

.Description
Simplify debugging by downloaded required sources from github. This is convenient
because only headers are often distributed with the binaries. With the modified
PDB is possible to access all involved sources on the cloud.

The Cmdlet relies on Git to find out github repos and subrepos with the proper
version.

.Parameter PDBs
PDB File or collection of PDB files to be modified.

.Parameter ToolsPath
Directory where the Windows SDK tools (pdbstr, srctool) to update the PDB files
are located.
Optional, if not provided the Cmdlet will try to find the tools.

.Parameter ExcludePaths
Paths to exclude from source indexing.

.Parameter MappedRepos
Manually mapped repositories provided by the user. This is necessary if the sources
are not into a git repository and automatic introspection is not possible.
Is a collection which provides the mapping details. It can be either:
 • A json string or a collection of json strings
 • A collection of hashtables
Each item keys:
 • Name: github repo name. For example: protocolbuffers/protobuf
 • Path: local path to the repository (as kept into the pdb). For example: C:\repos\protobuf
 • Commit: commit hash or tag to use for the source indexing. For example: v5.29.3
 • Submodules: (Optional) Collection of hashtables with the same structure as above
   to map submodules. This is useful if the sources are into a submodule of the main repo.

.Inputs
PDB File or collection of PDB files to be modified.

.Outputs
None

.Example
Modify all PDB files in a directory to include source indexing.

PS> Update-PdbSourceIndexing -PDBs (gci /repos/my-project/build/Debug/*.pdb) `
                             -ToolsPath "${Env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\srcsrv"

.Example
Use a pipeline to modify PDB files and let the Cmdlet to introspect the tools path.

PS> gci /repos/my-project/build/Debug/*.pdb | Update-PdbSourceIndexing

.Example
Use the cmdlet alias to fix PDB files in a directory.

PS> gci /repos/my-project/build/Debug/*.pdb | fixpdb

.Example
Exclude those files from a private repository:

PS> fixpdb -PDBs (gci /repos/my-project/build/Debug/*.pdb).FullName `
           -ExcludePaths /repos/my-private-project-A, /repos/my-private-project-B

This is convenient but the debugger often has its own devices. For example in
windbg and cdb:
    cdb> .srcpath C:\repos\my-private-project-A;C:\repos\my-private-project-B;SVR*
will disable source indexing for the private repos and use local sources instead.

.Notes
Only .exes and .dlls have complete PDB files able to be source indexed.

Static libraries (.lib) can have PDB files associated if compiled with /Zi flag but those
are partial PDB files that cannot be source indexed.
The proper strategy, and the one followed by vcpkg, is to compile static libraries with
the /Z7 flag that will embed all debug info (sources included) into the .lib file.

Only when the static library is linked into an executable or a dynamic library a proper
PDB file is generated (with the static library info too) and source indexing can be
applied. Unfortunately, the static library repo would probably not be available locally
at this point.

Source indexing only works with public github repositories. Private repositories require the
use of short live tokens on the API REST call which makes it impractical to use.

Modify the .pdb files before debugging. Otherwise the original .pdb files may be cached and
the modified ones would not be used by the debugger.

.Example
Manually map sources not currently available, for example static lib sources that are not
deployed on installation.
This may be helpful too on frameworks like vcpkg, that do not keep the sources
in git repos.
The mappings can be provided using hashtables:

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

.Example
Manually map sources using a json string.

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

.Link

https://github.com/MiguelBarro/PdbSourceIndexing

#>

function Update-PdbSourceIndexing
{
    [Alias('fixpdb')]
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true,
            HelpMessage = 'Pdb files to update with source indexing',
            ValueFromPipeline=$true)]
            [ValidateScript({
                (Test-Path $_ -PathType Leaf) -and
                ((Get-Item $_).Extension -eq '.pdb')
                })]
            [String[]]$PDBs,
        [Parameter(
            HelpMessage = 'Path to the SRCSRV ancillary tools')]
            [ValidateScript({
                (Test-Path $_ -PathType Container) -and
                (Get-ChildItem -Path (Join-Path $_ *) -Include pdbstr.exe, srctool.exe)
                })]
            [String]$ToolsPath,
        [Parameter(
            HelpMessage = 'Paths to exclude from source indexing')]
            [ValidateScript({ Test-Path $_ -PathType Container })]
            [String[]]$ExcludePaths,
        [Parameter(
            HelpMessage = 'Manually mapped repos')]
            [ValidateScript({
                # Hashtable with 3 keys: Name, Path, Commit, Submodules (Optional)
                $hash_common = {
                    ($_.Name -match '^[\w-]+/[\w-]+$') -and [bool]$_.Commit -and
                    ($_.Path -match '^(\w:|[^<>:"/\\|?*\r\n]*)?(\\[^<>:"/\\|?*\r\n]*)+$')
                }
                $validate_hash = {
                    ($_ -is [Hashtable]) -and
                    (($_.Keys | ? { $_ -in 'Name', 'Path', 'Commit'}).Count -eq 3)
                }
                $validate_object = {
                    ($_ -is [PSCustomObject]) -and
                    (($_.psobject.Properties.Name | ? { $_ -in 'Name', 'Path', 'Commit'}).Count -eq 3)
                }
                $validate_all = {
                    (($_ | % $validate_hash ) -or ($_ | % $validate_object)) -and
                    ($_ | % $hash_common)
                }
                $validate = {
                    ($_ | % $validate_all) -and
                    (($_.Submodules | % $validate_all | ? { -not $_}).Count -eq 0)
                }

                if ($_ -is [String])
                {
                    # May contain several objects
                    $objs = $_ | ConvertFrom-Json
                }
                else
                {
                    # May be a hashtable or PSCustomObject
                    $objs = $_
                }

                $objs | % $validate
                })]
            [Object[]]$MappedRepos
    )

    $ErrorActionPreference = 'Stop'

    # Check if git is available
    if(-not (Get-Command git -ErrorAction SilentlyContinue))
    {
        # Terminating error
        throw New-Object System.InvalidProgramException `
                         "Git is not available, please install it to use this Cmdlet"
    }

    # Locate the pdb tools from the Windows Drivers SDK
    if($ToolsPath)
    {
        $pdbstr = ls -path $ToolsPath -Filter pdbstr.exe
        $srctool = ls -path $ToolsPath -Filter srctool.exe
    }
    else
    {
        # if not provided make some introspection
        $kitskey = Get-Item "HKLM:SOFTWARE/Microsoft/Windows Kits/Installed Roots"
        $kitspath = $kitskey.GetValue($kitskey.GetValueNames() -match "kitsRoot")
        $pdbstr = Resolve-Path "$kitspath*/x64/srcsrv/pdbstr.exe"
        $srctool = Resolve-Path "$kitspath/*/x64/srcsrv/srctool.exe"
    }

    if(!$pdbstr -or !$srctool)
    {
        # Terminating error
        throw New-Object System.InvalidProgramException `
                         "Cannot find the required tools: pdbstr.exe and srctool.exe"
    }

    $ErrorActionPreference = 'SilentlyContinue'

    # https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/new-object?view=powershell-7.5#example-6-calling-a-constructor-that-takes-an-array-as-a-single-parameter
    $repos = New-Object -TypeName Repositories -ArgumentList (,[Object[]]$MappedRepos)
    $excludes = New-Object -TypeName ExcludePaths

    $user_excludes = $null
    if($ExcludePaths)
    {
        $user_excludes = New-Object -TypeName ExcludePaths -ArgumentList (,[String[]]$ExcludePaths)
    }

    # Script to process the files into entries
    $process = {

        $entry = @{}
        # keep the file as id
        $entry.id = $_

        # Check if the file should be excluded

        # By user command
        if($user_excludes -and $user_excludes.Exclude($_))
        {
            Write-Debug "File $_ is excluded by user command, skipping"
            return
        }

        # By introspection
        if($excludes.Exclude($_))
        {
            # Do not use warning to avoid slowing down the process
            Write-Debug "File $_ couldn't be associated with any repository, skipping"
            return
        }

        # Check the commit
        $repo = $repos.GetRepo($_)

        # If there is no repo try to find one
        if(!$repo)
        {
            if($repos.AddRepo($_))
            {
                # retrieve the repo
                $repo = $repos.GetRepo($_)
            }
            else
            {
                # If there is no repo ignore and update exclude
                if($excludes.AddFile($_))
                {
                    $dir = Split-Path -Path $_ -Parent
                    Write-Warning "Dir $dir couldn't be associated with any repository, skipping"
                }
                return
            }
        }

        $entry.commit = $repo.Commit
        $entry.repo = $repo.Name
        $entry.repo_path = $repo.Path

        # propagate
        $entry = [PSCustomObject]$entry
        Write-Output $entry
    }

    foreach ($pdbfile in $PDBs)
    {
        # Extract files and generate entries
        $entries = & $srctool -r $pdbfile | Select -SkipLast 1 | % $process

        # keep the relative path
        $groups = ($entries | ? repo -ne $null) | Group-Object -Property repo_path
        $groups | % {
            # calculate the relative path for all files
            $repo_path = $_.Group[0].repo_path

            if (Get-Item $repo_path -ErrorAction SilentlyContinue)
            {   # The repo is available locally
                pushd $repo_path
                $_.Group | % {
                    $rp = (Resolve-Path -Path $_.id -Relative).replace(".\","").replace("\","/")
                    Add-Member -InputObject $_ -MemberType NoteProperty `
                               -Name relpath -Value $rp }
                popd
            }
            else
            {
                # Non local repos apply introspection
                $repo_path = $repo_path -replace "\\", "/"

                $_.Group | % {
                    $rp = $_.id -replace "\\", "/"
                    $rp = $rp -replace $repo_path, ''
                    $rp = $rp -replace "^/", ''
                    Add-Member -InputObject $_ -MemberType NoteProperty `
                               -Name relpath -Value $rp }
            }
        }

        # Generate the stream
        $header = $PDBStreamHeader -f (Get-Date -Format "ddd, dd MMMM yyyy")
        $header = $header -split "`r?`n"

        $footer = 'SRCSRV: end ------------------------------------------------'

        # $tmp = New-TemporaryFile
        $tmp = Join-Path $Env:TMP (Get-Random)
        Write-Debug "Creating temporary file $tmp for source indexing stream"
        $entries | % { $header } {"{0}*{1}*{2}*{3}" -f $_.id, $_.repo, $_.commit, $_.relpath } { $footer } | Out-File $tmp -Encoding OEM

        # incorporate the stream into the file
        & $pdbstr -w "-p:$pdbfile" -s:srcsrv "-i:$tmp"
    }
}

# Cmdlet ancillary

$PDBStreamHeader = @'
SRCSRV: ini ------------------------------------------------
VERSION=2
VERCTRL=PDB-Github
DATETIME={0}
SRCSRV: variables ------------------------------------------
SRCSRVTRG=https://raw.githubusercontent.com/%var2%/%var3%/%var4%
SRCSRV: source files ---------------------------------------
'@

# Auxiliary class to identify which repo a file belongs to
class Repositories
{
    # Each individual repo keys:
    # - Name
    # - Commit
    # - Path
    # - Submodules array
    [PSCustomObject[]]$repos

    Repositories()
    {
        $this.repos = @()
    }

    Repositories([Object[]]$MappedRepos)
    {
        # Delegate in a method that admits recursion (Constructors cannot)
        $this.Initialize($MappedRepos)
    }

    [PSCustomObject] GetRepo([string]$file)
    {
        return [Repositories]::GetRepo($file, $this.repos)
    }

    [bool] AddRepo([string]$file)
    {
        $new = [PSCustomObject]@{
            Name = ""
            Commit = ""
            Path = ""
            Submodules = @()
        }
        $res = [Repositories]::AddRepo($file, $new)

        # Use path as key in the collection (not Name that can be duplicated)
        if($res -and ($new.Path -notin $this.repos.Path))
        {
            $this.repos += $new
        }
        return $res
    }

    # Initialization purposes
    hidden [void] Initialize([Object[]]$MappedRepos)
    {
        # Initialize the collection of repositories
        $this.repos = @()

        foreach ($repo in $MappedRepos)
        {
            if($repo -is [HashTable] -or $repo -is [PSCustomObject])
            {
                Write-Debug "Adding repo from user provided mapping: $($repo.Path) - $($repo.Name) - $($repo.Commit)"
                $this.AddRepo([PSCustomObject]$repo)
            }
            elseif ($repo -is [String])
            {
                # Either the string was a single repo or a collection
                $repos_objs = $repo | ConvertFrom-Json

                if ($repos_objs -is [System.Collections.IEnumerable])
                {
                    # recurse
                    $this.Initialize($repos_objs)
                    return
                }
                else
                {   # now is a single object
                    $this.AddRepo($repos_objs)
                }
            }
        }

        if($MappedRepos)
        {
            Write-Debug "User provided repos: $($this.repos)"
        }
    }

    # Initialization purposes
    hidden [PSCustomObject] AddRepo([PSCustomObject]$Repo)
    {
        # Precondition: parameter validation

        # Recurse submodules
        $submodules = @()
        foreach($sub in $Repo.Submodules)
        {
            $sub = $this.AddRepo([PSCustomObject]$sub)
            if($sub)
            {
                $submodules += $sub
            }
        }

        # Check if already exists
        if($Repo.Path -in $this.repos.Path)
        {
            return $null
        }

        # Create the repo object
        $new = [PSCustomObject]$Repo
        # Normalize Path (git does this)
        $new.Path = $new.Path.replace("\", "/")
        # Add submodules object collection
        if($submodules)
        {
            $new.Submodules = $submodules
        }

        # Add the new repo to the collection
        $this.repos += $new
        return $new
    }

    # Recursive implementation methods

    static hidden [PSCustomObject] GetRepo([string]$file, [PSCustomObject[]]$col)
    {
        # ignore if empty
        if($col.Count -eq 0)
        {
            return $null
        }

        # Search for a repo whose path matches the file
        $file = $file.replace("\", "/")
        $repo = $col.Where({$file -match $_.Path}, 'SkipUntil', 1)

        # Check if the $file belong to some submodule
        $subrepo = $Null
        if($repo.Submodules)
        {
            $subrepo = [Repositories]::GetRepo($file, $repo.Submodules)
        }

        # return $subrepo ?? $repo
        if($subrepo)
        {
            return $subrepo
        }
        else
        {
            return $repo
        }
    }

    static hidden [bool] AddRepo([string]$file, [PSCustomObject]$new)
    {
        # Precondition the $file is not associated with a known repo

        # Check if the file exists
        $f = Get-Item -Path $file -ErrorAction SilentlyContinue
        if(!$f)
        {
            return $false
        }

        # get associated dir
        $dir = $f.Directory.FullName

        # use git to find out the repo
        $new.Commit = git -C $dir log -n1 --pretty=format:'%h' 2>$null
        if($new.Commit -eq $null)
        {
            return $false
        }

        $branches = git -C $dir branch -r --contains $new.Commit

        # get associated repos
        $candidates = $branches | sls '^\s*(?<remote>\w+)/' | select -ExpandProperty Matches |
            select -ExpandProperty Groups | ? name -eq 'remote' | sort | unique |
            select -ExpandProperty Value

        # filter out repo list
        $new.Name = ((git -C $dir remote -v |
            sls "^(?<remote>\w+)\s+https://github.com/(?<repo>\S+).git").Matches |
            % { [PSCustomObject]@{ repo = [String]$_.Groups['repo']; remote = [String]$_.Groups['remote']}} |
            ? remote -in $candidates | Select -First 1).repo

        # get the path
        $new.Path = git -C $dir rev-parse --show-toplevel

        # populate submodules
        $matches = (git -C $dir submodule | sls "^\s*\w+ (?<relpath>[\S]+)").Matches
        if($matches)
        {
            $new.Submodules = $matches | % {
                    $subdir = "{0}/{1}" -f $new.Path, $_.Groups['relpath']
                    $subnew = [PSCustomObject]@{
                        Name = ""
                        Commit = ""
                        Path = ""
                        Submodules = @()
                    }
                    if([Repositories]::AddRepo($subdir, $subnew))
                    {
                        $subnew
                    }
                }
        }

        return $true;
    }
}

# Auxiliary class to identify files to ignore
class ExcludePaths
{
    [string[]]$dirs

    ExcludePaths()
    {
        $this.dirs = @()
    }

    ExcludePaths([string[]]$dirs)
    {
        # Initialize the dirs
        # Precondition: dirs must be available otherwise it does not
        # make sense to exclude them
        foreach ($dir in $dirs)
        {
           # Turn into absolute path
           $dir = Resolve-Path -Path $dir -ErrorAction SilentlyContinue
           if ($dir)
           {
              # Adding one by one to remove subfolders
              $this.AddDir($dir)
           }
        }
    }

    [bool] Exclude([string]$file)
    {
        return [ExcludePaths]::Exclude($file, $this.dirs)
    }

    [bool] AddDir([string]$dir)
    {
       # 1. Normalize path
       $dir = $dir.replace("\","/")
       # 2. Check if there already
       if($this.dirs -contains $dir)
       {
           return $false
       }
       # 3. Remove those entries that are subfolders of the new one
       if($this.dirs)
       {
           $this.dirs = ($this.dirs | sls -Pattern $dir -NotMatch).Line
       }
       # 4. Add the new one
       $this.dirs += @($dir.replace("(","\(").replace(")","\)"))

       return $true
    }

    [bool] AddFile([string]$file)
    {
       # Precondition: the file is not excluded
       $dir = Split-Path -Path $file -Parent
       return $this.AddDir($dir)
    }

    static [bool] Exclude([string]$file, [string[]]$dirs)
    {
        # Change \ to / (avoid regex escaping issues)
        return [bool]$dirs.Count -and
               [bool]($file.replace("\","/") | sls -Pattern $dirs)
    }
}
