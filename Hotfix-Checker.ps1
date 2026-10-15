#requires -Version 5.1
<#
.SYNOPSIS
Hotfix Checker: static SQL*Plus reference auditing and hotfix file naming.
.DESCRIPTION
No arguments starts the hotfix/master selection workflow. Supplied hotfixes and
masters are paired by array position; relative master/working paths use the hotfix
root. Reports and this utility must be outside every supplied hotfix.
The installer my $hotfix assignment is synchronized with the hotfix folder name.
The five supported Perl/undeploy script filenames in sql are also synchronized.
The documentation DOCX filename is synchronized, and zero-byte files are reported.
Exit codes: 0 completed/no findings; 1 completed/findings; 2 incomplete or failed.
#>
[CmdletBinding()]
param(
    [string[]]$HotfixPath,
    [string[]]$MasterPath,
    [string[]]$WorkingDirectory,
    [switch]$IncludeNested,
    [switch]$DetailedReport,
    [string]$ReportDirectory = '',
    [string]$InputCsv,
    [ValidateSet('Auto', 'UTF8', 'Default', 'Windows1252', 'Unicode', 'BigEndianUnicode')]
    [string]$ScriptEncoding = 'Auto',
    [ValidateRange(1, 1024)][int]$MaxScriptSizeMB = 64,
    [switch]$NonInteractive,
    [switch]$NoPause,
    [switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:ExcludedExtensions = @('.ear', '.java', '.war', '.bc', '.zip',
    '.docx', '.wft', '.perl', '.pl', '.txt', '.cmd', '.sh', '.bat', '.undeploy', '.properties', '.jar', '.deploy', '.bundle')
$script:ZeroByteIgnoredExtensions = @('.pl', '.perl', '.undeploy', '.txt')
# These master-call targets may be absent from the hotfix. Keep this list separate
# from coverage exclusions: if a listed file is supplied, it is still checked.
# Match whole filenames ignoring case, after the default .sql suffix is applied.
$script:AllowedMissingCallTargets = @(
    'dbdefine_verify_HF.sql'
    'dbdefine.sql'
    'OWKF_OWF_MONITOR.ps'
    'OWKF_OWF_MONITOR.pb'
    'CMiC_Connect_OWF_Administrator.SQL'
    'dbk_patch_flag.ps'
    'dbk_patch_flag.pb'
    'ptfcompx'
    'get_con_idx_trg_status.sql'
    'sys_multitenant_view.ps'
    'sys_multitenant_view.pb'
    'create_z_audit_columns.sql'
    'uig_grants_to_da.sql'
    'da_synonyms_for_uig_obj.sql'
    'sys_create_api.ps'
    'sys_create_api.pb'
    'sysopt.vw'
    'sys_opt.ps'
    'sec.vwt'
    'sys#opt.vw'
    'sys_opt.pb'
    'omopt.vw'
    'om#opt.vw'
    'recreate_altered_vwt.sql'
    'sysinfo.ps'
    'sysinfo.pb'
    'add_jasper_om_reports.sql'
    'add_jasper_pm_reports.sql'
    'cmic_fk_idx_synchronize.sql'
    'da_grants_to_cmic_bi_runtime.sql'
    'da_grants_to_cmic_user_defined_views.sql'
    'da_grants_to_uig.sql'
    'ptfcompx.sql'
    'CF_DA_Grants_To_UIG.grnt'
    'CF_UIG_Grants_To_CF.grnt'
    'CF_DA_Grants_To_CF.grnt'
    'CF_DA_Grants_To_DAR.grnt'
    'CF_UIG_synonyms_for_DA_obj.syn'
    'CF_synonyms_for_DA_obj.syn'
    'CF_synonyms_for_UIG_obj.syn'
    'CF_synonyms_for_CF_obj.syn'
    'CF_Grants_To_UIG.grnt'
    'CF_Grants_To_DA.grnt'
    'CF_Grants_To_DAR.grnt'
    'CF_DA_synonyms_for_CF_obj.syn'
    'CF_UIG_synonyms_for_CF_obj.syn'
    'CF_DAR_synonyms_for_CF_obj.syn'
    'Da_grants_to_jsr.sql'
    'Da_grants_to_jsd.sql'
    'Da_grants_to_owkf.sql'
    'OWKF_Grants_To_DA.sql'
    'CMIC_WF_Grants_To_All.grnt'
    'DA_Grants_To_CMIC_WF.sql'
    'OWKF_Grants_To_CMIC_WF.sql'
    'CMIC_WF_Required_Grants_From_Others.grnt'
    'deftbsp.sql'
    'jss_grants_to_da.sql'
    'dar_grants_to_uig.sql'
    'uig_synonyms_for_da_obj.sql'
    'sys_uig_db_info_ps.plb'
    'dar_synonyms_for_uig_obj.sql'
    'uig_grants_to_dar.sql'
    'uigstdtarget.dat'
    'uigstdtargetforms.dat'
    'uigstdmenuv10x.dat'
    'uigstdmenusaas.dat'
    'uigstdmenuprofessional.dat'
    'uigstdmenuxprojects.dat'
    'uigstdmenucrm.dat'
    'uigstdmenu1000.dat'
    'uigstdmenuforms.dat'
    'uigstdmenu_rp.dat'
    'uigstdmenuv12.dat'
    'uigstdmenunexus.dat'
    'uigfeaturetestmenu.dat'
    'uigconsole.dat'
    'uigconsoleprofessional.dat'
    'uigconsolesaas.dat'
    'uigconsolexprojects.dat'
    'uigconsolenexus.dat'
    'da_grants_to_cmic_report_views.sql'
    'cmic_report_views.dat'
    'CMIC_REPORT_VIEWS_grants_to_CMIC_REPORT_WRITER.sql'
    'CMIC_REPORT_VIEWS_grants_to_CMIC_BI_RUNTIME.sql'
    'DA_Grants_To_CMIC_BI.sql'
    'custinst.sql'
    'dar_custinst.sql'
    'uig_custinst.sql'
    'jsr_custinst.sql'
    'install_custom_prd.sql'
    'bi_cmic_default.dsd'
    'cmic_compile_detail.sql'
    'invalidobjects.sql'
)
$script:AllowedMissingCallNames = [Collections.Hashtable]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($allowedTarget in $script:AllowedMissingCallTargets) {
    $name = if ([IO.Path]::GetExtension($allowedTarget)) { $allowedTarget } else { $allowedTarget + '.sql' }
    $script:AllowedMissingCallNames[$name] = $true
}
$script:ReportAudits = @()
$script:FreeTextCommandPattern = '^\s*(?i:REM(?:A(?:R(?:K)?)?)?|PRO(?:M(?:P(?:T)?)?)?|PAU(?:S(?:E)?)?|SPO(?:O(?:L)?)?|DEF(?:I(?:N(?:E)?)?)?|UNDEF\w*|ACC(?:E(?:P(?:T)?)?)?|COL(?:U(?:M(?:N)?)?)?|TTI\w*|BTI\w*)(?:\s|$)'

function New-PathMap { return [Collections.Hashtable]::new([StringComparer]::OrdinalIgnoreCase) }
function Test-SamePath([string]$Left, [string]$Right) { return [string]::Equals($Left, $Right, [StringComparison]::OrdinalIgnoreCase) }

function ConvertTo-SafeText([string]$Text, [switch]$Multiline) {
    $pattern = if ($Multiline) { '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F\p{Cf}\u2028\u2029]' } else { '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]' }
    return [regex]::Replace($Text, $pattern, { param($m) '\u{0:X4}' -f [int]$m.Value[0] })
}
function Write-Console([string]$Message) { Write-Host (ConvertTo-SafeText $Message -Multiline) }

function Get-SectionBanner([string]$Title) {
    $text = ConvertTo-SafeText $Title
    $width = [Math]::Max(83, $text.Length + 5)
    $border = '*' * $width
    return (@($border, ('*  ' + $text.PadRight($width - 4) + '*'), $border) -join [Environment]::NewLine)
}

function Update-AuditProgress($Audit, [string]$Message, [switch]$Force) {
    if ($Audit -and $Audit.ShowProgress) {
        Write-Verbose (ConvertTo-SafeText $Message)
        if ($Force -or $Audit.ProgressWatch.Elapsed.TotalSeconds -ge 2) {
            Write-Console ('  ' + (ConvertTo-SafeText $Message))
            $Audit.ProgressWatch.Restart()
        }
    }
}

function Get-PhysicalPath([string]$Path) {
    if (-not ('HotfixChecker.NativePaths' -as [type])) {
        Add-Type -TypeDefinition @'
using System; using System.Text; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
namespace HotfixChecker {
    public static class NativePaths {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint mode, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint size, uint flags);
        public static string Resolve(string path) {
            using (var handle = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
                if (handle.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                var result = new StringBuilder(32768);
                uint size = GetFinalPathNameByHandle(handle, result, (uint)result.Capacity, 2);
                if (size == 0 || size >= result.Capacity) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                return result.ToString();
            }
        }
    }
}
'@
    }
    $cursor = $Path; $suffix = ''
    while (-not (Test-Path -LiteralPath $cursor)) {
        $suffix = '\' + [IO.Path]::GetFileName($cursor) + $suffix
        $cursor = [IO.Path]::GetDirectoryName($cursor.TrimEnd('\'))
        if (-not $cursor) { throw "Cannot determine the filesystem location: $Path" }
    }
    return [HotfixChecker.NativePaths]::Resolve($cursor).TrimEnd('\') + $suffix
}

function Test-LocationInRoot([string]$Path, [string]$Root) {
    return ((Test-InRoot $Path $Root) -or ((Test-Path -LiteralPath $Root -PathType Container) -and
        (Test-InRoot (Get-PhysicalPath $Path) (Get-PhysicalPath $Root))))
}

function Assert-ReportLocation([string]$Path) {
    foreach ($audit in $script:ReportAudits) {
        if ($audit.NormalizedRoot -and (Test-LocationInRoot $Path $audit.Root)) { throw "ReportDirectory must be outside ALL scanned hotfixes: $($audit.Root)" }
    }
    Assert-NoPathLinks $Path
}

function Write-ReportText([string]$Path, [string[]]$Lines) {
    Assert-ReportLocation $Path
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $writer = $null
    try {
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($true))
        foreach ($line in $Lines) { $writer.WriteLine((ConvertTo-SafeText $line -Multiline)) }
    } finally { if ($writer) { $writer.Dispose() } else { $stream.Dispose() } }
}

function Read-ScriptBytes([string]$Path) {
    Assert-NoPathLinks $Path
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -gt $MaxScriptSizeMB * 1MB) { throw "Script exceeds the $MaxScriptSizeMB MB read limit; use -MaxScriptSizeMB to increase it." }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if (-not $read) { throw 'Script changed or ended unexpectedly while reading.' }
            $offset += $read
        }
        return ,$bytes
    } finally { $stream.Dispose() }
}

function Get-HotfixName([string]$Root) {
    # Get-Item.Name can echo the caller's casing on Windows. The filesystem
    # handle resolves the stored name, including callers using an 8.3 alias.
    $path = if (Test-Path -LiteralPath $Root -PathType Container) { Get-PhysicalPath $Root } else { $Root }
    $name = ($path.TrimEnd('\', '/') -split '[\\/]')[-1]
    if (-not $name) { return 'InvalidHotfix' }
    return $name
}

function Get-ReportTimestamp([datetime]$UtcNow = [datetime]::UtcNow) {
    $zone = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
    $localTime = [TimeZoneInfo]::ConvertTimeFromUtc($UtcNow, $zone)
    return $localTime.ToString('yyyyMMdd_hhmmtt', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-ReportName([string]$Name) {
    $safe = [regex]::Replace($Name, '[\\/:*?"<>|\p{Cc}\p{Cf}]', '_').TrimEnd(' ', '.')
    if (-not $safe) { return 'InvalidHotfix' }
    return $safe
}

function New-ReportFolder([string]$ReportRoot, [string]$Timestamp, [string]$Name) {
    $stem = $Timestamp + '_' + (Get-ReportName $Name)
    for ($number = 1; ; $number++) {
        $suffix = if ($number -eq 1) { '' } else { '_' + $number }
        $path = Join-Path $ReportRoot ($stem + $suffix)
        Assert-ReportLocation $path
        if (Test-Path -LiteralPath $path) { continue }
        try { [void](New-Item -ItemType Directory -Path $path -ErrorAction Stop) }
        catch {
            # Another run may have claimed this minute's name after Test-Path.
            if (Test-Path -LiteralPath $path -PathType Container) { continue }
            throw
        }
        Assert-ReportLocation $path
        return $path
    }
}

function Get-InstallerHotfixAssignment([string]$Text) {
    $pattern = '(?:\A|(?<=\n)|(?<=\r)(?!\n))[ \t]*my[ \t]+\$hotfix[ \t]*=[ \t]*(?<quote>["''])(?<value>(?:\\[^\r\n]|(?!\k<quote>)[^\\\r\n])*)\k<quote>[ \t]*;'
    $candidates = @([regex]::Matches($Text, $pattern))
    $active = New-Object System.Collections.ArrayList
    if ($candidates.Count) {
        $last = $candidates[-1].Index
        $byLine = @{}; foreach ($candidate in $candidates) { $byLine[$candidate.Index] = $candidate }
        $quoteOperator = [regex]'\G(?:(?:q[qxwr]?|m|s|tr|y)(?:\s|[^\w\s]|$)|format(?:\s|=|$))'
        # A complete one-line import of literal symbol names cannot hide an
        # assignment or open a multiline string. Do not skip arbitrary use lines.
        $literalImport = [regex]'\A[ \t]*use[ \t]+[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*[ \t]+qw[ \t]*\([A-Za-z0-9_: \t]*\)[ \t]*;[ \t]*(?:#.*)?\z'
        $quote = ''; $pod = $false; $offset = 0; $lineNumber = 1
        # This is a conservative edit guard, not a Perl interpreter. Inspect
        # context only through the last potential assignment, never execute it.
        while ($offset -le $last) {
            $end = $Text.IndexOfAny([char[]]"`r`n", $offset)
            if ($end -lt 0) { $end = $Text.Length }
            $line = $Text.Substring($offset, $end - $offset)
            if ($pod) { if ($line -cmatch '^=cut(?:\s|$)') { $pod = $false } }
            elseif (-not $quote -and $line -cmatch '^=[A-Za-z]') { $pod = $true }
            elseif (-not $quote -and $line -cmatch '^\s*__(?:DATA|END)__(?:\s|$)') { break }
            elseif (-not $quote -and $literalImport.IsMatch($line)) {
                # e.g. use Fcntl qw(:DEFAULT :flock); -- text only, never loaded.
            }
            else {
                if (-not $quote -and $byLine.ContainsKey($offset)) { [void]$active.Add($byLine[$offset]) }
                if ($offset -eq $last) { break }
                for ($i = 0; $i -lt $line.Length; $i++) {
                    $c = [string]$line[$i]
                    if ($quote) {
                        if ($c -eq '\') { $i++ }
                        elseif ($c -eq $quote) { $quote = '' }
                        continue
                    }
                    if ($c -eq '#') { break }
                    if ($c -eq '"' -or $c -eq "'" -or $c -eq '`') { $quote = $c; continue }
                    # Perl's regex/quote operators, heredocs and format bodies
                    # need a full parser. Refuse candidates beyond them rather
                    # than treating embedded example text as executable code.
                    if ($c -eq '/' -or ($c -eq '<' -and $i + 1 -lt $line.Length -and $line[$i + 1] -eq '<') -or
                        (($i -eq 0 -or $line[$i - 1] -notmatch '[\w$]') -and
                        $quoteOperator.Match($line, $i).Success)) {
                        throw ('Cannot safely identify the hotfix assignment after complex Perl syntax (regex, quote operator, heredoc or format) at line ' + $lineNumber + ', column ' + ($i + 1) + '. Update it manually.')
                    }
                }
            }
            $offset = $end
            if ($offset -lt $Text.Length -and $Text[$offset] -eq "`r") { $offset++ }
            if ($offset -lt $Text.Length -and $Text[$offset] -eq "`n") { $offset++ }
            $lineNumber++
            if ($end -eq $Text.Length) { break }
        }
    }
    if ($active.Count -ne 1) { throw ('Expected exactly one active literal my $hotfix assignment; found ' + $active.Count + '.') }
    return $active[0]
}

function Complete-InstallerReplacement([string]$Temporary, [string]$Destination, [string]$Backup) {
    [IO.File]::Replace($Temporary, $Destination, $Backup)
}

function Update-HotfixInstaller($Audit) {
    $path = Join-Path $Audit.Root 'v12hotfixinstall\v12hotfixinstall.pl'
    $temporary = ''; $backup = ''; $replaceStarted = $false; $replaceSucceeded = $false
    try {
        Assert-NoPathLinks $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $Audit.InstallerStatus = 'Missing'; return }
        $bytes = Read-ScriptBytes $path
        $codePage = 65001; $offset = 0
        foreach ($bom in @(@('FF-FE-00-00', 12000, 4), @('00-00-FE-FF', 12001, 4),
            @('EF-BB-BF', 65001, 3), @('FF-FE', 1200, 2), @('FE-FF', 1201, 2))) {
            if ($bytes.Length -ge $bom[2] -and [BitConverter]::ToString($bytes, 0, $bom[2]) -eq $bom[0]) {
                $codePage = $bom[1]; $offset = $bom[2]; break
            }
        }
        $encoding = [Text.Encoding]::GetEncoding($codePage, [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback)
        try { $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset) }
        catch [Text.DecoderFallbackException] {
            if ($offset) { throw }
            $encoding = [Text.Encoding]::GetEncoding(1252, [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback)
            $text = $encoding.GetString($bytes)
        }
        if ($text.IndexOf([char]0) -ge 0) { throw 'Binary/NUL content is not a supported installer text file.' }
        $assignment = Get-InstallerHotfixAssignment $text
        $value = $assignment.Groups['value']; $quote = $assignment.Groups['quote'].Value
        $name = (Get-HotfixName $Audit.Root).Replace('\', '\\').Replace($quote, ('\' + $quote))
        if ($quote -eq '"') { $name = $name.Replace('$', '\$').Replace('@', '\@') }
        if ([string]::Equals($value.Value, $name, [StringComparison]::Ordinal)) { $Audit.InstallerStatus = 'AlreadyMatches'; return }
        $updated = $text.Substring(0, $value.Index) + $name + $text.Substring($value.Index + $value.Length)
        [byte[]]$prefix = if ($offset) { $bytes[0..($offset - 1)] } else { @() }
        [byte[]]$replacement = $prefix + $encoding.GetBytes($updated)
        Assert-NoPathLinks $path
        $item = Get-Item -LiteralPath $path -Force
        $linkType = $item.PSObject.Properties['LinkType']
        if ($null -ne $linkType -and $linkType.Value -eq 'HardLink') { throw 'Installer has multiple hardlinks; refusing to modify another file through an alias.' }
        # Prepare and flush a complete sibling first. Replacement never truncates
        # the live installer and does not fall back to an in-place write.
        $temporary = Join-Path ([IO.Path]::GetDirectoryName($path)) ('.hotfix-checker-' + [guid]::NewGuid().ToString('N') + '.tmp')
        $backup = [IO.Path]::ChangeExtension($temporary, '.bak')
        $stream = $null; $staging = $null; $created = $false
        try {
            Assert-NoPathLinks $temporary
            $staging = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $created = $true
            $staging.Write($replacement, 0, $replacement.Length)
            $staging.Flush($true)
            $staging.Dispose(); $staging = $null
            Assert-NoPathLinks $path
            # Deny other writers while checking the snapshot; delete sharing is
            # required by Windows to replace the file through this open handle.
            $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Delete)
            if ($stream.Length -ne $bytes.Length) { throw 'Installer changed while preparing the update.' }
            $hasher = [Security.Cryptography.SHA256]::Create()
            try {
                $originalHash = [BitConverter]::ToString($hasher.ComputeHash($bytes))
                $currentHash = [BitConverter]::ToString($hasher.ComputeHash($stream))
                if ($originalHash -ne $currentHash) { throw 'Installer changed while preparing the update.' }
            } finally { $hasher.Dispose() }
            Assert-NoPathLinks $temporary
            Assert-NoPathLinks $backup
            if (Test-Path -LiteralPath $backup) { throw 'Recovery backup destination already exists.' }
            $replaceStarted = $true
            Complete-InstallerReplacement $temporary $path $backup
            $created = $false; $replaceSucceeded = $true
        } finally {
            if ($stream) { $stream.Dispose() }
            if ($staging) { $staging.Dispose() }
            if ($created -and -not $replaceStarted) {
                Assert-NoPathLinks $temporary
                [IO.File]::Delete($temporary)
            }
        }
        # ReplaceFile can fail after moving the original. Never delete either
        # recovery file on that path. A successful replacement permits cleanup.
        Assert-NoPathLinks $backup
        [IO.File]::Delete($backup)
        $Audit.InstallerStatus = 'Updated'
        $Audit.InstallerNote = 'Installer updated: v12hotfixinstall\v12hotfixinstall.pl now uses hotfix "' + (Get-HotfixName $Audit.Root) + '".'
    } catch {
        $Audit.InstallerStatus = 'Failed'
        $Audit.InstallerNote = 'Installer update failed: ' + $_.Exception.Message
        if ($replaceStarted -and -not $replaceSucceeded) {
            $Audit.InstallerNote += ' Recovery files were preserved if created. Original backup: ' + $backup + '; prepared replacement: ' + $temporary + '. Review them before retrying.'
        } elseif ($replaceSucceeded) { $Audit.InstallerNote += ' The installer was replaced; recovery backup cleanup failed: ' + $backup }
        Add-Issue $Audit $Audit.InstallerNote $path
    }
}

function Rename-HotfixScripts($Audit) {
    $sqlRoot = Join-Path $Audit.Root 'sql'
    try {
        Assert-NoPathLinks $sqlRoot
        if (-not (Test-Path -LiteralPath $sqlRoot -PathType Container)) { return }
        $files = @(Get-ChildItem -LiteralPath $sqlRoot -File -Force -ErrorAction Stop)
        $hotfixName = Get-HotfixName $Audit.Root
        foreach ($suffix in @('aftercopy.perl', 'beforecopy.perl', 'beforedeploy.perl', 'last.perl', 'undeploy')) {
            try {
                $pattern = '^V12-[^.]+\.' + [regex]::Escape($suffix) + '$'
                $candidates = @($files | Where-Object { $_.Name -imatch $pattern })
                if (-not $candidates.Count) { continue }
                $destinationName = $hotfixName + '.' + $suffix
                if ($candidates.Count -gt 1) {
                    throw ('Multiple matching files would map to ' + $destinationName + ': ' + (($candidates | ForEach-Object { $_.Name }) -join ', '))
                }
                $file = $candidates[0]
                if ([string]::Equals($file.Name, $destinationName, [StringComparison]::Ordinal)) { continue }
                $destination = Get-NormalPath $destinationName $sqlRoot
                if (-not (Test-SamePath ([IO.Path]::GetDirectoryName($file.FullName)) $sqlRoot) -or
                    -not (Test-SamePath ([IO.Path]::GetDirectoryName($destination)) $sqlRoot)) { throw 'Rename must stay directly inside the hotfix sql folder.' }
                Assert-NoPathLinks $file.FullName
                Assert-NoPathLinks $destination
                # Windows treats case-only destinations as the same file.
                if ((Test-Path -LiteralPath $destination) -and -not (Test-SamePath $file.FullName $destination)) {
                    throw ('Destination already exists: ' + $destinationName)
                }
                Rename-Item -LiteralPath $file.FullName -NewName $destinationName -ErrorAction Stop
                [void]$Audit.ScriptRenameNotes.Add('Script renamed: sql\' + $file.Name + ' -> sql\' + $destinationName)
            } catch {
                $message = 'Script rename failed (' + $suffix + '): ' + $_.Exception.Message
                [void]$Audit.ScriptRenameNotes.Add($message)
                Add-Issue $Audit $message $sqlRoot
            }
        }
    } catch {
        $message = 'Script renaming failed: ' + $_.Exception.Message
        [void]$Audit.ScriptRenameNotes.Add($message)
        Add-Issue $Audit $message $sqlRoot
    }
}

function Rename-HotfixDocumentation($Audit) {
    $folder = Join-Path $Audit.Root 'documentation'
    try {
        Assert-NoPathLinks $folder
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { return }
        $documents = @(Get-ChildItem -LiteralPath $folder -File -Force -ErrorAction Stop |
            Where-Object { $_.Extension -ieq '.docx' -and -not $_.Name.StartsWith('~$', [StringComparison]::Ordinal) -and
                -not [string]::Equals($_.Name, 'Hotfix Installation Instructions for V12C.docx', [StringComparison]::OrdinalIgnoreCase) })
        if (-not $documents.Count) { return }
        if ($documents.Count -gt 1) { throw ('Multiple DOCX files found; cannot choose which to rename: ' + (($documents | ForEach-Object { $_.Name }) -join ', ')) }
        $file = $documents[0]
        $destinationName = (Get-HotfixName $Audit.Root) + '.docx'
        if ([string]::Equals($file.Name, $destinationName, [StringComparison]::Ordinal)) { return }
        $destination = Get-NormalPath $destinationName $folder
        if (-not (Test-SamePath ([IO.Path]::GetDirectoryName($file.FullName)) $folder) -or
            -not (Test-SamePath ([IO.Path]::GetDirectoryName($destination)) $folder)) { throw 'Rename must stay directly inside the hotfix documentation folder.' }
        Assert-NoPathLinks $file.FullName
        Assert-NoPathLinks $destination
        if ((Test-Path -LiteralPath $destination) -and -not (Test-SamePath $file.FullName $destination)) { throw ('Destination already exists: ' + $destinationName) }
        Rename-Item -LiteralPath $file.FullName -NewName $destinationName -ErrorAction Stop
        $Audit.DocumentationNote = 'Documentation renamed: documentation\' + $file.Name + ' -> documentation\' + $destinationName
    } catch {
        $Audit.DocumentationNote = 'Documentation rename failed: ' + $_.Exception.Message
        Add-Issue $Audit $Audit.DocumentationNote $folder
    }
}

function Get-NormalPath([string]$Path, [string]$Base = (Get-Location).ProviderPath) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'An empty path is not valid.' }
    $p = $Path.Trim().Trim('"').Replace('/', '\')
    if ($p -match '^\\\\[?.]\\|^\\\?\?\\|[\x00-\x1F]') { throw 'Device namespaces and control characters are not supported in paths.' }
    if ($p -match '^[A-Za-z]:[^\\]' -or $p -match '^[A-Za-z]:$') {
        throw "Drive-relative paths are not supported: $p. Use a full path."
    }
    if (-not [IO.Path]::IsPathRooted($p)) { $p = [IO.Path]::Combine($Base, $p) }
    $p = [IO.Path]::GetFullPath($p)
    # .NET Framework can turn NUL.sql and similar DOS names into device paths.
    if ($p -match '^\\\\[?.]\\|^\\\?\?\\') { throw 'Reserved Windows device names and namespaces are not supported in paths.' }
    $root = [IO.Path]::GetPathRoot($p)
    if (($p -replace '^[A-Za-z]:', '') -match ':') { throw 'Alternate data streams are not supported in paths.' }
    foreach ($part in ($p.Substring($root.Length) -split '\\')) {
        if ($part.TrimEnd(' ', '.') -match '^(?i:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|CLOCK\$|COM[1-9\u00B9\u00B2\u00B3]|LPT[1-9\u00B9\u00B2\u00B3])(?:\.|$)') { throw 'Reserved Windows device names are not supported in paths.' }
    }
    if ($p.Length -gt $root.Length) { $p = $p.TrimEnd('\') }
    return $p
}

function Test-InRoot([string]$Path, [string]$Root) {
    return ($Path.Equals($Root, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase))
}

function Get-RelativePath([string]$Path, [string]$Root) {
    if ($Path.Equals($Root, [StringComparison]::OrdinalIgnoreCase)) { return '.' }
    return $Path.Substring($Root.TrimEnd('\').Length + 1)
}

function Test-PathLink($Item) {
    # LinkType/Target are lazy provider properties and can query remote servers.
    # Ordinary files, including hardlinks, cannot redirect directory traversal.
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { return $false }
    # OneDrive cloud placeholders also have ReparsePoint; they are not junctions.
    $link = $Item.PSObject.Properties['LinkType']
    $target = $Item.PSObject.Properties['Target']
    if ($null -ne $link -and $link.Value -eq 'HardLink') { return $false }
    return (($null -ne $link -and -not [string]::IsNullOrEmpty([string]$link.Value)) -or
        ($null -ne $target -and @($target.Value | Where-Object { $_ }).Count -gt 0))
}

function Assert-NoPathLinks([string]$Path) {
    $cursor = $Path
    $volumeRoot = [IO.Path]::GetPathRoot($Path).TrimEnd('\')
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (Test-PathLink $item) { throw "Symbolic link or junction in path: $cursor" }
        }
        if ($cursor.TrimEnd('\') -ieq $volumeRoot) { break }
        $parent = [IO.Path]::GetDirectoryName($cursor.TrimEnd('\'))
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Add-Issue($Audit, [string]$Message, [string]$Source = '', [int]$Line = 0, [string]$Text = '') {
    [void]$Audit.Issues.Add([pscustomobject]@{
        SourceFile = $Source; LineNumber = $Line; Message = $Message; SourceText = $Text
    })
}

function Get-Inventory($Audit) {
    $complete = $true
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Audit.Root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        Update-AuditProgress $Audit ('Scanning folder: ' + $directory + ' (' + $Audit.Files.Count + ' files found)')
        # Keep partial results if a directory emits a read error.
        $readErrors = @()
        $items = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue -ErrorVariable readErrors)
        foreach ($e in $readErrors) { $complete = $false; Add-Issue $Audit "Directory read error: $e" $directory }
        foreach ($item in $items) {
            if ($Audit.Files.Count % 250 -eq 0) { Update-AuditProgress $Audit ('Indexing hotfix files: ' + $Audit.Files.Count + ' found') }
            $isLink = Test-PathLink $item
            if ($item.PSIsContainer) {
                if ($isLink) { $complete = $false; Add-Issue $Audit 'Directory link skipped; inventory is incomplete.' $item.FullName }
                else { $pending.Push($item.FullName) }
            } else {
                $length = $null
                if (-not $isLink) {
                    try { $length = $item.Length }
                    catch { $complete = $false; Add-Issue $Audit ('File size could not be read: ' + $_.Exception.Message) $item.FullName }
                }
                $file = [pscustomobject]@{
                    FullPath = $item.FullName; RelativePath = (Get-RelativePath $item.FullName $Audit.Root)
                    Name = $item.Name; Extension = $item.Extension.ToLowerInvariant()
                    Excluded = ($script:ExcludedExtensions -contains $item.Extension)
                    IsLink = $isLink; Length = $length
                }
                [void]$Audit.Files.Add($file)
                $Audit.ByPath[$file.FullPath] = $file
                if (-not $Audit.ByName.ContainsKey($file.Name)) {
                    $Audit.ByName[$file.Name] = New-Object System.Collections.ArrayList
                }
                [void]$Audit.ByName[$file.Name].Add($file)
                if ($isLink) { $complete = $false; Add-Issue $Audit 'File link inventoried but not followed or matched.' $item.FullName }
            }
        }
    }
    $Audit.InventoryComplete = $complete
}

function Get-CodeLine([string]$Line, $State) {
    # A small lexer: comments only outside quotes, doubled quote escapes, and
    # Oracle q'[...]' (including multiline literals). Keep path quotes intact.
    $startedInLiteral = ($State.Quote -ne '' -or $State.AlternateEnd -ne '')
    # Most ordinary SQL/call lines need no character-by-character lexing.
    # Stateful literals and any quote/comment markers still use the full lexer.
    if (-not $State.Block -and -not $startedInLiteral -and $Line -notmatch '[''"]|--|/\*') {
        $text = if ($Line -match $script:FreeTextCommandPattern) { '' } else { $Line }
        return [pscustomobject]@{ Text = $text; StartedInLiteral = $false }
    }
    $out = New-Object Text.StringBuilder
    $hasToken = $startedInLiteral
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        $next = if ($i + 1 -lt $Line.Length) { [string]$Line[$i + 1] } else { '' }
        if ($State.Block) {
            if ($c -eq '*' -and $next -eq '/') { $State.Block = $false; $i++; [void]$out.Append('  ') }
            else { [void]$out.Append(' ') }
            continue
        }
        if ($State.AlternateEnd -ne '') {
            [void]$out.Append($c)
            if ([string]$c -eq $State.AlternateEnd -and $next -eq "'") {
                [void]$out.Append($next); $i++; $State.AlternateEnd = ''
            }
            continue
        }
        if ($State.Quote -ne '') {
            [void]$out.Append($c)
            if ([string]$c -eq $State.Quote) {
                if ($next -eq $State.Quote) { [void]$out.Append($next); $i++ }
                else { $State.Quote = '' }
            }
            continue
        }
        if ($c -eq '-' -and $next -eq '-') { break }
        if ($c -eq '/' -and $next -eq '*') { $State.Block = $true; $State.BlockLine = [int]$State['Line']; [void]$out.Append('  '); $i++; continue }
        if (-not $hasToken -and -not [char]::IsWhiteSpace($c)) {
            $rest = $Line.Substring($i)
            # These SQL*Plus commands contain free text, not SQL string literals.
            if ($rest -match $script:FreeTextCommandPattern) {
                return [pscustomobject]@{ Text = ''; StartedInLiteral = $startedInLiteral }
            }
            # SQL*Plus control-command arguments are not multiline SQL literals.
            # Keep SET text for settings analysis without letting prompt/password
            # punctuation consume subsequent START lines.
            if ($rest -match '^(?i:SET)\s+(?i:SQLP(?:R(?:O(?:M(?:P(?:T)?)?)?)?)?|PAU(?:S(?:E)?)?)(?:\s|$)|^(?i:CONN(?:E(?:C(?:T)?)?)?)\s+(?![Bb][Yy](?:\s|$))|^(?i:SHO(?:W)?|WHENEVER|CL(?:E(?:A(?:R)?)?)?|PRI(?:N(?:T)?)?|PASSW(?:O(?:R(?:D)?)?)?|HELP)(?:\s|$)') {
                return [pscustomobject]@{ Text = $out.ToString() + $rest; StartedInLiteral = $startedInLiteral }
            }
            $hasToken = $true
        }
        if (($c -eq 'q' -or $c -eq 'Q') -and $next -eq "'" -and $i + 2 -lt $Line.Length) {
            $delimiter = [string]$Line[$i + 2]
            $pairs = @{ '[' = ']'; '(' = ')'; '{' = '}'; '<' = '>' }
            $State.AlternateEnd = if ($pairs.ContainsKey($delimiter)) { $pairs[$delimiter] } else { $delimiter }
            $State.AlternateLine = [int]$State['Line']
            [void]$out.Append($Line.Substring($i, 3)); $i += 2; continue
        }
        if ($c -eq "'" -or $c -eq '"') { $State.Quote = [string]$c; $State.QuoteLine = [int]$State['Line'] }
        [void]$out.Append($c)
    }
    return [pscustomobject]@{ Text = $out.ToString(); StartedInLiteral = $startedInLiteral }
}

function Read-Target([string]$Operand) {
    $s = $Operand.Trim()
    if (-not $s) { return @{ Target = ''; Arguments = ''; Error = 'Call has no target.' } }
    $target = New-Object Text.StringBuilder
    $i = 0
    if ($s[0] -eq '"' -or $s[0] -eq "'") {
        $quote = $s[0]; $i = 1; $closed = $false
        while ($i -lt $s.Length) {
            if ($s[$i] -eq $quote) {
                if ($i + 1 -lt $s.Length -and $s[$i + 1] -eq $quote) {
                    [void]$target.Append($quote); $i += 2; continue
                }
                $i++; $closed = $true; break
            }
            [void]$target.Append($s[$i]); $i++
        }
        if (-not $closed) { return @{ Target = $target.ToString(); Arguments = ''; Error = 'Unclosed quoted target.' } }
        if ($i -lt $s.Length -and -not [char]::IsWhiteSpace($s[$i]) -and $s[$i] -ne ';') {
            return @{ Target = $target.ToString(); Arguments = $s.Substring($i); Error = 'Constructed target after a quoted path.' }
        }
    } else {
        while ($i -lt $s.Length -and -not [char]::IsWhiteSpace($s[$i])) {
            [void]$target.Append($s[$i]); $i++
        }
    }
    # Default SQLTERMINATOR: remove one trailing semicolon, without damaging a
    # semicolon inside a quoted filename. Non-default terminators are manual review.
    $t = $target.ToString()
    if ($s[0] -ne '"' -and $s[0] -ne "'" -and $t.EndsWith(';')) { $t = $t.Substring(0, $t.Length - 1) }
    $argsText = $s.Substring($i).Trim()
    if ($argsText -eq ';') { $argsText = '' }
    if ($argsText -match '^(?:\|\||\+)') {
        return @{ Target = $t; Arguments = $argsText; Error = 'Possible concatenated filename expression; manual review required.' }
    }
    return @{ Target = $t; Arguments = $argsText; Error = '' }
}

function Read-Script([string]$Path, $Audit = $null) {
    $calls = New-Object System.Collections.ArrayList
    $issues = New-Object System.Collections.ArrayList
    $suffixUnknown = $false; $syntaxUnknown = $false; $readSucceeded = $false; $errorLine = 0
    $state = @{ Block = $false; Quote = ''; AlternateEnd = ''; Line = 0; BlockLine = 0; QuoteLine = 0; AlternateLine = 0 }
    try {
        Update-AuditProgress $Audit ('Reading script: ' + $Path)
        # Decode the complete byte array: .NET Framework StreamReader can drop
        # an incomplete UTF-8 sequence at EOF without flushing its decoder.
        $bytes = Read-ScriptBytes $Path
        $codePage = @{ Auto = 65001; UTF8 = 65001; Default = [Text.Encoding]::Default.CodePage; Windows1252 = 1252; Unicode = 1200; BigEndianUnicode = 1201 }[$ScriptEncoding]
        $offset = 0
        foreach ($bom in @(@('FF-FE-00-00', 12000, 4), @('00-00-FE-FF', 12001, 4),
            @('EF-BB-BF', 65001, 3), @('FF-FE', 1200, 2), @('FE-FF', 1201, 2))) {
            if ($bytes.Length -ge $bom[2] -and [BitConverter]::ToString($bytes, 0, $bom[2]) -eq $bom[0]) {
                $codePage = $bom[1]; $offset = $bom[2]; break
            }
        }
        $encoding = [Text.Encoding]::GetEncoding($codePage, [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback)
        try { $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset) }
        catch {
            $decodeError = $_.Exception.GetBaseException()
            if ($decodeError -isnot [Text.DecoderFallbackException]) { throw }
            if ($offset -eq 0 -and $ScriptEncoding -eq 'Auto') {
                $encoding = [Text.Encoding]::GetEncoding(1252, [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback)
                $text = $encoding.GetString($bytes, 0, $bytes.Length)
                if ($Audit) { [void]$Audit.EncodingFallbacks.Add([pscustomobject]@{ SourceFile = $Path; Encoding = 'Windows1252' }) }
                Update-AuditProgress $Audit ('Reading as Windows1252 after invalid UTF-8: ' + $Path) -Force
            } else {
                $message = 'Encoding error (' + $encoding.WebName + '): ' + $decodeError.Message
                if ($offset -eq 0 -and $codePage -eq 65001) {
                    $message += ' If this is a legacy Windows ANSI script, rerun Hotfix-Checker.bat -ScriptEncoding Default; use -ScriptEncoding Windows1252 for a known Western Windows-1252 file. No encoding was guessed and no source was changed.'
                } else { $message += ' Check the file encoding; a Unicode BOM overrides -ScriptEncoding.' }
                throw $message
            }
        }
        if ($text.IndexOf([char]0) -ge 0) { throw 'Binary/NUL content is not a supported SQL*Plus text script.' }
        $lines = [regex]::Split($text, '\r\n|\n|\r')
        $readSucceeded = $true
        for ($n = 0; $n -lt $lines.Length; $n++) {
            if ($n % 256 -eq 0) { Update-AuditProgress $Audit ('Parsing ' + [IO.Path]::GetFileName($Path) + ': line ' + ($n + 1) + ' of ' + $lines.Length) }
            $state.Line = $n + 1
            $code = Get-CodeLine $lines[$n] $state
            if ($code.StartedInLiteral) { continue }
            $line = $code.Text.Trim()
            if (-not $line) { continue }
            $command = ''; $operand = ''
            # Extend invocation detection here; operands are parsed separately.
            if ($line -match '^(@@|@)\s*(.*)$') { $command = $Matches[1]; $operand = $Matches[2] }
            elseif ($line -match '^(?i:START)\s+(?i:WITH)(?:\s|$)') {
                $command = 'UNSUPPORTED'; $operand = $line
            }
            elseif ($line -match '^(?i:STA(?:R(?:T)?)?)(?:\s+(.*)|$)') { $command = 'START'; $operand = $Matches[1] }
            elseif ($line -match '^(?i:HO(?:S(?:T)?)?)(?:\s|$)|^!') {
                $command = 'HOST'; $operand = $line
            }
            elseif ($line -match '^(?i:SET)\s+(?i:SUF(?:F(?:I(?:X)?)?)?)(?:\s|$)') {
                $suffixUnknown = $true
                [void]$issues.Add([pscustomobject]@{ SourceFile = $Path; LineNumber = $n + 1;
                    Message = 'SET SUFFIX is not modeled; extensionless targets require manual review.'; SourceText = $lines[$n] })
            }
            elseif ($line -match '^(?i:SET)\s+(?i:DEF(?:I(?:N(?:E)?)?)?)\s+(?i:ON|OFF)\s*;?\s*$') {
                # Standard toggles do not construct a filename or choose a custom
                # substitution character. Variable-bearing targets remain manual
                # review, and a prior custom setting stays conservative.
                $state.Quote = ''; $state.AlternateEnd = ''
            }
            elseif ($line -match '^(?i:SET)\s+(?i:DEF(?:I(?:N(?:E)?)?)?|CON(?:C(?:A(?:T)?)?)?|ESC(?:A(?:P(?:E)?)?)?|SQLT\w*|CMDS\w*)(?:\s|$)') {
                $syntaxUnknown = $true
                [void]$issues.Add([pscustomobject]@{ SourceFile = $Path; LineNumber = $n + 1;
                    Message = 'Parser/substitution setting is not modeled; supported calls require manual review.'; SourceText = $lines[$n] })
            }
            elseif ($line -match '^(?i:EXECUTE)\s+(?i:IMMEDIATE)(?:\s|$)') {
                # PL/SQL dynamic SQL can contain a multiline literal. It is not
                # a SQL*Plus EXECUTE command; preserve its lexer state.
            }
            elseif ($line -match '^(?i:GET|RUN|R|EXEC(?:U(?:T(?:E)?)?)?|SQLPLUS)(?:\s|$)|^(?i:CALL|:R)\s|^#!|^(?i:@echo|param\s*\(|function\s|Import-Module\s|Write-Host\s)') {
                $command = 'UNSUPPORTED'; $operand = $line
            }
            if ($command) {
                $parts = if ($command -eq 'HOST' -or $command -eq 'UNSUPPORTED') {
                    @{ Target = ''; Arguments = $operand; Error = 'Unsupported invocation form; manual review required.' }
                } else { Read-Target $operand }
                if ($operand -match '(?:^|\s)-\s*$') { $parts.Error = 'Command continuation is not modeled; review this call and the next line.' }
                [void]$calls.Add([pscustomobject]@{ SourceFile = $Path; LineNumber = $n + 1;
                    SourceText = $lines[$n]; Command = $command; Target = $parts.Target;
                    Arguments = $parts.Arguments; ParseError = $parts.Error })
                # A malformed command's unmatched quote must not hide later calls.
                $state.Quote = ''; $state.AlternateEnd = ''
            }
        }
        if ($state.Block -or $state.Quote -ne '' -or $state.AlternateEnd -ne '') {
            $kind = if ($state.Block) { 'block comment' } else { 'SQL literal' }
            $errorLine = if ($state.Block) { $state.BlockLine } elseif ($state.AlternateEnd -ne '') { $state.AlternateLine } else { $state.QuoteLine }
            throw ('Unterminated ' + $kind + ' opened at line ' + $errorLine + '; analysis may be incomplete. Source: ' + $lines[$errorLine - 1])
        }
    } catch {
        [void]$issues.Add([pscustomobject]@{ SourceFile = $Path; LineNumber = $errorLine;
            Message = "Script read/parse error: $($_.Exception.Message)"; SourceText = '' })
    }
    return [pscustomobject]@{ Calls = @($calls); Issues = @($issues);
        SuffixUnknown = $suffixUnknown; SyntaxUnknown = $syntaxUnknown; ReadSucceeded = $readSucceeded }
}

function Resolve-Call($Call, $Audit, [string]$Chain, [bool]$Direct) {
    $r = [pscustomobject]@{
        HotfixRoot = $Audit.Root; SelectedMaster = $Audit.Master; SourceFile = $Call.SourceFile
        LineNumber = $Call.LineNumber; SourceText = $Call.SourceText; Command = $Call.Command
        Target = $Call.Target; Arguments = $Call.Arguments; Direct = $Direct
        Status = 'Unresolved'; MatchingMethod = ''; ResolvedPath = ''; Candidates = ''
        CallChain = $Chain; Notes = ''; Cycle = $false
    }
    if ($Call.Command -eq 'HOST' -or $Call.Command -eq 'UNSUPPORTED') {
        $r.Status = 'Unsupported'; $r.Notes = $Call.ParseError; return $r
    }
    if ($Call.ParseError) { $r.Notes = $Call.ParseError; return $r }
    if ($Call.Target -match '^[A-Za-z][A-Za-z0-9+.-]*://') {
        $r.Status = 'OutsideHotfix'; $r.Notes = 'External URL; not fetched or checked.'; return $r
    }
    $target = $Call.Target.Replace('/', '\')
    if (-not $target -or $target -match '[&%$`*?]|\|\||["<>]' -or $target -match '^[A-Za-z]:[^\\]|^[A-Za-z]:$') {
        $r.Notes = 'Empty, dynamic, variable-bearing, invalid, or drive-relative target; not evaluated.'; return $r
    }
    if ($Audit.SyntaxUnknown) { $r.Notes = 'Reachable script changes parser/substitution settings; assumptions cannot safely resolve calls.'; return $r }
    try {
        if ([IO.Path]::GetExtension($target) -eq '') {
            if ($Audit.SuffixUnknown) { $r.Notes = 'Extensionless target with a reachable SET SUFFIX; default extension is unknown.'; return $r }
            $target += '.sql'; $r.Notes = 'Default .sql extension assumed. '
        }
        $base = if ($Call.Command -eq '@@') { [IO.Path]::GetDirectoryName($Call.SourceFile) } else { $Audit.WorkingDirectory }
        $path = Get-NormalPath $target $base
        $explicitPath = ($target -match '[\\/:]')
        if (-not (Test-InRoot $path $Audit.Root)) {
            if ($explicitPath) {
                $r.Status = 'OutsideHotfix'; $r.ResolvedPath = $path
                $r.Notes += 'Outside scanned hotfix; existence elsewhere is not checked.'; return $r
            }
            # A bare filename still permits an explicitly labeled inventory match.
        } elseif ($Audit.ByPath.ContainsKey($path)) {
            $r.ResolvedPath = $path
            $r.MatchingMethod = if ([IO.Path]::IsPathRooted($target)) { 'AbsolutePath' }
                elseif ($Call.Command -eq '@@') { 'CallerRelativePath' } else { 'WorkingDirectoryPath' }
            $r.Status = 'Resolved'
        }
        if ($r.Status -ne 'Resolved') {
            if (-not $explicitPath -and $Audit.ByName.ContainsKey($target)) {
                $candidates = @($Audit.ByName[$target])
                if ($candidates.Count -eq 1) {
                    $r.Status = 'Resolved'; $r.ResolvedPath = $candidates[0].FullPath
                    $r.MatchingMethod = 'UniqueFilename'
                    $r.Notes += 'Inventory filename match only; runtime SQL*Plus lookup is not established.'
                } else {
                    $r.Status = 'Ambiguous'; $r.Candidates = ($candidates.FullPath -join ' | ')
                    $r.Notes += 'Multiple filenames and no matching path context; none counted as called.'
                }
            } else {
                $r.Status = 'MissingInHotfix'; $r.ResolvedPath = $path
                $r.Notes += 'Not found in scanned inventory; explicit paths never use basename fallback.'
            }
        }
        if ($r.Status -eq 'Resolved') {
            $file = $Audit.ByPath[$r.ResolvedPath]
            $r.ResolvedPath = $file.FullPath
            if ($file.IsLink) { $r.Status = 'Unresolved'; $r.Notes += ' File link not followed.' }
            elseif ($file.Excluded) { $r.Notes += ' Target excluded from eligible-file coverage by extension.' }
        }
    } catch { $r.Status = 'Unresolved'; $r.Notes += " Invalid/unsupported path: $($_.Exception.Message)" }
    return $r
}

function Visit-Script($Audit, [string]$Path, [string[]]$Stack, [string]$Chain) {
    if ($Audit.Visited.ContainsKey($Path)) { return }
    if ($Stack.Count -ge 128) { Add-Issue $Audit 'Nested depth limit (128) reached; analysis incomplete.' $Path; return }
    $Audit.Visited[$Path] = $true
    if (-not $Audit.Cache.ContainsKey($Path)) { $Audit.Cache[$Path] = Read-Script $Path $Audit }
    $parsed = $Audit.Cache[$Path]
    foreach ($issue in $parsed.Issues) { [void]$Audit.Issues.Add($issue) }
    if ($parsed.SuffixUnknown -and -not $Audit.SuffixUnknown) {
        $Audit.SuffixUnknown = $true; $Audit.ModelChanged = $true
        foreach ($issue in $parsed.Issues) { [void]$Audit.ModelIssues.Add($issue) }
    }
    if ($parsed.SyntaxUnknown -and -not $Audit.SyntaxUnknown) {
        $Audit.SyntaxUnknown = $true; $Audit.ModelChanged = $true
        foreach ($issue in $parsed.Issues) { [void]$Audit.ModelIssues.Add($issue) }
    }
    $stackNow = @($Stack) + @($Path)
    foreach ($call in $parsed.Calls) {
        $edgeChain = $Chain + ':' + $call.LineNumber + ' -> ' + $call.Target
        $primary = Resolve-Call $call $Audit $edgeChain (Test-SamePath $Path $Audit.Master)
        # Only literal master calls with a normalized filesystem target qualify.
        # Dynamic/malformed targets and unsupported invocations still need review.
        if ($primary.Direct -and $primary.Status -in @('MissingInHotfix', 'OutsideHotfix') -and
            $primary.ResolvedPath -and $script:AllowedMissingCallNames.ContainsKey([IO.Path]::GetFileName($primary.ResolvedPath))) {
            $primary.Status = 'IgnoredMissing'
            $primary.Notes += ' Missing from hotfix is allowed by AllowedMissingCallTargets.'
        }
        $references = @($primary)
        # Direct coverage asks whether the filename is called by the master.
        # Bare START/@ names cover every exact basename in the hotfix. Explicit
        # paths and @@ keep path resolution; nested reads use only the primary.
        if ($primary.Direct -and $call.Command -ne '@@' -and $call.Target -notmatch '[\\/:]' -and
            $primary.Status -in @('Resolved', 'Ambiguous')) {
            $name = $call.Target
            if (-not [IO.Path]::GetExtension($name)) { $name += '.sql' }
            $copies = @($Audit.ByName[$name])
            if ($copies.Count -gt 1) {
                $references = foreach ($copy in $copies) {
                    $match = $primary.PSObject.Copy()
                    $match.ResolvedPath = $copy.FullPath
                    $match.Status = if ($copy.IsLink) { 'Unresolved' } else { 'Resolved' }
                    $match.MatchingMethod = 'FilenamePresence'
                    $match.Candidates = $copies.FullPath -join ' | '
                    $match.Notes = 'Exact filename called in the master; multiple hotfix copies match. This does not establish which copy SQL*Plus executes.'
                    $match
                }
                if ($Audit.Nested -and $primary.Status -ne 'Resolved') {
                    Add-Issue $Audit 'Multiple filename copies match; the nested script path is ambiguous and was not read.' $Path $call.LineNumber $call.SourceText
                }
            }
        }
        foreach ($reference in $references) {
            [void]$Audit.References.Add($reference)
            if ($Audit.Nested -and $primary.Status -eq 'Resolved' -and $reference.Status -eq 'Resolved' -and
                (Test-SamePath $reference.ResolvedPath $primary.ResolvedPath)) {
                if (@($stackNow | Where-Object { Test-SamePath $_ $reference.ResolvedPath }).Count) {
                    $reference.Cycle = $true; $reference.Notes += ' Cycle detected; traversal stopped at this edge.'
                } else {
                    # SQL*Plus can read any extension. Recognize foreign languages
                    # conservatively and report them rather than parsing them as SQL.
                    $extension = [IO.Path]::GetExtension($reference.ResolvedPath)
                    if ($script:ExcludedExtensions -contains $extension -or
                        @('.bat', '.cmd', '.ps1', '.exe', '.dll', '.png', '.jpg', '.pdf', '.sh', '.py') -contains $extension) {
                        Add-Issue $Audit 'Reached content type is unsupported for nested SQL*Plus parsing.' $reference.ResolvedPath
                    } else { Visit-Script $Audit $reference.ResolvedPath $stackNow ($Chain + ':' + $call.LineNumber + ' -> ' + (Get-RelativePath $reference.ResolvedPath $Audit.Root)) }
                }
            }
        }
    }
}

function Get-MasterCallChecks($Audit) {
    # FilenamePresence can create several file matches for a single source line.
    # Count each master call once, including repeated calls on different lines.
    # Generic unsupported-command diagnostics have no file target and belong in
    # the detailed audit, not in the master file-call counts.
    foreach ($group in @($Audit.References | Where-Object { $_.Direct -and $_.Command -in @('START', '@', '@@') } | Group-Object LineNumber | Sort-Object { [int]$_.Name })) {
        $refs = @($group.Group)
        $status = if (@($refs | Where-Object { $_.Status -eq 'IgnoredMissing' }).Count) { 'IgnoredMissing' }
            elseif (@($refs | Where-Object { $_.Status -in @('MissingInHotfix', 'OutsideHotfix') }).Count) { 'Missing' }
            elseif (@($refs | Where-Object { $_.Status -ne 'Resolved' }).Count) { 'Review' }
            else { 'Present' }
        [pscustomobject]@{ Target = $refs[0].Target; LineNumber = $refs[0].LineNumber; PresenceStatus = $status }
    }
}

function New-Audit([string]$Root, [string]$Master, [string]$Working, [bool]$Nested) {
    return [pscustomobject]@{
        Root = $Root; Master = $Master; WorkingDirectory = $Working; Nested = $Nested
        ExecutedBy = [Environment]::UserName
        Encoding = $ScriptEncoding
        Files = (New-Object System.Collections.ArrayList); ByPath = (New-PathMap); ByName = (New-PathMap)
        References = (New-Object System.Collections.ArrayList); Issues = (New-Object System.Collections.ArrayList)
        Rows = @(); MasterCalls = @(); Cache = (New-PathMap); Visited = (New-PathMap); ModelIssues = (New-Object System.Collections.ArrayList)
        SuffixUnknown = $false; SyntaxUnknown = $false; ModelChanged = $false
        ExitCode = 2; Counts = @{}; Summary = ''; ReportPaths = @(); Repeated = @(); MasterReadable = $false
        InputError = ''; NormalizedRoot = $true
        ShowProgress = $false; ProgressWatch = [Diagnostics.Stopwatch]::StartNew()
        EncodingFallbacks = (New-Object System.Collections.ArrayList)
        InstallerStatus = 'NotChecked'; InstallerNote = ''
        ScriptRenameNotes = (New-Object System.Collections.ArrayList)
        DocumentationNote = ''; ZeroByteFiles = @(); InventoryComplete = $false
    }
}

function Invoke-Audit($Audit) {
    try {
        if ($Audit.InputError) { throw $Audit.InputError }
        Update-AuditProgress $Audit 'Validating hotfix and master paths...' -Force
        Assert-NoPathLinks $Audit.Root
        if (-not (Test-Path -LiteralPath $Audit.Root -PathType Container)) { throw 'Hotfix directory does not exist or is inaccessible.' }
        if (-not (Test-InRoot $Audit.Master $Audit.Root)) { throw 'Selected master must be within this hotfix.' }
        if ([IO.Path]::GetExtension($Audit.Master) -ine '.sql') { throw 'Selected master must be a .sql file.' }
        Assert-NoPathLinks $Audit.Master
        if (-not (Test-Path -LiteralPath $Audit.Master -PathType Leaf)) { throw 'Selected master does not exist or is inaccessible.' }
        if (-not (Test-Path -LiteralPath $Audit.WorkingDirectory -PathType Container)) { throw 'Assumed working directory does not exist or is inaccessible.' }
        Assert-NoPathLinks $Audit.WorkingDirectory
        Rename-HotfixScripts $Audit
        Rename-HotfixDocumentation $Audit
        Update-AuditProgress $Audit 'Scanning hotfix folders...' -Force
        Get-Inventory $Audit
        Update-AuditProgress $Audit ('Inventory complete: ' + $Audit.Files.Count + ' files found.') -Force
        if (-not $Audit.ByPath.ContainsKey($Audit.Master)) { throw 'Selected master was not accessible in the inventory.' }
        $inventoryIssues = @($Audit.Issues)
        Update-AuditProgress $Audit ('Reading master and checking calls: ' + $Audit.Master) -Force
        # Settings changed by nested scripts persist in SQL*Plus. Rebuild the graph
        # conservatively when a reached setting invalidates default assumptions.
        do {
            $Audit.ModelChanged = $false; $Audit.Visited = New-PathMap
            $Audit.References.Clear(); $Audit.Issues.Clear()
            foreach ($issue in $inventoryIssues) { [void]$Audit.Issues.Add($issue) }
            Visit-Script $Audit $Audit.Master @() (Get-RelativePath $Audit.Master $Audit.Root)
        } while ($Audit.ModelChanged)
        $Audit.MasterReadable = $Audit.Cache.ContainsKey($Audit.Master) -and $Audit.Cache[$Audit.Master].ReadSucceeded
        foreach ($issue in $Audit.ModelIssues) {
            if (-not @($Audit.Issues | Where-Object { (Test-SamePath $_.SourceFile $issue.SourceFile) -and $_.LineNumber -eq $issue.LineNumber -and $_.Message -eq $issue.Message }).Count) {
                [void]$Audit.Issues.Add($issue)
            }
        }
        if ($Audit.MasterReadable) { Update-HotfixInstaller $Audit }
    } catch { Add-Issue $Audit $_.Exception.Message $Audit.Root }
    Update-AuditProgress $Audit 'Preparing coverage results...' -Force
    $matchesByPath = New-PathMap; $ambiguitiesByPath = New-PathMap
    foreach ($reference in $Audit.References) {
        if ($reference.Status -eq 'Resolved') {
            if (-not $matchesByPath.ContainsKey($reference.ResolvedPath)) { $matchesByPath[$reference.ResolvedPath] = New-Object System.Collections.ArrayList }
            [void]$matchesByPath[$reference.ResolvedPath].Add($reference)
        } elseif ($reference.Status -eq 'Ambiguous') {
            foreach ($candidate in ($reference.Candidates -split ' \| ')) {
                if (-not $ambiguitiesByPath.ContainsKey($candidate)) { $ambiguitiesByPath[$candidate] = New-Object System.Collections.ArrayList }
                [void]$ambiguitiesByPath[$candidate].Add($reference)
            }
        }
    }
    $rows = foreach ($file in @($Audit.Files | Sort-Object RelativePath)) {
        if ($file.Excluded -or (Test-SamePath $file.FullPath $Audit.Master)) { continue }
        $matched = @(); if ($matchesByPath.ContainsKey($file.FullPath)) { $matched = @($matchesByPath[$file.FullPath]) }
        $direct = @($matched | Where-Object { $_.Direct })
        $indirect = @($matched | Where-Object { -not $_.Direct })
        $ambiguous = @(); if ($ambiguitiesByPath.ContainsKey($file.FullPath)) { $ambiguous = @($ambiguitiesByPath[$file.FullPath]) }
        $notes = @($matched | ForEach-Object { $_.Notes } | Where-Object { $_ })
        if ($ambiguous.Count) { $notes += 'Candidate for ambiguous call(s): ' + (($ambiguous | ForEach-Object { $_.SourceFile + ':' + $_.LineNumber }) -join ' | ') }
        if ($file.IsLink) { $notes += 'File link skipped; review manually.' }
        [pscustomobject]@{
            HotfixRoot = $Audit.Root; SelectedMaster = $Audit.Master; RelativeFilePath = $file.RelativePath
            Extension = $(if ($file.Extension) { $file.Extension } else { '(none)' })
            DirectReferenceStatus = $(if ($direct.Count) { 'DirectlyReferenced' } elseif (@($ambiguous | Where-Object { $_.Direct }).Count) { 'Ambiguous' } else { 'NoDirectReferenceFound' })
            IndirectReferenceStatus = $(if (-not $Audit.Nested) { 'NotChecked' } elseif ($indirect.Count) { 'IndirectlyReferenced' } elseif (@($ambiguous | Where-Object { -not $_.Direct }).Count) { 'Ambiguous' } else { 'NoIndirectReferenceFound' })
            MatchingMethod = (($matched | ForEach-Object { $_.MatchingMethod } | Sort-Object -Unique) -join ' | ')
            ReferenceSourceFile = (($matched | ForEach-Object { $_.SourceFile + ':' + $_.LineNumber }) -join ' | ')
            SourceLineNumbers = (($matched | ForEach-Object { $_.LineNumber }) -join ' | ')
            NumberOfDetectedCalls = $matched.Count; DirectCallCount = $direct.Count; IndirectCallCount = $indirect.Count
            CallChains = (($matched | ForEach-Object { $_.CallChain } | Sort-Object -Unique) -join ' | ')
            Notes = (($notes | Sort-Object -Unique) -join ' | ')
        }
    }
    $Audit.Rows = @($rows)
    $Audit.Repeated = @($matchesByPath.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 } | ForEach-Object {
        [pscustomobject]@{ Name = $_.Key; Count = $_.Value.Count; Group = @($_.Value) }
    })
    $Audit.MasterCalls = @(Get-MasterCallChecks $Audit)
    $Audit.ZeroByteFiles = @($Audit.Files | Where-Object {
        -not $_.IsLink -and $null -ne $_.Length -and $_.Length -eq 0 -and $script:ZeroByteIgnoredExtensions -notcontains $_.Extension
    } | Sort-Object RelativePath)
    $Audit.Counts = Get-AuditCounts $Audit
    $incomplete = ($Audit.Issues.Count -gt 0 -or $Audit.Counts['Master calls requiring review'] -gt 0 -or
        @($Audit.References | Where-Object { $_.Status -in @('Unresolved', 'Unsupported') }).Count -gt 0)
    $findings = ($Audit.ZeroByteFiles.Count -gt 0 -or @($Audit.Rows | Where-Object { $_.DirectReferenceStatus -ne 'DirectlyReferenced' }).Count -gt 0 -or
        @($Audit.References | Where-Object { $_.Status -notin @('Resolved', 'IgnoredMissing') -or $_.Cycle }).Count -gt 0 -or $Audit.Repeated.Count -gt 0)
    $Audit.ExitCode = if ($incomplete) { 2 } elseif ($findings) { 1 } else { 0 }
    foreach ($row in $Audit.Rows) {
        $row | Add-Member -NotePropertyName AuditStatus -NotePropertyValue $(if ($incomplete) { 'Incomplete' } else { 'Completed' })
    }
}

function Get-AuditCounts($Audit) {
    $direct = @($Audit.Rows | Where-Object { $_.DirectReferenceStatus -eq 'DirectlyReferenced' }).Count
    $counts = [ordered]@{
        'Total files discovered' = $Audit.Files.Count
        'Files excluded by extension' = @($Audit.Files | Where-Object { $_.Excluded }).Count
        'Eligible files checked' = $Audit.Rows.Count
        'Files directly referenced' = $direct; 'Files not directly referenced' = $Audit.Rows.Count - $direct
        'Files referenced only indirectly' = @($Audit.Rows | Where-Object { $_.DirectReferenceStatus -ne 'DirectlyReferenced' -and $_.IndirectReferenceStatus -eq 'IndirectlyReferenced' }).Count
    }
    foreach ($entry in @(@('Ambiguous references', 'Ambiguous'), @('Unresolved references', 'Unresolved'),
        @('Unsupported invocations', 'Unsupported'), @('Call targets not found within scanned hotfix', 'MissingInHotfix'), @('References outside scanned hotfix', 'OutsideHotfix'))) {
        $counts[$entry[0]] = @($Audit.References | Where-Object { $_.Status -eq $entry[1] }).Count
    }
    $counts['Master calls checked'] = $Audit.MasterCalls.Count
    foreach ($entry in @(@('Calls with files present', 'Present'), @('Allowed missing calls ignored', 'IgnoredMissing'),
        @('Required calls missing files', 'Missing'), @('Master calls requiring review', 'Review'))) {
        $counts[$entry[0]] = @($Audit.MasterCalls | Where-Object { $_.PresenceStatus -eq $entry[1] }).Count
    }
    $counts['Repeated targets'] = $Audit.Repeated.Count
    $counts['0KB files found'] = $Audit.ZeroByteFiles.Count
    $counts['Cycles'] = @($Audit.References | Where-Object { $_.Cycle }).Count
    $counts['Read errors / other incomplete-analysis reasons'] = $Audit.Issues.Count
    return $counts
}

function Get-MasterCallSummary($Audit) {
    $s = New-Object 'System.Collections.Generic.List[string]'
    $s.Add((Get-SectionBanner 'Master call file check (hotfix folder)'))
    if (-not $Audit.MasterReadable) {
        $s.Add('File presence result: COULD NOT CHECK - the hotfix or master could not be read.')
        return ($s -join [Environment]::NewLine)
    }
    $missing = @($Audit.MasterCalls | Where-Object { $_.PresenceStatus -eq 'Missing' })
    $review = @($Audit.MasterCalls | Where-Object { $_.PresenceStatus -eq 'Review' })
    if ($missing.Count) {
        $s.Add('File presence result: NO - ' + $missing.Count + ' required call(s) have no matching file in the hotfix folder.')
    } elseif ($Audit.ExitCode -eq 2 -or $review.Count) {
        $s.Add('File presence result: INCOMPLETE - some files or calls could not be checked.')
    } elseif (-not $Audit.MasterCalls.Count) {
        $s.Add('File presence result: No active master calls to check.')
    } else {
        $s.Add('File presence result: YES - all required master calls have matching files in the hotfix folder.')
    }
    foreach ($label in @('Master calls checked', 'Calls with files present', 'Allowed missing calls ignored', 'Required calls missing files')) {
        $s.Add($label + ': ' + $Audit.Counts[$label])
    }
    $s.Add(''); $s.Add('Required files missing from hotfix folder (master line numbers)')
    if (-not $missing.Count) { $s.Add('  (none)') }
    foreach ($call in $missing) { $s.Add('  ' + $call.Target + ' (line ' + $call.LineNumber + ')') }
    if ($review.Count) {
        $s.Add('Note: ' + $review.Count + ' script call(s) could not be resolved. Use -DetailedReport for source lines and reasons.')
    }
    return ($s -join [Environment]::NewLine)
}

function Get-ZeroByteSummary($Audit) {
    $s = New-Object 'System.Collections.Generic.List[string]'
    $s.Add((Get-SectionBanner '0KB file check'))
    if ($Audit.ZeroByteFiles.Count) {
        $s.Add('0KB files found: ' + $Audit.ZeroByteFiles.Count)
        foreach ($file in $Audit.ZeroByteFiles) { $s.Add('  ' + (ConvertTo-SafeText $file.RelativePath)) }
    } elseif ($Audit.InventoryComplete) {
        $s.Add('0KB files were not found.')
    } else {
        $s.Add('0KB files could not be fully checked.')
    }
    if (-not $Audit.InventoryComplete) { $s.Add('Note: The inventory is incomplete; these results cover only accessible files.') }
    return ($s -join [Environment]::NewLine)
}

function Get-CoverageSummary($Audit) {
    $s = New-Object 'System.Collections.Generic.List[string]'
    $s.Add('Executed by: ' + (ConvertTo-SafeText $Audit.ExecutedBy))
    $s.Add('Hotfix: ' + (ConvertTo-SafeText $Audit.Root))
    $s.Add('Selected master: ' + (ConvertTo-SafeText $Audit.Master))
    if ($Audit.InstallerNote) { $s.Add((ConvertTo-SafeText $Audit.InstallerNote)) }
    foreach ($note in $Audit.ScriptRenameNotes) { $s.Add((ConvertTo-SafeText $note)) }
    if ($Audit.DocumentationNote) { $s.Add((ConvertTo-SafeText $Audit.DocumentationNote)) }
    foreach ($choice in $Audit.EncodingFallbacks) {
        $s.Add('Encoding fallback: ' + (ConvertTo-SafeText (Get-RelativePath $choice.SourceFile $Audit.Root)) + ' read as ' + $choice.Encoding + ' after invalid UTF-8.')
    }
    if (@($Audit.References | Where-Object { $_.MatchingMethod -eq 'FilenamePresence' }).Count) {
        $s.Add('Matching: Bare filenames called in the master cover all exact-name copies across hotfix folders; runtime path selection is not verified.')
    }
    if (-not $Audit.MasterReadable) {
        $s.Add('Result: COULD NOT CHECK - the hotfix or master could not be read.')
        if ($Audit.Issues.Count) { $s.Add('Reason: ' + (ConvertTo-SafeText $Audit.Issues[0].Message)) }
        $s.Add(''); $s.Add((Get-MasterCallSummary $Audit))
        $s.Add(''); $s.Add((Get-ZeroByteSummary $Audit))
        return ($s -join [Environment]::NewLine)
    }
    $notDirect = @($Audit.Rows | Where-Object { $_.DirectReferenceStatus -ne 'DirectlyReferenced' } | Sort-Object RelativeFilePath)
    if ($notDirect.Count) {
        $s.Add('Result: ' + $(if ($Audit.ExitCode -eq 2) { '' } else { 'NO - ' }) + $notDirect.Count + ' file(s) have no matching call in the master.')
    } elseif ($Audit.ExitCode -eq 2) {
        $s.Add('Result: Every listed file has a matching call, but the check is incomplete.')
    } elseif (-not $Audit.Rows.Count) {
        $s.Add('Result: No eligible files to check.')
    } else {
        $s.Add('Result: YES - all checked files are called by the master.')
    }
    $s.Add('Files checked: ' + $Audit.Rows.Count)
    $s.Add('Files called by master: ' + $Audit.Counts['Files directly referenced'])
    $s.Add('Files with no matching call: ' + $notDirect.Count)
    $s.Add('Skipped: selected master and ' + $Audit.Counts['Files excluded by extension'] + ' file(s) with excluded extensions (' + ($script:ExcludedExtensions -join ', ') + ').')
    if ($Audit.ExitCode -eq 2) {
        if ($Audit.Issues.Count) { $s.Add('Reason: ' + (ConvertTo-SafeText $Audit.Issues[0].Message)) }
    } elseif (@($Audit.References | Where-Object { $_.Status -eq 'Ambiguous' }).Count) {
        $s.Add('Note: An ambiguous filename could not be matched to a specific file.')
    }
    $s.Add('')
    $s.Add((Get-SectionBanner 'Files with no matching call in the master'))
    if (-not $notDirect.Count) { $s.Add('  (none)') }
    foreach ($row in $notDirect) { $s.Add('  ' + $row.RelativeFilePath) }
    $s.Add(''); $s.Add((Get-MasterCallSummary $Audit))
    $s.Add(''); $s.Add((Get-ZeroByteSummary $Audit))
    return ($s -join [Environment]::NewLine)
}

function Get-Summary($Audit) {
    $s = New-Object 'System.Collections.Generic.List[string]'
    $notDirect = @($Audit.Rows | Where-Object { $_.DirectReferenceStatus -ne 'DirectlyReferenced' })
    $s.Add((Get-SectionBanner 'Hotfix Checker'))
    $s.Add('Executed by: ' + (ConvertTo-SafeText $Audit.ExecutedBy))
    $s.Add('Hotfix: ' + (ConvertTo-SafeText $Audit.Root)); $s.Add('Selected master: ' + (ConvertTo-SafeText $Audit.Master))
    $s.Add('Static references only; no hotfix scripts were executed.')
    if ($Audit.InstallerNote) { $s.Add((ConvertTo-SafeText $Audit.InstallerNote)) }
    foreach ($note in $Audit.ScriptRenameNotes) { $s.Add((ConvertTo-SafeText $note)) }
    if ($Audit.DocumentationNote) { $s.Add((ConvertTo-SafeText $Audit.DocumentationNote)) }
    $s.Add('Result: ' + $(if ($Audit.ExitCode -eq 2) { 'INCOMPLETE / FAILED - coverage is provisional.' } elseif ($Audit.ExitCode -eq 1) { 'Completed with findings.' } else { 'Completed with no findings.' }))
    $s.Add('Mode: ' + $(if ($Audit.Nested) { 'Direct and reachable nested calls' } else { 'Direct master calls only' }))
    $s.Add('Assumed working directory (START/@): ' + (ConvertTo-SafeText $Audit.WorkingDirectory))
    $s.Add('Script encoding without BOM: ' + $Audit.Encoding + ' (Unicode BOM overrides).')
    foreach ($choice in $Audit.EncodingFallbacks) {
        $s.Add('Automatic per-file encoding fallback: ' + (ConvertTo-SafeText $choice.SourceFile) + ' = ' + $choice.Encoding)
    }
    $s.Add('Bare START/@ filenames in the master cover all exact-name copies; explicit paths and @@ remain path-based. Nested reads use only the resolved primary path.')
    $s.Add('@@ resolves relative to its caller. Default suffix: .sql unless flagged as unknown.')
    $s.Add('UniqueFilename is an inventory match, not proof of runtime lookup. SQLPATH is not searched.')
    foreach ($entry in $Audit.Counts.GetEnumerator()) {
        if ($Audit.Nested -or $entry.Key -ne 'Files referenced only indirectly') { $s.Add($entry.Key + ': ' + $entry.Value) }
    }
    $s.Add(''); $s.Add((Get-SectionBanner 'Files with no matching call in the master'))
    if (-not $notDirect.Count) { $s.Add('  (none found in the accessible inventory)') }
    foreach ($group in @($notDirect | Group-Object Extension | Sort-Object Name)) {
        $s.Add('  ' + $group.Name)
        foreach ($row in $group.Group) {
            $s.Add('    ' + $row.RelativeFilePath + ' [' + $row.DirectReferenceStatus + '; ' + $row.IndirectReferenceStatus + ']')
        }
    }
    $s.Add(''); $s.Add((Get-MasterCallSummary $Audit))
    $s.Add(''); $s.Add((Get-ZeroByteSummary $Audit))
    foreach ($section in @(
        @{ Title = 'Ambiguous references'; Status = @('Ambiguous') },
        @{ Title = 'Unresolved / manual review'; Status = @('Unresolved', 'Unsupported') },
        @{ Title = 'Call targets not found within scanned hotfix'; Status = @('MissingInHotfix') },
        @{ Title = 'References outside scanned hotfix (not checked externally)'; Status = @('OutsideHotfix') }
    )) {
        $s.Add(''); $s.Add($section.Title + ':')
        $refs = @($Audit.References | Where-Object { $section.Status -contains $_.Status })
        if (-not $refs.Count) { $s.Add('  (none)') }
        foreach ($r in $refs) {
            $s.Add('  ' + $r.SourceFile + ':' + $r.LineNumber + ' [' + $r.Status + '] ' + $r.SourceText)
            $s.Add('    ' + $r.Notes)
            if ($r.ResolvedPath) { $s.Add('    Normalized target: ' + $r.ResolvedPath) }
            if ($r.Candidates) { $s.Add('    Candidates: ' + $r.Candidates) }
        }
    }
    $s.Add(''); $s.Add('Detected resolved calls (source lines and representative call chains):')
    foreach ($r in @($Audit.References | Where-Object { $_.Status -eq 'Resolved' })) {
        $s.Add('  ' + $r.SourceFile + ':' + $r.LineNumber + ' -> ' + $r.ResolvedPath + ' [' + $r.MatchingMethod + ']')
        $s.Add('    Chain: ' + $r.CallChain)
        if ($r.Notes) { $s.Add('    ' + $r.Notes) }
    }
    $s.Add(''); $s.Add('Repeated calls (static call sites, not runtime execution counts):')
    foreach ($g in $Audit.Repeated) {
        $s.Add('  ' + $g.Name + ': ' + $g.Count + ' call sites - ' + (($g.Group | ForEach-Object { $_.SourceFile + ':' + $_.LineNumber }) -join ' | '))
    }
    if (-not $Audit.Repeated.Count) { $s.Add('  (none)') }
    $s.Add(''); $s.Add('Read errors / incomplete-analysis reasons:')
    foreach ($issue in $Audit.Issues) { $s.Add((ConvertTo-SafeText ('  ' + $issue.SourceFile + ':' + $issue.LineNumber + ' ' + $issue.Message + ' ' + $issue.SourceText))) }
    if (-not $Audit.Issues.Count) { $s.Add('  (none)') }
    $s.Add(''); $s.Add('This audit does not prove that a deployment will execute successfully. Exit code: ' + $Audit.ExitCode)
    return ($s -join [Environment]::NewLine)
}

function Write-ReportCsv([object[]]$Rows, [string[]]$Columns, [string]$Path) {
    $lines = if ($Rows.Count) {
        foreach ($row in $Rows) {
            $safe = [ordered]@{}
            foreach ($column in $Columns) {
                $value = ConvertTo-SafeText ([string]$row.$column)
                # A visible text prefix survives spreadsheet save/reopen, unlike
                # relying on removable CSV quote/apostrophe escaping alone.
                if ($value -match '^[\s\p{Cf}]*[=+\-@\uFF1D\uFF0B\uFF0D\uFF20]') { $value = 'text:' + $value }
                $safe[$column] = $value
            }
            [pscustomobject]$safe
        }
    }
    if ($Rows.Count) { Write-ReportText $Path @($lines | ConvertTo-Csv -NoTypeInformation) }
    else { Write-ReportText $Path @(($Columns | ForEach-Object { '"' + $_ + '"' }) -join ',') }
}

function Select-Master([string]$Root) {
    $folderName = [IO.Path]::GetFileName($Root.TrimEnd('\'))
    $detectedMaster = ''
    if ($folderName) {
        $expectedMaster = Join-Path (Join-Path $Root 'sql') ($folderName + '.sql')
        try {
            Assert-NoPathLinks $expectedMaster
            if (Test-Path -LiteralPath $expectedMaster -PathType Leaf) {
                $detectedMaster = (Get-Item -LiteralPath $expectedMaster -Force).FullName
            }
        } catch { Write-Console ('Master detection warning: ' + $_.Exception.Message) }
    }
    if ($detectedMaster) {
        Write-Console ("`nDetected master: " + $detectedMaster)
        while ($true) {
            Write-Console ('Is ' + [IO.Path]::GetFileName($detectedMaster) + ' the master script for this hotfix? (Y/N)')
            $confirmation = (Read-Host 'Y/N').Trim()
            if ($confirmation -ieq 'Y' -or $confirmation -ieq 'YES') { return $detectedMaster }
            if ($confirmation -ieq 'N' -or $confirmation -ieq 'NO') { break }
            Write-Console 'Please enter Y or N.'
        }
        Write-Console 'Select the master manually.'
    } else {
        Write-Console ("`nNo master matching the hotfix folder name was found. Select the master manually.")
    }
    $sqlRoot = Join-Path $Root 'sql'
    $sqlFiles = @()
    if (Test-Path -LiteralPath $sqlRoot -PathType Container) {
        # Use the same bounded inventory logic; never traverse directory links.
        $menuAudit = New-Audit $sqlRoot '' '' $false
        try {
            Assert-NoPathLinks $sqlRoot
            Get-Inventory $menuAudit
            $sqlFiles = @($menuAudit.Files | Where-Object { $_.Extension -eq '.sql' -and -not $_.IsLink } | Sort-Object RelativePath)
        } catch { Write-Console ('Menu warning: ' + $_.Exception.Message) }
        foreach ($issue in $menuAudit.Issues) { Write-Console ('Menu warning: ' + $issue.Message + ' ' + $issue.SourceFile) }
    }
    Write-Console "`nSelect the master for: $Root"
    for ($i = 0; $i -lt $sqlFiles.Count; $i++) { Write-Console ('  {0}. {1}' -f ($i + 1), $sqlFiles[$i].FullPath) }
    Write-Console '  M. Enter a master .sql path manually (relative to hotfix or absolute)'
    while ($true) {
        $choice = Read-Host 'Master number, M, or a file path'
        $index = 0
        if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $sqlFiles.Count) { return $sqlFiles[$index - 1].FullPath }
        if ($choice -ieq 'M') { $choice = Read-Host 'Master .sql path' }
        try {
            $master = Get-NormalPath $choice $Root
            if (-not (Test-InRoot $master $Root) -or [IO.Path]::GetExtension($master) -ine '.sql') { throw 'Choose a .sql file inside this hotfix.' }
            Assert-NoPathLinks $master
            if (-not (Test-Path -LiteralPath $master -PathType Leaf)) { throw 'File does not exist or is inaccessible.' }
            return $master
        } catch { Write-Console ('Invalid master: ' + $_.Exception.Message) }
    }
}

function Invoke-Checker {
    if ($Help) {
        Write-Console 'Hotfix Checker - Windows PowerShell 5.1'
        Write-Console 'No arguments: hotfix paths, automatic master detection and Y/N confirmation.'
        Write-Console 'Parameters: -HotfixPath <paths> -MasterPath <paths> [-WorkingDirectory <paths>]'
        Write-Console '            [-IncludeNested] [-ReportDirectory <path>] [-NonInteractive]'
        Write-Console '            [-DetailedReport] (optional CSVs and full call details)'
        Write-Console '            [-NoPause] (disable the final wait in an interactive script run)'
        Write-Console '            [-ScriptEncoding Auto|UTF8|Default|Windows1252|Unicode|BigEndianUnicode] [-MaxScriptSizeMB 64]'
        Write-Console 'Alternative batch input: -InputCsv <csv> with HotfixPath,MasterPath,WorkingDirectory columns.'
        Write-Console 'See README.md for examples and exit codes (0 / 1 / 2).'
        return 0
    }
    $jobs = New-Object System.Collections.ArrayList
    if ($InputCsv) {
        if ($HotfixPath -or $MasterPath -or $WorkingDirectory) { throw 'InputCsv cannot be combined with HotfixPath, MasterPath, or WorkingDirectory.' }
        $records = @(Import-Csv -LiteralPath $InputCsv)
        if (-not $records.Count) { throw 'Input CSV has no hotfix rows.' }
        foreach ($record in $records) {
            if (-not $record.PSObject.Properties['HotfixPath'] -or -not $record.PSObject.Properties['MasterPath']) { throw 'CSV requires HotfixPath and MasterPath columns.' }
            $wd = if ($record.PSObject.Properties['WorkingDirectory']) { $record.WorkingDirectory } else { '' }
            [void]$jobs.Add(@{ Hotfix = $record.HotfixPath; Master = $record.MasterPath; Working = $wd })
        }
    } elseif ($HotfixPath -or $MasterPath -or $NonInteractive) {
        if (-not $HotfixPath -or -not $MasterPath -or $HotfixPath.Count -ne $MasterPath.Count) { throw 'Supply one MasterPath for each HotfixPath; no prompts are used when paths are supplied.' }
        if ($WorkingDirectory -and $WorkingDirectory.Count -ne 1 -and $WorkingDirectory.Count -ne $HotfixPath.Count) { throw 'WorkingDirectory must have one value, or one per hotfix.' }
        for ($i = 0; $i -lt $HotfixPath.Count; $i++) {
            $wd = if (-not $WorkingDirectory) { '' } elseif ($WorkingDirectory.Count -eq 1) { $WorkingDirectory[0] } else { $WorkingDirectory[$i] }
            [void]$jobs.Add(@{ Hotfix = $HotfixPath[$i]; Master = $MasterPath[$i]; Working = $wd })
        }
    } else {
        Write-Console (Get-SectionBanner 'Hotfix Checker - check file coverage and master call targets')
        Write-Console 'Enter hotfix folders one per line; submit a blank line when finished.'
        while ($true) {
            $prompt = if ($jobs.Count) { 'Another hotfix folder (press Enter to choose masters)' } else { 'Hotfix folder' }
            $entered = Read-Host $prompt
            if ([string]::IsNullOrWhiteSpace($entered)) { break }
            try {
                $root = Get-NormalPath $entered
                Assert-NoPathLinks $root
                if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Directory does not exist or is inaccessible.' }
                if (Test-InRoot $PSScriptRoot $root) { throw 'The utility must be outside the hotfix folder.' }
                if (@($jobs | Where-Object { Test-SamePath $_.Hotfix $root }).Count) {
                    Write-Console ('Already added: ' + $root)
                    Write-Console 'Press Enter on the empty prompt to continue to master selection, or enter a different hotfix folder.'
                    continue
                }
                [void]$jobs.Add(@{ Hotfix = $root; Master = ''; Working = '' })
                Write-Console ('Added hotfix: ' + $root)
                Write-Console 'Press Enter on the empty prompt to continue to master selection, or enter another hotfix folder.'
            } catch { Write-Console ('Invalid hotfix: ' + $_.Exception.Message) }
        }
        if (-not $jobs.Count) { Write-Console 'No hotfixes selected.'; return 2 }
        Write-Console 'Hotfixes selected: Next, confirm or select a master for each hotfix.'
        if ($WorkingDirectory -and $WorkingDirectory.Count -ne 1 -and $WorkingDirectory.Count -ne $jobs.Count) { throw 'WorkingDirectory must have one value, or one per hotfix.' }
        for ($i = 0; $i -lt $jobs.Count; $i++) {
            $jobs[$i].Master = Select-Master $jobs[$i].Hotfix
            if ($WorkingDirectory) { $jobs[$i].Working = if ($WorkingDirectory.Count -eq 1) { $WorkingDirectory[0] } else { $WorkingDirectory[$i] } }
        }
    }
    $audits = New-Object System.Collections.ArrayList
    foreach ($job in $jobs) {
        $root = [string]$job.Hotfix; $master = [string]$job.Master; $wd = [string]$job.Working
        $inputError = ''; $normalizedRoot = $false
        try {
            $root = Get-NormalPath $job.Hotfix; $normalizedRoot = $true
            $master = Get-NormalPath $job.Master $root
            $wd = if ($job.Working) { Get-NormalPath $job.Working $root } else { [IO.Path]::GetDirectoryName($master) }
        } catch { $inputError = 'Invalid hotfix/master/working path: ' + $_.Exception.Message }
        if ($normalizedRoot -and (Test-LocationInRoot $PSScriptRoot $root)) { throw "Move the utility outside the scanned hotfix: $root" }
        $audit = New-Audit $root $master $wd ([bool]$IncludeNested)
        $audit.InputError = $inputError; $audit.NormalizedRoot = $normalizedRoot
        [void]$audits.Add($audit)
    }
    if (-not $ReportDirectory) { $ReportDirectory = Join-Path $PSScriptRoot 'reports' }
    $reportRoot = Get-NormalPath $ReportDirectory
    $script:ReportAudits = @($audits)
    Assert-ReportLocation $reportRoot
    $timestamp = Get-ReportTimestamp
    $fileColumns = @('HotfixRoot', 'SelectedMaster', 'RelativeFilePath', 'Extension', 'DirectReferenceStatus', 'IndirectReferenceStatus', 'MatchingMethod', 'ReferenceSourceFile', 'SourceLineNumbers', 'NumberOfDetectedCalls', 'DirectCallCount', 'IndirectCallCount', 'CallChains', 'Notes', 'AuditStatus')
    $refColumns = @('HotfixRoot', 'SelectedMaster', 'SourceFile', 'LineNumber', 'SourceText', 'Command', 'Target', 'Arguments', 'Direct', 'Status', 'MatchingMethod', 'ResolvedPath', 'Candidates', 'CallChain', 'Notes', 'Cycle')
    $overall = 0; $index = 0
    if ($audits.Count -gt 1) { Write-Console ('Hotfixes checked: ' + $audits.Count) }
    foreach ($audit in $audits) {
        $index++
        $name = Get-ReportName (Get-HotfixName $audit.Root)
        $runFolder = New-ReportFolder $reportRoot $timestamp $name
        $script:LastRunFolder = $runFolder
        $summaryPath = Join-Path $runFolder ('summary_' + $name + '.txt')
        Write-Console ("`nChecking hotfix: " + (ConvertTo-SafeText $audit.Root))
        if ($DetailedReport) { Write-Console ('Selected master: ' + (ConvertTo-SafeText $audit.Master)) }
        $audit.ShowProgress = $true
        Invoke-Audit $audit
        if (-not $DetailedReport) {
            # Normal runs check both coverage directions. Repeated calls and
            # cycles remain detailed-report findings.
            if ($audit.ExitCode -ne 2) {
                $audit.ExitCode = if ($audit.Counts['Files not directly referenced'] -or $audit.Counts['Required calls missing files'] -or $audit.ZeroByteFiles.Count) { 1 } else { 0 }
            }
            $summary = (Get-SectionBanner 'Hotfix Checker') + [Environment]::NewLine + (Get-CoverageSummary $audit)
            $summary += [Environment]::NewLine + [Environment]::NewLine + 'Summary saved to: ' + $summaryPath
            Write-Console '  Saving summary...'
            Write-ReportText $summaryPath @($summary)
            $audit.ReportPaths = @($summaryPath)
            Write-Console ("`n" + $summary)
            if ($audit.ExitCode -gt $overall) { $overall = $audit.ExitCode }
            continue
        }
        $audit.Summary = Get-Summary $audit
        $stem = '{0:D2}_{1}' -f $index, ($name -replace '[^a-zA-Z0-9._-]', '_')
        $txt = $summaryPath
        $csv = Join-Path $runFolder ($stem + '_files.csv')
        $refsCsv = Join-Path $runFolder ($stem + '_references.csv')
        Update-AuditProgress $audit 'Saving detailed reports...' -Force
        Write-ReportText $txt @($audit.Summary)
        Write-ReportCsv @($audit.Rows) $fileColumns $csv
        Write-ReportCsv @($audit.References) $refColumns $refsCsv
        $audit.ReportPaths = @($txt, $csv, $refsCsv)
        Write-Console "`n$($audit.Summary)"
        Write-Console "`nReports:"
        foreach ($report in $audit.ReportPaths) { Write-Console ('  ' + $report) }
        if ($audit.ExitCode -gt $overall) { $overall = $audit.ExitCode }
    }
    if (-not $DetailedReport) { return $overall }
    $totals = @((Get-SectionBanner 'Hotfix Checker - combined totals'),
        ('Executed by: ' + (ConvertTo-SafeText $audits[0].ExecutedBy)), ('Hotfixes reviewed: ' + $audits.Count))
    foreach ($label in $audits[0].Counts.Keys) {
        $value = ($audits | ForEach-Object { $_.Counts[$label] } | Measure-Object -Sum).Sum
        if ($label -eq 'Files referenced only indirectly' -and -not $IncludeNested) { $value = 'Not checked (direct-only mode)' }
        if ($label -eq 'Unresolved references') {
            $value += ($audits | ForEach-Object { $_.Counts['Unsupported invocations'] } | Measure-Object -Sum).Sum
            $displayLabel = 'Unresolved / unsupported references'
        } elseif ($label -eq 'Unsupported invocations') { continue }
        else { $displayLabel = $label.Replace('scanned hotfix', 'scanned hotfixes') }
        $totals += $displayLabel + ': ' + $value
    }
    $totals += 'Incomplete / failed hotfixes: ' + @($audits | Where-Object { $_.ExitCode -eq 2 }).Count
    $totals += 'Overall exit code: ' + $overall
    $totals = $totals -join [Environment]::NewLine
    if ($audits.Count -gt 1) {
        $runFolder = New-ReportFolder $reportRoot $timestamp 'Combined'
        $script:LastRunFolder = $runFolder
    }
    $combined = Join-Path $runFolder 'combined_summary.txt'
    Write-ReportText $combined @($totals)
    Write-Console "`n$totals`nCombined summary: $combined"
    return $overall
}

# Dot sourcing exposes the functions to the built-in regression harness only.
if ($MyInvocation.InvocationName -ne '.') {
    $interactiveRun = (-not $HotfixPath -and -not $MasterPath -and -not $InputCsv -and -not $NonInteractive -and -not $Help)
    $script:LastRunFolder = ''
    $code = 2
    try { $code = Invoke-Checker }
    catch {
        $failure = $_
        Write-Console ('INCOMPLETE / FAILED: ' + (ConvertTo-SafeText $failure.Exception.Message))
        # LastRunFolder is set only after the report destination passes all guards.
        # Preserve diagnostics there if an unexpected failure follows.
        if ($script:LastRunFolder) {
            try {
                $errorReport = Join-Path $script:LastRunFolder 'checker_error.txt'
                Write-ReportText $errorReport @(
                    ('INCOMPLETE / FAILED: ' + (ConvertTo-SafeText $failure.Exception.Message)),
                    $failure.ScriptStackTrace, 'Exit code: 2'
                )
                Write-Console ('Error details: ' + $errorReport)
            } catch { Write-Console ('Unable to save error details: ' + $_.Exception.Message) }
        }
    }
    finally {
        if ($interactiveRun -and -not $NoPause) {
            Write-Console "`nPress Enter to close this window."
            try { [void](Read-Host) } catch { Write-Console ('Unable to wait for input: ' + $_.Exception.Message) }
        }
    }
    exit $code
}
