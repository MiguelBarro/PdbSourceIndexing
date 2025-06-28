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
            [String]$ToolsPath
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

    $repos = New-Object -TypeName Repositories
    $excludes = New-Object -TypeName ExcludePaths

    # Script to process the files into entries
    $process = {

        $entry = @{}
        # keep the file as id
        $entry.id = $_

        # Check if the file should be excluded
        if($excludes.Exclude($_))
        {
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
                $excludes.Add($_)
                Write-Warning "File $_ couldn't be associated with any repository, skipping"
                return
            }
        }

        $entry.commit = $repo.commit
        $entry.repo = $repo.name
        $entry.repo_path = $repo.path

        # propagate
        $entry = [PSCustomObject]$entry
        Write-Output $entry
    }

    foreach ($pdbfile in $PDBs)
    {
        # Extract files and generate entries
        $entries = & $srctool -r $pdbfile | Select -SkipLast 1 | % $process

        # keep the relative path
        $groups = ($entries | ? repo -ne $null) | Group-Object -Property repo
        $groups | % {
            # calculate the relative path for all files
            pushd $_.Group[0].repo_path
            $_.Group | % {
                $rp = (Resolve-Path -Path $_.id -Relative).replace(".\","").replace("\","/")
                Add-Member -InputObject $_ -MemberType NoteProperty `
                           -Name relpath -Value $rp }
            popd
        }

        # Generate the stream
        $header = $PDBStreamHeader -f (Get-Date -Format "ddd, dd MMMM yyyy")
        $header = $header -split "`r?`n"

        $footer = 'SRCSRV: end ------------------------------------------------'

        # $tmp = New-TemporaryFile
        $tmp = Join-Path $Env:TMP (Get-Random)
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
    # - name
    # - commit
    # - path
    # - submodules array
    [PSCustomObject[]]$repos

    [PSCustomObject] GetRepo([string]$file)
    {
        return [Repositories]::GetRepo($file, $this.repos)
    }

    [bool] AddRepo([string]$file)
    {
        $new = [PSCustomObject]@{
            name = ""
            commit = ""
            path = ""
            submodules = @()
        }
        $res = [Repositories]::AddRepo($file, $new)
        if($res)
        {
            $this.repos += $new
        }
        return $res
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
        $repo = $col.Where({$file -match $_.path}, 'SkipUntil', 1)

        # Check if the $file belong to some submodule
        $subrepo = $Null
        if($repo.submodules)
        {
            $subrepo = [Repositories]::GetRepo($file, $repo.submodules)
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

        # get associated dir
        $dir = $file
        if(Test-Path $file -PathType Leaf)
        {
            $dir = ($file | Split-Path)
        }
        $dir.replace("\","/")

        # use git to find out the repo
        $new.commit = git -C $dir log -n1 --pretty=format:'%h' 2>$null
        if($new.commit -eq $null)
        {
            return $false
        }

        $branches = git -C $dir branch -r --contains $new.commit

        # get associated repos
        $candidates = $branches | sls '^\s*(?<remote>\w+)/' | select -ExpandProperty Matches |
            select -ExpandProperty Groups | ? name -eq 'remote' | sort | unique |
            select -ExpandProperty Value

        # filter out repo list
        $new.name = ((git -C $dir remote -v |
            sls "^(?<remote>\w+)\s+https://github.com/(?<repo>\S+).git").Matches |
            % { [PSCustomObject]@{ repo = [String]$_.Groups['repo']; remote = [String]$_.Groups['remote']}} |
            ? remote -in $candidates | Select -First 1).repo

        # get the path
        $new.path = git -C $dir rev-parse --show-toplevel

        # populate submodules
        $matches = (git -C $dir submodule | sls "^\s*\w+ (?<relpath>[\S]+)").Matches
        if($matches)
        {
            $new.submodules = $matches | % {
                    $subdir = "{0}/{1}" -f $new.path, $_.Groups['relpath']
                    $subnew = [PSCustomObject]@{
                        name = ""
                        commit = ""
                        path = ""
                        submodules = @()
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

    [bool] Exclude([string]$file) {
        # Change \ to / (avoid regex escaping issues)
        return [bool]$this.dirs.Count -and
               [bool]($file.replace("\","/") | sls -Pattern $this.dirs)
    }

    [void] Add([string]$file) {
       # Precondition: the file is not excluded
       # 1. Get the folder
       $dir = ($file | Split-Path).replace("\","/")
       # 2. Remove those entries that are subfolders of the new one
       if($this.dirs)
       {
           $this.dirs = ($this.dirs | sls -Pattern $dir -NotMatch).Line
       }
       # 3. Add the new one
       $this.dirs += @($dir.replace("(","\(").replace(")","\)"))
    }
}
