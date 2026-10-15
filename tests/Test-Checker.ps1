#requires -Version 5.1
# No Pester, modules, SQL*Plus, or third-party test dependencies are needed.
$ErrorActionPreference = 'Stop'
$checker = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Hotfix-Checker.ps1'))
$launcher = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Hotfix-Checker.bat'))
. $checker
$testRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$fixtures = Join-Path $testRoot 'fixtures'
$work = Join-Path $testRoot ('.work\' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Path $work -Force)
$script:assertions = 0
$script:childConsoleEncoding = $null

function Assert-Equal($Actual, $Expected, [string]$Message) {
    $script:assertions++
    if ([string]$Actual -cne [string]$Expected) { throw "$Message - expected [$Expected], got [$Actual]." }
}
function Assert-True([bool]$Value, [string]$Message) { Assert-Equal $Value $true $Message }
function Row($Audit, [string]$Relative) {
    $rows = @($Audit.Rows | Where-Object { Test-SamePath $_.RelativeFilePath $Relative })
    Assert-Equal $rows.Count 1 "Exactly one eligible row for $Relative"
    return $rows[0]
}
function Audit-Fixture([string]$Name, [bool]$Nested = $false, [string]$Working = '') {
    $root = Get-NormalPath (Join-Path $fixtures $Name)
    $master = Join-Path $root 'sql\master.sql'
    if (-not $Working) { $Working = Split-Path -Parent $master }
    $audit = New-Audit $root $master $Working $Nested
    Invoke-Audit $audit
    return $audit
}
function New-TestHotfix([string]$Name, [string]$MasterText, [hashtable]$Files) {
    $root = Join-Path $work $Name
    [void](New-Item -ItemType Directory -Path (Join-Path $root 'sql') -Force)
    Set-Content -LiteralPath (Join-Path $root 'sql\master.sql') -Value $MasterText -Encoding UTF8
    foreach ($relative in $Files.Keys) {
        $path = Join-Path $root $relative
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
        Set-Content -LiteralPath $path -Value $Files[$relative] -Encoding UTF8
    }
    return $root
}
function Audit-Path([string]$Root, [bool]$Nested = $false, [string]$Working = '') {
    $master = Join-Path $Root 'sql\master.sql'
    if (-not $Working) { $Working = Split-Path -Parent $master }
    $audit = New-Audit $Root $master $Working $Nested
    Invoke-Audit $audit
    return $audit
}
function Run-Cli([string[]]$Arguments, [string]$Name, [bool]$Batch = $false) {
    $reportRoot = Join-Path $work ($Name + '-reports')
    $log = Join-Path $work ($Name + '.log')
    $argsToPass = @($Arguments) + @('-ReportDirectory', $reportRoot)
    if ($Batch) { & $launcher @argsToPass > $log 2>&1 }
    else { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checker @argsToPass > $log 2>&1 }
    $processCode = $LASTEXITCODE
    $summaries = @(); $combined = @()
    if (Test-Path -LiteralPath $reportRoot) {
        $summaries = @(Get-ChildItem -LiteralPath $reportRoot -File -Recurse -Filter 'summary_*.txt' | Sort-Object LastWriteTimeUtc -Descending)
        $combined = @(Get-ChildItem -LiteralPath $reportRoot -File -Recurse -Filter 'combined_summary.txt')
    }
    $folder = if ($summaries.Count) { $summaries[0].DirectoryName } else { '' }
    $summary = if ($summaries.Count) { $summaries[0].FullName } else { '' }
    return [pscustomobject]@{ ExitCode = $processCode; Folder = $folder; Log = $log; ReportRoot = $reportRoot
        SummaryPath = $summary; SummaryPaths = @($summaries | ForEach-Object { $_.FullName })
        CombinedPath = $(if ($combined.Count) { $combined[0].FullName } else { '' }) }
}
function Fixture-Hashes {
    return @((Get-ChildItem -LiteralPath $fixtures -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
        $_.FullName + ' ' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    })) -join "`n"
}
function Run-Interactive([string]$Entry, [string[]]$InputLines, [string]$Name, [bool]$Batch = $false,
    [switch]$VerifyKeepOpen, [string]$ReportOverride = '', [switch]$NoFinalPause, [switch]$Nested, [switch]$Detailed, [switch]$StrictUtf8) {
    if (-not $script:childConsoleEncoding) {
        # A windowless Windows PowerShell child can use an OEM code page even
        # when the parent console is UTF-8. Read its actual setting once so
        # redirected output preserves accented filenames in the assertions.
        $probeInfo = New-Object Diagnostics.ProcessStartInfo
        $probeInfo.FileName = (Get-Command powershell.exe).Source
        $probeInfo.Arguments = '-NoProfile -Command "[Console]::OutputEncoding.CodePage"'
        $probeInfo.UseShellExecute = $false; $probeInfo.CreateNoWindow = $true; $probeInfo.RedirectStandardOutput = $true
        $probe = [Diagnostics.Process]::Start($probeInfo)
        try {
            $codePage = $probe.StandardOutput.ReadToEnd().Trim()
            $probe.WaitForExit()
            if ($probe.ExitCode -ne 0) { throw 'Could not determine the child console encoding.' }
            $script:childConsoleEncoding = [Text.Encoding]::GetEncoding([int]$codePage)
        } finally { $probe.Dispose() }
    }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $script:childConsoleEncoding; $info.StandardErrorEncoding = $script:childConsoleEncoding
    if ($Batch) {
        $info.FileName = $env:ComSpec
        $info.Arguments = '/d /c ""' + $Entry + '""'
    } else {
        $info.FileName = (Get-Command powershell.exe).Source
        $reportPath = if ($ReportOverride) { $ReportOverride } else { Join-Path $work ($Name + '-reports') }
        $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Entry + '" -ReportDirectory "' + $reportPath + '"'
        if ($NoFinalPause) { $info.Arguments += ' -NoPause' }
        if ($Nested) { $info.Arguments += ' -IncludeNested' }
        if ($Detailed) { $info.Arguments += ' -DetailedReport' }
        if ($StrictUtf8) { $info.Arguments += ' -ScriptEncoding UTF8' }
    }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    [void]$process.Start()
    $stdout = if ($VerifyKeepOpen) { $null } else { $process.StandardOutput.ReadToEndAsync() }
    $stderr = $process.StandardError.ReadToEndAsync()
    foreach ($line in $InputLines) { $process.StandardInput.WriteLine($line) }
    $prefix = New-Object 'System.Collections.Generic.List[string]'
    $heldForClose = $false
    if ($VerifyKeepOpen) {
        # Leave stdin open after the menu selection. Verify the process reaches
        # the final wait, remains alive, and exits only after a separate Enter.
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while ([DateTime]::UtcNow -lt $deadline) {
            $lineTask = $process.StandardOutput.ReadLineAsync()
            $timeLeft = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if (-not $lineTask.Wait($timeLeft)) { break }
            if ($null -eq $lineTask.Result) { break }
            $prefix.Add($lineTask.Result)
            if ($lineTask.Result -eq 'Press Enter to close this window.') {
                $heldForClose = -not $process.WaitForExit(250)
                break
            }
        }
        if (-not $heldForClose) {
            if (-not $process.HasExited) { $process.Kill() }
            $process.Dispose()
            throw "Interactive test $Name did not stay open after completing the audit."
        }
        $process.StandardInput.WriteLine('')
        $stdout = $process.StandardOutput.ReadToEndAsync()
    }
    $process.StandardInput.Close()
    if (-not $process.WaitForExit(20000)) {
        $process.Kill(); $process.Dispose(); throw "Interactive test $Name did not finish within 20 seconds."
    }
    $process.WaitForExit()
    $output = ($prefix -join [Environment]::NewLine) + [Environment]::NewLine + $stdout.Result + $stderr.Result
    $exitCode = $process.ExitCode; $process.Dispose()
    Set-Content -LiteralPath (Join-Path $work ($Name + '.log')) -Value $output -Encoding UTF8
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output; HeldForClose = $heldForClose }
}

try {
    Write-Host ('Testing on Windows PowerShell ' + $PSVersionTable.PSVersion)
    Assert-True ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1) 'Run this harness with Windows PowerShell 5.1'
    $before = Fixture-Hashes
    Write-Host 'Checking zero-byte files and documentation names.'
    $zeroPaths = @('sql\empty.sql', 'data\zero.dat', 'archives\empty.zip', 'payload\empty.bundle', 'docs\empty.docx', 'data\empty.properties', 'scripts\support.pl.bak')
    $ignoredZeroPaths = @('scripts\support.PL', 'scripts\support.PERL', 'scripts\support.UNDEPLOY', 'docs\notes.TxT')
    $zeroFiles = @{ 'data\one.dat' = 'placeholder'; 'archives\small.zip' = 'placeholder' }
    foreach ($relative in @($zeroPaths) + @($ignoredZeroPaths)) { $zeroFiles[$relative] = 'placeholder' }
    $zeroRoot = New-TestHotfix 'Zero-byte inventory' "@empty.sql`n@zero.dat`n@one.dat`n@support.pl.bak" $zeroFiles
    foreach ($relative in @($zeroPaths) + @($ignoredZeroPaths)) { [IO.File]::WriteAllBytes((Join-Path $zeroRoot $relative), [byte[]]@()) }
    [IO.File]::WriteAllBytes((Join-Path $zeroRoot 'data\one.dat'), [byte[]]@(255))
    [IO.File]::WriteAllBytes((Join-Path $zeroRoot 'archives\small.zip'), [byte[]]@(1,2,3))
    $zeroBefore = @(Get-ChildItem -LiteralPath $zeroRoot -File -Recurse | Sort-Object FullName | ForEach-Object { $_.FullName + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join '|'
    $zeroAudit = Audit-Path $zeroRoot
    Assert-Equal $zeroAudit.ZeroByteFiles.Count 7 'Recursive zero-byte detection checks all file types except the four explicit exclusions'
    Assert-Equal $zeroAudit.Counts['0KB files found'] 7 'Zero-byte findings are included in report totals'
    Assert-Equal $zeroAudit.Counts['Files not directly referenced'] 0 'Zero-byte findings are independent of successful master call coverage'
    Assert-Equal $zeroAudit.ExitCode 1 'Zero-byte findings alone produce the findings exit code'
    foreach ($relative in $zeroPaths) { Assert-True (@($zeroAudit.ZeroByteFiles | Where-Object { $_.RelativePath -ceq $relative }).Count -eq 1) 'Each zero-byte file is listed by its full relative path'
    }
    Assert-Equal @($zeroAudit.ZeroByteFiles | Where-Object { $_.RelativePath -in $ignoredZeroPaths -or $_.Name -in @('one.dat', 'small.zip') }).Count 0 'Ignored extensions and nonempty files smaller than 1KB are not reported'
    Assert-Equal (@(Get-ChildItem -LiteralPath $zeroRoot -File -Recurse | Sort-Object FullName | ForEach-Object { $_.FullName + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join '|') $zeroBefore 'Zero-byte detection never modifies source files'
    Assert-True ((Get-CoverageSummary $zeroAudit) -match '(?s)0KB file check.*0KB files found: 7.*archives\\empty.zip') 'Normal summaries include zero-byte findings and paths'
    Assert-True ((Get-Summary $zeroAudit) -match '(?s)0KB file check.*0KB files found: 7') 'Detailed summaries include the same zero-byte check'
    $ignoredOnlyFiles = @{}
    foreach ($relative in $ignoredZeroPaths) { $ignoredOnlyFiles[$relative] = 'placeholder' }
    $ignoredOnlyRoot = New-TestHotfix 'Ignored zero-byte files' 'select 1 from dual;' $ignoredOnlyFiles
    foreach ($relative in $ignoredZeroPaths) { [IO.File]::WriteAllBytes((Join-Path $ignoredOnlyRoot $relative), [byte[]]@()) }
    $ignoredOnlyAudit = Audit-Path $ignoredOnlyRoot
    Assert-Equal $ignoredOnlyAudit.ExitCode 0 'Empty files with ignored extensions do not create a zero-byte finding'
    Assert-True ((Get-ZeroByteSummary $ignoredOnlyAudit) -match '0KB files were not found\.') 'A complete clean scan explicitly reports that no 0KB files were found'
    $emptyMasterRoot = New-TestHotfix 'Empty master file' 'placeholder' @{}
    [IO.File]::WriteAllBytes((Join-Path $emptyMasterRoot 'sql\master.sql'), [byte[]]@())
    $emptyMasterAudit = Audit-Path $emptyMasterRoot
    Assert-Equal $emptyMasterAudit.ZeroByteFiles.Count 1 'The selected master is included in the zero-byte scan'
    Assert-Equal $emptyMasterAudit.ZeroByteFiles[0].RelativePath 'sql\master.sql' 'An empty master is named in the zero-byte results'
    Assert-Equal $emptyMasterAudit.ExitCode 1 'An empty master cannot produce a clean completed run'

    $docHotfix = 'V12-023-2-02-HF-ALC-02'
    $docRoot = New-TestHotfix $docHotfix '@keep.pdf' @{
        'documentation\V12-023-2-02-HF-ALC-01.docx' = 'placeholder'
        'documentation\Hotfix Installation Instructions for V12C.docx' = 'Preserve installation instructions.'
        'documentation\sub\keep.docx' = 'Nested document; do not rename.'
        'documentation\~$Office.docx' = 'Office lock file; do not rename.'
        'documentation\keep.pdf' = 'A different document type.'
    }
    $oldDoc = Join-Path $docRoot 'documentation\V12-023-2-02-HF-ALC-01.docx'
    [IO.File]::WriteAllBytes($oldDoc, [byte[]]@(80,75,3,4,0,255,13,10,127))
    $docHash = (Get-FileHash -LiteralPath $oldDoc -Algorithm SHA256).Hash
    $docTime = [IO.File]::GetLastWriteTimeUtc($oldDoc).Ticks
    $instructionsFile = Join-Path $docRoot 'documentation\Hotfix Installation Instructions for V12C.docx'
    $instructionsHash = (Get-FileHash -LiteralPath $instructionsFile -Algorithm SHA256).Hash
    $instructionsTime = [IO.File]::GetLastWriteTimeUtc($instructionsFile).Ticks
    $docAudit = Audit-Path $docRoot
    $newDoc = Join-Path $docRoot ('documentation\' + $docHotfix + '.docx')
    Assert-Equal $docAudit.ExitCode 0 'A documentation rename completes without a coverage finding'
    Assert-True (Test-Path -LiteralPath $newDoc -PathType Leaf) 'The documentation filename matches the exact supplied hotfix name'
    Assert-True (-not (Test-Path -LiteralPath $oldDoc)) 'The previous documentation name is removed'
    Assert-Equal (Get-FileHash -LiteralPath $newDoc -Algorithm SHA256).Hash $docHash 'DOCX binary contents remain byte-for-byte identical'
    Assert-Equal ([IO.File]::GetLastWriteTimeUtc($newDoc).Ticks) $docTime 'DOCX renaming preserves its modification time'
    Assert-True (Test-Path -LiteralPath $instructionsFile -PathType Leaf) 'Installation instructions retain their original filename'
    Assert-Equal (Get-FileHash -LiteralPath $instructionsFile -Algorithm SHA256).Hash $instructionsHash 'Installation instructions retain their exact contents'
    Assert-Equal ([IO.File]::GetLastWriteTimeUtc($instructionsFile).Ticks) $instructionsTime 'Installation instructions retain their modification time'
    Assert-True ($docAudit.ByPath.ContainsKey($newDoc) -and -not $docAudit.ByPath.ContainsKey($oldDoc)) 'The inventory contains the final documentation name'
    Assert-True ((Get-CoverageSummary $docAudit) -match 'Documentation renamed:') 'An actual documentation rename is recorded in the summary'
    Assert-True (Test-Path -LiteralPath (Join-Path $docRoot 'documentation\sub\keep.docx')) 'Nested DOCX files keep their names'
    Assert-True (Test-Path -LiteralPath (Join-Path $docRoot 'documentation\~$Office.docx')) 'Office lock files are not documentation rename candidates'
    Assert-True ([string]::IsNullOrEmpty((Audit-Path $docRoot).DocumentationNote)) 'Already matching documentation is skipped without redundant output'
    Assert-Equal ([IO.File]::GetLastWriteTimeUtc($newDoc).Ticks) $docTime 'An already matching document keeps its modification time'
    $instructionsOnlyRoot = New-TestHotfix 'Instructions-only documentation' 'select 1 from dual;' @{ 'documentation\hotfix installation instructions for v12c.DOCX' = 'Keep these instructions.' }
    $instructionsOnlyAudit = Audit-Path $instructionsOnlyRoot
    Assert-Equal $instructionsOnlyAudit.ExitCode 0 'Instructions are excluded from rename candidates ignoring case'
    Assert-True ([string]::IsNullOrEmpty($instructionsOnlyAudit.DocumentationNote)) 'An instructions-only folder does not trigger a rename or error'
    $caseDocHotfix = 'V12-023-2-02-HF-ALC-03'
    $caseDocRoot = New-TestHotfix $caseDocHotfix 'select 1 from dual;' @{ ('documentation\' + $caseDocHotfix.ToLowerInvariant() + '.DOCX') = 'Opaque document data.' }
    Assert-Equal (Audit-Path $caseDocRoot).ExitCode 0 'A case-only documentation rename succeeds on Windows'
    Assert-Equal (Get-ChildItem -LiteralPath (Join-Path $caseDocRoot 'documentation') -File).Name ($caseDocHotfix + '.docx') 'Documentation name and extension use the exact target casing'
    $docConflictHotfix = 'V12-023-2-02-HF-ALC-04'
    $docConflictRoot = New-TestHotfix $docConflictHotfix 'select 1 from dual;' @{
        'documentation\old.docx' = 'Preserve the old document.'
        ('documentation\' + $docConflictHotfix + '.docx') = 'Preserve the target document.'
    }
    $docConflictBefore = @(Get-ChildItem -LiteralPath (Join-Path $docConflictRoot 'documentation') -File | Sort-Object Name | ForEach-Object { $_.Name + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join '|'
    $docConflictAudit = Audit-Path $docConflictRoot
    Assert-Equal $docConflictAudit.ExitCode 2 'Multiple documentation candidates are reported without guessing or overwriting'
    Assert-True ($docConflictAudit.DocumentationNote -match 'Multiple DOCX files') 'The documentation ambiguity is explained in the summary'
    Assert-Equal (@(Get-ChildItem -LiteralPath (Join-Path $docConflictRoot 'documentation') -File | Sort-Object Name | ForEach-Object { $_.Name + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join '|') $docConflictBefore 'All conflicting documentation files keep their names and bytes'
    $emptyDocHotfix = 'V12-023-2-02-HF-ALC-05'
    $emptyDocRoot = New-TestHotfix $emptyDocHotfix 'select 1 from dual;' @{ 'documentation\old.docx' = 'placeholder' }
    [IO.File]::WriteAllBytes((Join-Path $emptyDocRoot 'documentation\old.docx'), [byte[]]@())
    $emptyDocAudit = Audit-Path $emptyDocRoot
    Assert-Equal $emptyDocAudit.ExitCode 1 'An empty DOCX remains a zero-byte finding after being renamed'
    Assert-Equal $emptyDocAudit.ZeroByteFiles[0].RelativePath ('documentation\' + $emptyDocHotfix + '.docx') 'Zero-byte output uses the final documentation filename'
    $docDirectoryHotfix = 'V12-023-2-02-HF-ALC-06'
    $docDirectoryRoot = New-TestHotfix $docDirectoryHotfix 'select 1 from dual;' @{ 'documentation\old.docx' = 'Preserve this document.' }
    [void](New-Item -ItemType Directory -Path (Join-Path $docDirectoryRoot ('documentation\' + $docDirectoryHotfix + '.docx')))
    Assert-Equal (Audit-Path $docDirectoryRoot).ExitCode 2 'An existing destination directory cannot be overwritten by a DOCX rename'
    Assert-True (Test-Path -LiteralPath (Join-Path $docDirectoryRoot 'documentation\old.docx') -PathType Leaf) 'A documentation destination conflict preserves the source name'
    $externalDocs = Join-Path $work 'external-documentation'
    [void](New-Item -ItemType Directory -Path $externalDocs)
    $externalDoc = Join-Path $externalDocs 'old.docx'
    Set-Content -LiteralPath $externalDoc -Value 'Preserve the external document.' -Encoding UTF8
    $externalDocHash = (Get-FileHash -LiteralPath $externalDoc -Algorithm SHA256).Hash
    $docLinkRoot = New-TestHotfix 'V12-023-2-02-HF-ALC-08' 'select 1 from dual;' @{}
    [void](New-Item -ItemType Junction -Path (Join-Path $docLinkRoot 'documentation') -Value $externalDocs)
    $docLinkAudit = Audit-Path $docLinkRoot
    Assert-Equal $docLinkAudit.ExitCode 2 'A documentation junction is reported without following it'
    Assert-True (Test-Path -LiteralPath $externalDoc -PathType Leaf) 'A documentation junction cannot rename an external document'
    Assert-Equal (Get-FileHash -LiteralPath $externalDoc -Algorithm SHA256).Hash $externalDocHash 'A documentation junction cannot change external document bytes'
    Assert-True (-not $docLinkAudit.InventoryComplete) 'Skipped directories make the zero-byte inventory incomplete'
    Assert-True ((Get-ZeroByteSummary $docLinkAudit) -match 'could not be fully checked' -and (Get-ZeroByteSummary $docLinkAudit) -notmatch 'were not found') 'An incomplete scan cannot claim no 0KB files were found'

    Write-Host 'Checking named report folders and installer hotfix synchronization.'
    Assert-Equal (Get-ReportTimestamp ([datetime]::new(2026,10,15,16,15,0,[DateTimeKind]::Utc))) '20261015_1215PM' 'Report time uses Toronto local time in the requested date/time format'
    Assert-Equal (Get-ReportTimestamp ([datetime]::new(2026,10,15,4,5,0,[DateTimeKind]::Utc))) '20261015_1205AM' 'Midnight uses the 12-hour AM format'
    Assert-Equal (Get-ReportTimestamp ([datetime]::new(2026,1,15,17,15,0,[DateTimeKind]::Utc))) '20260115_1215PM' 'Report timestamps account for standard time as well as daylight time'
    $namedReportRoot = Join-Path $work 'named-folder-collisions'
    $firstNamed = New-ReportFolder $namedReportRoot '20261015_1215PM' 'V12-020-2-02N-HF-AMI-16'
    $sentinel = Join-Path $firstNamed 'preserve.txt'
    Set-Content -LiteralPath $sentinel -Value 'Existing report.' -Encoding UTF8
    $secondNamed = New-ReportFolder $namedReportRoot '20261015_1215PM' 'V12-020-2-02N-HF-AMI-16'
    Assert-Equal (Split-Path -Leaf $firstNamed) '20261015_1215PM_V12-020-2-02N-HF-AMI-16' 'First report folder exactly follows the requested pattern'
    Assert-Equal (Split-Path -Leaf $secondNamed) '20261015_1215PM_V12-020-2-02N-HF-AMI-16_2' 'A repeated run in the same minute gets a readable collision suffix'
    Assert-Equal (Get-Content -Raw -LiteralPath $sentinel).Trim() 'Existing report.' 'Naming collisions preserve the existing report'

    $installerTemplate = @'
#!/usr/bin/perl
use strict;
use Cwd;
use Config;
use File::Copy;
use File::Path;
use File::Find ();
use File::Basename;
use File::Spec;
use Time::localtime;
use XML::Parser;
use Sys::Hostname;
use Socket;
use Fcntl qw(:DEFAULT :flock);
my $patch = "v12-023-2";
# my $hotfix = "COMMENTED";
my $hotfixes = "OTHER_VARIABLE";
  my  $hotfix = "OLD_HOTFIX_NAME_LONGER_THAN_THE_NEW_ONE_1234567890"; # keep this comment
my $other = "OLD_HOTFIX_NAME_LONGER_THAN_THE_NEW_ONE_1234567890";
'@
    $installerTemplate += "`n# caf" + [char]0x00E9 + "`n"
    foreach ($encodingCase in @(
        @('UTF8', 65001, $false, "`n"), @('UTF8-BOM', 65001, $true, "`r`n"),
        @('Windows1252', 1252, $false, "`r`n"), @('UTF16-LE', 1200, $true, "`r`n"),
        @('UTF16-BE', 1201, $true, "`n"), @('UTF32-LE', 12000, $true, "`n"), @('UTF32-BE', 12001, $true, "`n")
    )) {
        $installerName = 'Installer-' + $encodingCase[0]
        $installerRoot = New-TestHotfix $installerName '@child.sql' @{ 'sql\child.sql' = 'select 1 from dual;' }
        [void](New-Item -ItemType Directory -Path (Join-Path $installerRoot 'v12hotfixinstall'))
        $installerFile = Join-Path $installerRoot 'v12hotfixinstall\v12hotfixinstall.pl'
        $installerEncoding = [Text.Encoding]::GetEncoding($encodingCase[1])
        [byte[]]$preamble = if ($encodingCase[2]) { $installerEncoding.GetPreamble() } else { @() }
        $installerText = [regex]::Replace($installerTemplate, '\r?\n', $encodingCase[3])
        [IO.File]::WriteAllBytes($installerFile, ($preamble + $installerEncoding.GetBytes($installerText)))
        $expectedInstaller = $installerText.Replace('my  $hotfix = "OLD_HOTFIX_NAME_LONGER_THAN_THE_NEW_ONE_1234567890";', ('my  $hotfix = "' + $installerName + '";'))
        $sqlHash = (Get-FileHash -LiteralPath (Join-Path $installerRoot 'sql\master.sql') -Algorithm SHA256).Hash
        $installerAudit = Audit-Path $installerRoot
        Assert-Equal $installerAudit.InstallerStatus 'Updated' ('Installer is updated for ' + $installerName)
        Assert-Equal $installerAudit.ExitCode 0 'A successful installer update does not create a coverage finding'
        Assert-Equal ([Convert]::ToBase64String([IO.File]::ReadAllBytes($installerFile))) ([Convert]::ToBase64String(($preamble + $installerEncoding.GetBytes($expectedInstaller)))) 'Only the active hotfix value changes; BOM, encoding, comments, other variables and line endings are preserved'
        Assert-Equal (Get-FileHash -LiteralPath (Join-Path $installerRoot 'sql\master.sql') -Algorithm SHA256).Hash $sqlHash 'Installer synchronization does not change the SQL master'
        Assert-True ((Get-CoverageSummary $installerAudit) -match 'Installer updated:') 'An actual installer change is recorded in the summary'
        [IO.File]::SetLastWriteTimeUtc($installerFile, [datetime]::new(2020,1,2,3,4,5,[DateTimeKind]::Utc))
        $matchingTime = [IO.File]::GetLastWriteTimeUtc($installerFile)
        $matchingHash = (Get-FileHash -LiteralPath $installerFile -Algorithm SHA256).Hash
        $matchingAudit = Audit-Path $installerRoot
        Assert-Equal $matchingAudit.InstallerStatus 'AlreadyMatches' 'An already matching installer is skipped'
        Assert-Equal ([IO.File]::GetLastWriteTimeUtc($installerFile).Ticks) $matchingTime.Ticks 'A matching installer retains its exact modification time'
        Assert-Equal (Get-FileHash -LiteralPath $installerFile -Algorithm SHA256).Hash $matchingHash 'A matching installer retains its exact bytes'
        Assert-True ([string]::IsNullOrEmpty($matchingAudit.InstallerNote)) 'A matching installer does not add redundant update output'
    }
    $userInstallerText = @'
#!/usr/bin/perl
use strict;
use Cwd;
use Config;
use File::Copy;
use File::Path;
use File::Find ();
use File::Basename;
use File::Spec;
use Time::localtime;
use XML::Parser;
use Sys::Hostname;
use Socket;
use Fcntl qw(:DEFAULT :flock);

# The hotfix number - Edit this value for each hotfix!
# This is also the name of the directory where the hotfix files to be copied are found.
# default value
# not needed to declare
my $patch = "v12-023-2";
my $hotfix = "V12-023-2-02-HF-AMA-01";
my $isCustomHF = 1;
my $standardHotfixHasToBeInstalled = "v12-023-2-hf-02";
my $hotfix_exec_sql_scriptname = $hotfix.".sql";
my @prev_patch_list = ("v12-023-2","V12-023-2");
my @changed_subdirs = qw (forms java jsp jspsql patch reports sql uig web jreports jasper cf);
my $hostname = `hostname`;
# A static audit must never execute the installer body.
die "Installer content must never execute";
'@
    $userHotfix = 'V12-023-2-02-HF-AMA-21'
    $userInstallerRoot = New-TestHotfix ('installer-user-reproduction\' + $userHotfix) 'select 1 from dual;' @{
        'v12hotfixinstall\v12hotfixinstall.pl' = ''
    }
    $userInstallerPath = Join-Path $userInstallerRoot 'v12hotfixinstall\v12hotfixinstall.pl'
    [IO.File]::WriteAllText($userInstallerPath, $userInstallerText, [Text.UTF8Encoding]::new($false))
    $userMasterPath = Join-Path $userInstallerRoot 'sql\master.sql'
    $userMasterHash = (Get-FileHash -LiteralPath $userMasterPath).Hash
    $userInstallerRun = Run-Cli @('-HotfixPath', $userInstallerRoot, '-MasterPath', 'sql\master.sql') 'installer-fcntl-import' $true
    Assert-Equal $userInstallerRun.ExitCode 0 'The real CMD launcher accepts the supplied installer header with its Fcntl qw import'
    $expectedUserInstaller = $userInstallerText.Replace('my $hotfix = "V12-023-2-02-HF-AMA-01";', ('my $hotfix = "' + $userHotfix + '";'))
    Assert-Equal ([Convert]::ToBase64String([IO.File]::ReadAllBytes($userInstallerPath))) ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($expectedUserInstaller))) 'The supplied header changes only the hotfix value, leaving imports, patch settings and installer body byte-identical'
    Assert-Equal (Get-FileHash -LiteralPath $userMasterPath).Hash $userMasterHash 'The supplied installer regression leaves the SQL master unchanged'
    $userInstallerSummary = Get-Content -Raw -LiteralPath $userInstallerRun.SummaryPath
    Assert-True ($userInstallerSummary.Contains('Installer updated:') -and -not $userInstallerSummary.Contains('Installer update failed:')) 'The supplied header produces a successful installer result in the summary'
    Assert-True ((Get-Content -Raw -LiteralPath $userInstallerRun.Log).Contains($userInstallerSummary.TrimEnd())) 'CMD and saved TXT agree on the corrected installer result'
    Assert-Equal (@(Get-ChildItem -LiteralPath (Split-Path -Parent $userInstallerPath) -Force -Filter '.hotfix-checker-*').Count) 0 'The corrected installer update cleans its staging and backup files'
    $userInstallerHash = (Get-FileHash -LiteralPath $userInstallerPath).Hash
    $userInstallerTime = [IO.File]::GetLastWriteTimeUtc($userInstallerPath)
    $userInstallerRerun = Run-Cli @('-HotfixPath', $userInstallerRoot, '-MasterPath', 'sql\master.sql') 'installer-fcntl-import-rerun' $true
    Assert-Equal $userInstallerRerun.ExitCode 0 'The supplied header succeeds again after its hotfix value already matches'
    Assert-Equal (Get-FileHash -LiteralPath $userInstallerPath).Hash $userInstallerHash 'A rerun of the supplied header preserves installer bytes'
    Assert-Equal ([IO.File]::GetLastWriteTimeUtc($userInstallerPath).Ticks) $userInstallerTime.Ticks 'A rerun of the supplied header preserves the installer timestamp'
    Assert-True ((Get-Content -Raw -LiteralPath $userInstallerRerun.SummaryPath) -notmatch 'Installer updated:|Installer update failed:') 'An already matching supplied header emits no redundant installer message'
    foreach ($importCase in @(
        @('Basename', 'use File::Basename qw(dirname basename);'),
        @('Whitespace', "`tuse Fcntl`tqw ( :DEFAULT`t:flock ); # keep comment with 'quotes'"),
        @('Empty', 'use File::Copy qw();'),
        @('Symbols', 'use Some::Module_2 qw(:tag CONSTANT_1 symbol2);')
    )) {
        $importRoot = New-TestHotfix ('Installer-import-' + $importCase[0]) 'select 1 from dual;' @{
            'v12hotfixinstall\v12hotfixinstall.pl' = ($importCase[1] + "`n" + 'my $hotfix = "OLD";')
        }
        $importPath = Join-Path $importRoot 'v12hotfixinstall\v12hotfixinstall.pl'
        $importOriginal = [IO.File]::ReadAllText($importPath)
        Assert-Equal (Audit-Path $importRoot).InstallerStatus 'Updated' 'Complete one-line literal import lists are safe to skip'
        Assert-Equal ([IO.File]::ReadAllText($importPath)) ($importOriginal.Replace('my $hotfix = "OLD";', ('my $hotfix = "Installer-import-' + $importCase[0] + '";'))) 'Literal import contents and comments are preserved exactly'
        Assert-Equal (Audit-Path $importRoot).InstallerStatus 'AlreadyMatches' 'Literal import support preserves no-op behavior'
    }
    foreach ($badInstaller in @(
        @('Missing-assignment', 'my $different = "OLD";'),
        @('Duplicate-assignment', ('my $hotfix = "ONE";' + "`n" + 'my $hotfix = "TWO";')),
        @('POD-only', "=pod`nmy `$hotfix = `"EXAMPLE`";`n=cut`n"),
        @('DATA-only', "__DATA__`nmy `$hotfix = `"EXAMPLE`";`n"),
        @('END-only', "__END__`nmy `$hotfix = `"EXAMPLE`";`n"),
        @('String-only', "my `$example = `"text`nmy `$hotfix = 'EXAMPLE';`ntext`";`n"),
        @('Backticks-only', "my `$example = ``text`nmy `$hotfix = 'EXAMPLE';`ntext``;`n"),
        @('Heredoc-only', "print <<'EXAMPLE';`nmy `$hotfix = `"EXAMPLE`";`nEXAMPLE`n"),
        @('Quote-operator', "my `$example = q{`nmy `$hotfix = `"EXAMPLE`";`n};`n"),
        @('Quote-word-delimiter', "my `$example = q X`nmy `$hotfix = `"EXAMPLE`";`nX;`n"),
        @('Quote-nextline-delimiter', "my `$example = q`n{`nmy `$hotfix = `"EXAMPLE`";`n};`n"),
        @('Import-multiline-example', "use Fcntl qw(`nmy `$hotfix = `"EXAMPLE`";`n);`n"),
        @('Import-trailing-code', "use Fcntl qw(:DEFAULT :flock); my `$example = q{`nmy `$hotfix = `"EXAMPLE`";`n};`n"),
        @('Import-unclosed-list', "use Fcntl qw(:DEFAULT :flock;`nmy `$hotfix = `"EXAMPLE`";`n"),
        @('Regex-operator', "my `$example = m{`nmy `$hotfix = `"EXAMPLE`";`n};`n"),
        @('Regex-literal', "my `$example = /`nmy `$hotfix = `"EXAMPLE`";`n/;`n"),
        @('Format', "format STDOUT =`nmy `$hotfix = `"EXAMPLE`";`n.`n")
    )) {
        $badInstallerRoot = New-TestHotfix ('Installer-' + $badInstaller[0]) 'select 1 from dual;' @{ 'v12hotfixinstall\v12hotfixinstall.pl' = $badInstaller[1] }
        $badInstallerPath = Join-Path $badInstallerRoot 'v12hotfixinstall\v12hotfixinstall.pl'
        $badInstallerHash = (Get-FileHash -LiteralPath $badInstallerPath -Algorithm SHA256).Hash
        $badInstallerAudit = Audit-Path $badInstallerRoot
        Assert-Equal $badInstallerAudit.InstallerStatus 'Failed' 'An ambiguous or missing assignment is reported without guessing'
        Assert-Equal $badInstallerAudit.ExitCode 2 'An installer update failure makes the run incomplete'
        Assert-Equal (Get-FileHash -LiteralPath $badInstallerPath -Algorithm SHA256).Hash $badInstallerHash 'Rejected installer content is never rewritten'
        if ($badInstaller[0] -eq 'Import-multiline-example') {
            Assert-True ($badInstallerAudit.InstallerNote -match 'line 1, column 11') 'Unsupported installer syntax identifies its exact source line and column'
        }
    }
    foreach ($context in @(
        @('POD', "=pod`nmy `$hotfix = `"EXAMPLE`";`n=cut`n", ''),
        @('Multiline-string', "my `$example = `"text`nmy `$hotfix = 'EXAMPLE';`ntext`";`n", ''),
        @('DATA', '', "`n__DATA__`nmy `$hotfix = `"EXAMPLE`";`n"),
        @('END', '', "`n__END__`nmy `$hotfix = `"EXAMPLE`";`n"),
        @('CR-only', "# header`r", "`r# footer")
    )) {
        $contextName = 'Installer-context-' + $context[0]
        $contextText = $context[1] + 'my $hotfix = "OLD";' + $context[2]
        $contextRoot = New-TestHotfix $contextName 'select 1 from dual;' @{ 'v12hotfixinstall\v12hotfixinstall.pl' = $contextText }
        $contextFile = Join-Path $contextRoot 'v12hotfixinstall\v12hotfixinstall.pl'
        $contextOriginal = [IO.File]::ReadAllText($contextFile)
        $contextAudit = Audit-Path $contextRoot
        Assert-Equal $contextAudit.InstallerStatus 'Updated' 'An unambiguous active assignment can be updated around comments, strings or data sections'
        Assert-Equal ([IO.File]::ReadAllText($contextFile)) ($contextOriginal.Replace('my $hotfix = "OLD";', ('my $hotfix = "' + $contextName + '";'))) 'Embedded examples and all surrounding text retain their exact contents'
        Assert-Equal (Audit-Path $contextRoot).InstallerStatus 'AlreadyMatches' 'Context-aware installer editing remains idempotent'
    }
    $quotedRoot = New-TestHotfix 'Installer-quote''s-$x-@y' 'select 1 from dual;' @{ 'v12hotfixinstall\v12hotfixinstall.pl' = 'my $hotfix = ''OLD\''QUOTE'';' }
    $quotedFile = Join-Path $quotedRoot 'v12hotfixinstall\v12hotfixinstall.pl'
    Assert-Equal (Audit-Path $quotedRoot).InstallerStatus 'Updated' 'Escaped quotes in a single-quoted installer value are recognized'
    Assert-Equal ([IO.File]::ReadAllText($quotedFile).Trim()) 'my $hotfix = ''Installer-quote\''s-$x-@y'';' 'The replacement preserves literal Perl metacharacters and escapes the delimiter'
    Assert-Equal (Audit-Path $quotedRoot).InstallerStatus 'AlreadyMatches' 'Escaped values are recognized on subsequent runs'
    [IO.File]::WriteAllText($quotedFile, 'my $hotfix = "OLD\"QUOTE";')
    Assert-Equal (Audit-Path $quotedRoot).InstallerStatus 'Updated' 'Escaped quotes in a double-quoted installer value are recognized'
    Assert-Equal ([IO.File]::ReadAllText($quotedFile)) 'my $hotfix = "Installer-quote''s-\$x-\@y";' 'Double-quoted replacement escapes Perl interpolation characters'
    Assert-Equal (Audit-Path $quotedRoot).InstallerStatus 'AlreadyMatches' 'Escaped double-quoted values remain idempotent'

    $storedName = 'V12-023-2-02-HF-MiXeD-21'
    $storedRoot = New-TestHotfix $storedName 'select 1 from dual;' @{
        'v12hotfixinstall\v12hotfixinstall.pl' = 'my $hotfix = "OLD";'
        'sql\V12-old.last.perl' = 'hook bytes'
        'documentation\V12-old.docx' = 'document bytes'
    }
    $lowerRoot = $storedRoot.ToLowerInvariant()
    Assert-Equal (Get-HotfixName $lowerRoot) $storedName 'Hotfix naming uses the filesystem spelling instead of the caller path casing'
    $storedAudit = Audit-Path $lowerRoot
    Assert-Equal $storedAudit.InstallerStatus 'Updated' 'An installer can be synchronized through a differently cased root path'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $storedRoot 'v12hotfixinstall\v12hotfixinstall.pl')).Trim()) ('my $hotfix = "' + $storedName + '";') 'Installer uses the stored hotfix name'
    Assert-Equal (@(Get-ChildItem -LiteralPath (Join-Path $storedRoot 'sql') -Filter '*.perl')[0].Name) ($storedName + '.last.perl') 'Hook rename uses the stored folder spelling'
    Assert-Equal (@(Get-ChildItem -LiteralPath (Join-Path $storedRoot 'documentation') -Filter '*.docx')[0].Name) ($storedName + '.docx') 'Documentation rename uses the stored folder spelling'

    $lockedRoot = New-TestHotfix 'Installer-locked' 'select 1 from dual;' @{ 'v12hotfixinstall\v12hotfixinstall.pl' = 'my $hotfix = "OLD";' }
    $lockedFile = Join-Path $lockedRoot 'v12hotfixinstall\v12hotfixinstall.pl'
    $lockedHash = (Get-FileHash -LiteralPath $lockedFile).Hash
    $lockStream = [IO.File]::Open($lockedFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $lockedAudit = Audit-Path $lockedRoot
        Assert-Equal $lockedAudit.InstallerStatus 'Failed' 'A sharing conflict prevents replacing the installer'
        Assert-Equal $lockedAudit.ExitCode 2 'A blocked installer replacement is reported as incomplete'
        Assert-Equal (Get-FileHash -LiteralPath $lockedFile).Hash $lockedHash 'A failed replacement preserves the complete original installer'
        Assert-Equal (@(Get-ChildItem -LiteralPath (Split-Path -Parent $lockedFile) -Force -Filter '.hotfix-checker-*').Count) 0 'Failed replacement removes the staged file'
    } finally { $lockStream.Dispose() }
    Assert-Equal (Audit-Path $lockedRoot).InstallerStatus 'Updated' 'An installer can be retried after the competing file handle closes'
    Assert-Equal (@(Get-ChildItem -LiteralPath (Split-Path -Parent $lockedFile) -Force -Filter '.hotfix-checker-*').Count) 0 'Successful replacement leaves no staged files'

    $recoveryRoot = New-TestHotfix 'Installer-recovery' 'select 1 from dual;' @{ 'v12hotfixinstall\v12hotfixinstall.pl' = 'my $hotfix = "OLD";' }
    $recoveryFile = Join-Path $recoveryRoot 'v12hotfixinstall\v12hotfixinstall.pl'
    $recoveryHash = (Get-FileHash -LiteralPath $recoveryFile).Hash
    $replaceImplementation = ${function:Complete-InstallerReplacement}
    try {
        # Fault injection models the documented Windows partial-replacement
        # failure: original moved to backup, replacement not yet moved in.
        function Complete-InstallerReplacement([string]$Temporary, [string]$Destination, [string]$Backup) {
            [IO.File]::Move($Destination, $Backup)
            throw 'Simulated replacement failure after moving the original.'
        }
        $recoveryAudit = Audit-Path $recoveryRoot
        Assert-Equal $recoveryAudit.InstallerStatus 'Failed' 'A partial filesystem replacement is explicitly reported as failed'
        Assert-Equal $recoveryAudit.ExitCode 2 'A partial replacement cannot be reported as a successful audit'
        Assert-True (-not (Test-Path -LiteralPath $recoveryFile)) 'The failure simulation reached the missing-original-path state'
        $recoveryFolder = Split-Path -Parent $recoveryFile
        $savedOriginal = @(Get-ChildItem -LiteralPath $recoveryFolder -Force -Filter '.hotfix-checker-*.bak')
        $savedReplacement = @(Get-ChildItem -LiteralPath $recoveryFolder -Force -Filter '.hotfix-checker-*.tmp')
        Assert-Equal $savedOriginal.Count 1 'A partial replacement retains the original backup'
        Assert-Equal $savedReplacement.Count 1 'A partial replacement retains the prepared replacement'
        Assert-Equal (Get-FileHash -LiteralPath $savedOriginal[0].FullName).Hash $recoveryHash 'Recovery preserves every byte of the original installer'
        Assert-Equal ([IO.File]::ReadAllText($savedReplacement[0].FullName).Trim()) 'my $hotfix = "Installer-recovery";' 'The complete prepared installer is also recoverable'
        Assert-True ($recoveryAudit.InstallerNote.Contains($savedOriginal[0].FullName) -and $recoveryAudit.InstallerNote.Contains($savedReplacement[0].FullName)) 'The failure summary identifies both recovery paths'
        Assert-True ((Get-CoverageSummary $recoveryAudit).Contains('Recovery files were preserved')) 'Recovery instructions reach the normal user summary'
    } finally { ${function:Complete-InstallerReplacement} = $replaceImplementation }
    $matchingAttributes = [IO.File]::GetAttributes($installerFile)
    try {
        [IO.File]::SetAttributes($installerFile, ($matchingAttributes -bor [IO.FileAttributes]::ReadOnly))
        Assert-Equal (Audit-Path $installerRoot).InstallerStatus 'AlreadyMatches' 'An already matching read-only installer does not need write access'
    } finally { [IO.File]::SetAttributes($installerFile, $matchingAttributes) }
    $readOnlyRoot = New-TestHotfix 'Installer-readonly-mismatch' 'select 1 from dual;' @{ 'v12hotfixinstall\v12hotfixinstall.pl' = 'my $hotfix = "OLD";' }
    $readOnlyFile = Join-Path $readOnlyRoot 'v12hotfixinstall\v12hotfixinstall.pl'
    $readOnlyHash = (Get-FileHash -LiteralPath $readOnlyFile -Algorithm SHA256).Hash
    $readOnlyAttributes = [IO.File]::GetAttributes($readOnlyFile)
    try {
        [IO.File]::SetAttributes($readOnlyFile, ($readOnlyAttributes -bor [IO.FileAttributes]::ReadOnly))
        $readOnlyAudit = Audit-Path $readOnlyRoot
        Assert-Equal $readOnlyAudit.ExitCode 2 'An installer that needs an edit but cannot be written makes the run incomplete'
        Assert-Equal $readOnlyAudit.InstallerStatus 'Failed' 'An installer write failure is explicitly recorded'
        Assert-Equal (Get-FileHash -LiteralPath $readOnlyFile -Algorithm SHA256).Hash $readOnlyHash 'A rejected installer write preserves the source bytes'
    } finally { [IO.File]::SetAttributes($readOnlyFile, $readOnlyAttributes) }
    $installerLinkTarget = Join-Path $work 'installer-link-target'
    [void](New-Item -ItemType Directory -Path $installerLinkTarget)
    $linkedInstaller = Join-Path $installerLinkTarget 'v12hotfixinstall.pl'
    Set-Content -LiteralPath $linkedInstaller -Value 'my $hotfix = "OLD";' -Encoding UTF8
    $linkedInstallerHash = (Get-FileHash -LiteralPath $linkedInstaller -Algorithm SHA256).Hash
    $installerLinkRoot = New-TestHotfix 'Installer-junction' 'select 1 from dual;' @{}
    [void](New-Item -ItemType Junction -Path (Join-Path $installerLinkRoot 'v12hotfixinstall') -Value $installerLinkTarget)
    Assert-Equal (Audit-Path $installerLinkRoot).InstallerStatus 'Failed' 'The updater rejects a junction in the installer path'
    Assert-Equal (Get-FileHash -LiteralPath $linkedInstaller -Algorithm SHA256).Hash $linkedInstallerHash 'A linked installer outside the hotfix is never edited'
    $installerHardlinkRoot = New-TestHotfix 'Installer-hardlink' 'select 1 from dual;' @{}
    [void](New-Item -ItemType Directory -Path (Join-Path $installerHardlinkRoot 'v12hotfixinstall'))
    [void](New-Item -ItemType HardLink -Path (Join-Path $installerHardlinkRoot 'v12hotfixinstall\v12hotfixinstall.pl') -Value $linkedInstaller)
    Assert-Equal (Audit-Path $installerHardlinkRoot).InstallerStatus 'Failed' 'The updater refuses to write through an installer hardlink'
    Assert-Equal (Get-FileHash -LiteralPath $linkedInstaller -Algorithm SHA256).Hash $linkedInstallerHash 'An installer hardlink cannot change another file'

    Write-Host 'Checking hotfix Perl/undeploy filenames before the audit inventory.'
    $renameHotfix = 'V12-023-2-02-HF-AMA-21'
    $oldHookPrefix = 'v12-023-2-02-hf-ama-01'
    $hookSuffixes = @('aftercopy.perl', 'beforecopy.perl', 'beforedeploy.perl', 'last.perl', 'undeploy')
    $hookFiles = @{
        'sql\payload.pb' = 'select 1 from dual;'
        ('sql\' + $oldHookPrefix + '.aftercopy.perl.bak') = '# A backup, not a hook.'
        ('sql\' + $oldHookPrefix + '.aftercopy.pl') = '# Different extension.'
        ('sql\' + $oldHookPrefix + '.first.perl') = '# Different suffix.'
        ('sql\sub\' + $oldHookPrefix + '.aftercopy.perl') = '# Nested file; keep its name.'
        'sql\generic.aftercopy.perl' = '# Not a V12 hotfix prefix.'
        'sql\v11-old.aftercopy.perl' = '# Different hotfix prefix.'
    }
    foreach ($suffix in $hookSuffixes) { $hookFiles['sql\' + $oldHookPrefix + '.' + $suffix] = '# Opaque hook data for ' + $suffix }
    $hookMaster = "@payload.pb`n@" + $oldHookPrefix + ".aftercopy.perl.bak`n" + (($hookSuffixes | ForEach-Object { 'START ' + $renameHotfix + '.' + $_ }) -join "`n")
    $renameRoot = New-TestHotfix $renameHotfix $hookMaster $hookFiles
    $hookHashes = @{}; $hookTimes = @{}
    foreach ($suffix in $hookSuffixes) {
        $sourceHook = Join-Path $renameRoot ('sql\' + $oldHookPrefix + '.' + $suffix)
        $hookHashes[$suffix] = (Get-FileHash -LiteralPath $sourceHook -Algorithm SHA256).Hash
        $hookTimes[$suffix] = [IO.File]::GetLastWriteTimeUtc($sourceHook).Ticks
    }
    $renameMasterHash = (Get-FileHash -LiteralPath (Join-Path $renameRoot 'sql\master.sql') -Algorithm SHA256).Hash
    $renameAudit = Audit-Path $renameRoot
    Assert-Equal $renameAudit.ExitCode 0 'The audit checks master calls against the newly renamed files'
    Assert-Equal $renameAudit.ScriptRenameNotes.Count 5 'All five supplied hook suffixes are renamed'
    Assert-Equal $renameAudit.Counts['Required calls missing files'] 0 'The inventory uses final hook names without stale missing targets'
    foreach ($suffix in $hookSuffixes) {
        $renamedHook = Join-Path $renameRoot ('sql\' + $renameHotfix + '.' + $suffix)
        Assert-True (Test-Path -LiteralPath $renamedHook -PathType Leaf) ('Hook now matches hotfix name: ' + $suffix)
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $renameRoot ('sql\' + $oldHookPrefix + '.' + $suffix)))) 'The previous hook name no longer exists'
        Assert-Equal (Get-FileHash -LiteralPath $renamedHook -Algorithm SHA256).Hash $hookHashes[$suffix] 'Renaming preserves the exact hook file bytes'
        Assert-Equal ([IO.File]::GetLastWriteTimeUtc($renamedHook).Ticks) $hookTimes[$suffix] 'Renaming preserves the hook modification time'
    }
    foreach ($keepName in @(
        ('sql\' + $oldHookPrefix + '.aftercopy.perl.bak'), ('sql\' + $oldHookPrefix + '.aftercopy.pl'),
        ('sql\' + $oldHookPrefix + '.first.perl'), ('sql\sub\' + $oldHookPrefix + '.aftercopy.perl'),
        'sql\generic.aftercopy.perl', 'sql\v11-old.aftercopy.perl'
    )) { Assert-True (Test-Path -LiteralPath (Join-Path $renameRoot $keepName) -PathType Leaf) 'Other prefixes, suffixes, extensions, backups and nested names remain unchanged' }
    Assert-Equal (Get-FileHash -LiteralPath (Join-Path $renameRoot 'sql\master.sql') -Algorithm SHA256).Hash $renameMasterHash 'Hook renaming does not rewrite master calls or SQL contents'
    Assert-True ((Get-CoverageSummary $renameAudit) -match 'Script renamed: sql\\v12-023-2-02-hf-ama-01.aftercopy.perl -> sql\\V12-023-2-02-HF-AMA-21.aftercopy.perl') 'The summary records actual source and destination names'
    Assert-Equal (Audit-Path $renameRoot).ScriptRenameNotes.Count 0 'An already matching hook name is skipped without redundant output'

    $caseHotfix = 'V12-023-2-02-HF-AMA-22'
    $caseFiles = @{}
    foreach ($suffix in $hookSuffixes) { $caseFiles['sql\' + $caseHotfix.ToLowerInvariant() + '.' + $suffix.ToUpperInvariant()] = '# Case-only rename.' }
    $caseRoot = New-TestHotfix $caseHotfix 'select 1 from dual;' $caseFiles
    $caseAudit = Audit-Path $caseRoot
    Assert-Equal $caseAudit.ExitCode 0 'Case-only renames work in Windows PowerShell 5.1'
    foreach ($suffix in $hookSuffixes) {
        $actualHook = Get-ChildItem -LiteralPath (Join-Path $caseRoot 'sql') -File | Where-Object { $_.Name -ieq ($caseHotfix + '.' + $suffix) }
        Assert-Equal $actualHook.Name ($caseHotfix + '.' + $suffix) 'Hook prefix and suffix casing exactly match the target'
    }
    Assert-Equal (Audit-Path $caseRoot).ScriptRenameNotes.Count 0 'Case-normalized hooks need no second rename'

    $conflictHotfix = 'V12-023-2-02-HF-AMA-23'
    $conflictRoot = New-TestHotfix $conflictHotfix 'select 1 from dual;' @{
        ('sql\' + $oldHookPrefix + '.aftercopy.perl') = '# Keep the old file.'
        ('sql\' + $conflictHotfix + '.aftercopy.perl') = '# Keep the existing target.'
        ('sql\' + $oldHookPrefix + '.beforecopy.perl') = '# This unambiguous suffix can still be renamed.'
    }
    $conflictPaths = @((Join-Path $conflictRoot ('sql\' + $oldHookPrefix + '.aftercopy.perl')), (Join-Path $conflictRoot ('sql\' + $conflictHotfix + '.aftercopy.perl')))
    $conflictHashes = @($conflictPaths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }) -join ','
    $conflictAudit = Audit-Path $conflictRoot
    Assert-Equal $conflictAudit.ExitCode 2 'A duplicate suffix is reported as incomplete instead of choosing or overwriting a file'
    Assert-Equal (@($conflictPaths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }) -join ',') $conflictHashes 'Conflicting source and destination files retain their bytes'
    Assert-True ((Get-CoverageSummary $conflictAudit) -match 'Script rename failed.*Multiple matching files') 'The summary explains a rename conflict'
    Assert-True (Test-Path -LiteralPath (Join-Path $conflictRoot ('sql\' + $conflictHotfix + '.beforecopy.perl'))) 'An unrelated unambiguous suffix is still renamed'
    $directoryHotfix = 'V12-023-2-02-HF-AMA-24'
    $directoryRoot = New-TestHotfix $directoryHotfix 'select 1 from dual;' @{ ('sql\' + $oldHookPrefix + '.undeploy') = '# Keep this file.' }
    [void](New-Item -ItemType Directory -Path (Join-Path $directoryRoot ('sql\' + $directoryHotfix + '.undeploy')))
    Assert-Equal (Audit-Path $directoryRoot).ExitCode 2 'An existing destination directory cannot be overwritten by a hook file'
    Assert-True (Test-Path -LiteralPath (Join-Path $directoryRoot ('sql\' + $oldHookPrefix + '.undeploy')) -PathType Leaf) 'A destination directory conflict preserves the source name'
    $externalHookRoot = Join-Path $work 'external-hook-sql'
    [void](New-Item -ItemType Directory -Path $externalHookRoot)
    $externalHook = Join-Path $externalHookRoot ($oldHookPrefix + '.last.perl')
    Set-Content -LiteralPath $externalHook -Value '# Keep the external hook name and bytes.' -Encoding UTF8
    $externalHookHash = (Get-FileHash -LiteralPath $externalHook -Algorithm SHA256).Hash
    $hookLinkRoot = Join-Path $work 'V12-023-2-02-HF-AMA-26'
    $hookLinkWorking = Join-Path $hookLinkRoot 'manual'
    [void](New-Item -ItemType Directory -Path $hookLinkWorking)
    $hookLinkMaster = Join-Path $hookLinkWorking 'master.sql'
    Set-Content -LiteralPath $hookLinkMaster -Value 'select 1 from dual;' -Encoding UTF8
    [void](New-Item -ItemType Junction -Path (Join-Path $hookLinkRoot 'sql') -Value $externalHookRoot)
    $hookLinkAudit = New-Audit $hookLinkRoot $hookLinkMaster $hookLinkWorking $false
    Invoke-Audit $hookLinkAudit
    Assert-Equal $hookLinkAudit.ExitCode 2 'A sql junction is reported without renaming files through it'
    Assert-True (Test-Path -LiteralPath $externalHook -PathType Leaf) 'A sql junction cannot rename a hook outside the selected hotfix'
    Assert-Equal (Get-FileHash -LiteralPath $externalHook -Algorithm SHA256).Hash $externalHookHash 'A sql junction cannot change external hook bytes'

    $expected = @(Import-Csv -LiteralPath (Join-Path $testRoot 'expected-hotfix-one.csv'))
    foreach ($nested in @($false, $true)) {
        $audit = Audit-Fixture 'Hotfix one' $nested
        Assert-Equal $audit.Files.Count 36 'All files inventoried'
        Assert-Equal @($audit.Files | Where-Object { $_.Excluded }).Count 8 'Configured excluded extensions, mixed case'
        Assert-Equal $audit.Rows.Count 27 'Master excluded, every other eligible file retained'
        Assert-Equal $audit.ExitCode 2 'Unresolved variable makes the audit incomplete'
        Assert-Equal $audit.Issues.Count $(if ($nested) { 1 } else { 0 }) 'Nested ambiguous copies are not read by guessing their location'
        foreach ($e in $expected) {
            $row = Row $audit $e.RelativeFilePath
            Assert-Equal $row.DirectReferenceStatus $e.DirectReferenceStatus "Direct status: $($e.RelativeFilePath)"
            Assert-Equal $row.DirectCallCount $e.DirectCallCount "Direct call count: $($e.RelativeFilePath)"
            Assert-Equal $row.IndirectReferenceStatus $(if ($nested) { $e.NestedIndirectReferenceStatus } else { 'NotChecked' }) "Nested status: $($e.RelativeFilePath)"
            Assert-Equal $row.IndirectCallCount $(if ($nested) { $e.NestedIndirectCallCount } else { 0 }) "Indirect count: $($e.RelativeFilePath)"
            $method = if (-not $nested -and $e.DirectCallCount -eq '0') { '' } else { $e.MatchingMethod }
            Assert-Equal $row.MatchingMethod $method "Matching method: $($e.RelativeFilePath)"
            Assert-Equal $row.AuditStatus 'Incomplete' 'CSV rows signal provisional coverage'
        }
        Assert-Equal @($audit.References | Where-Object { $_.Status -eq 'Ambiguous' }).Count 0 'Direct bare filenames cover exact copies across hotfix folders'
        Assert-Equal @($audit.References | Where-Object { $_.Status -eq 'MissingInHotfix' }).Count 2 'Wrong explicit path and missing call both reported'
        Assert-Equal @($audit.References | Where-Object { $_.Target -eq 'wrong\py_post.pb' -and $_.Status -eq 'MissingInHotfix' }).Count 1 'Wrong path cannot use basename fallback'
        Assert-Equal @($audit.References | Where-Object { $_.LineNumber -eq 18 -and $_.Target -eq 'py_post.pb' }).Count 1 'Original source line retained'
        $quoted = @($audit.References | Where-Object { $_.Target -eq 'subfolder\script with spaces.pb' })[0]
        Assert-Equal $quoted.Arguments 'argument1 "argument two"' 'Arguments are separate from quoted target'
        Assert-True ((Row $audit 'docs\unique.DATA').Notes -match 'runtime SQL\*Plus lookup is not established') 'Unique filename caveat appears in CSV'
        Assert-Equal @($audit.References | Where-Object { $_.Cycle }).Count $(if ($nested) { 1 } else { 0 }) 'Cycle detection stops recursion'
        Assert-Equal $audit.Repeated.Count $(if ($nested) { 4 } else { 3 }) 'Repeated static calls grouped per matching hotfix file'
        Assert-Equal @($audit.References | Where-Object { $_.SourceFile -like '*unrelated.sql' }).Count 0 'Unrelated scripts never contribute coverage'
        if ($nested) {
            $indirect = Row $audit 'sql\subfolder\indirect.sql'
            Assert-True ($indirect.CallChains -match 'master.sql:22 -> sql\\subfolder\\post_install.sql:1') 'Indirect chain contains master and caller lines'
            Assert-True ((Get-Summary $audit) -match 'Files not directly referenced: 11') 'Indirectly called file remains in not-direct total'
        }
    }
    Assert-Equal (Audit-Fixture 'Clean').ExitCode 0 'Clean fixture exit zero'
    Assert-Equal (Audit-Fixture 'Clean' $true).ExitCode 0 'Clean nested audit exit zero'
    $second = Audit-Fixture 'Hotfix two'
    Assert-Equal $second.ExitCode 1 'Completed fixture with findings exit one'
    Assert-Equal $second.References[0].Status 'MissingInHotfix' 'Another hotfix cannot satisfy a missing call'

    Write-Host 'Checking master calls against the hotfix inventory and allowed missing targets.'
    Assert-Equal $script:AllowedMissingCallTargets.Count 93 'All supplied exception entries are included'
    $allowedMaster = ($script:AllowedMissingCallTargets | ForEach-Object { 'START ' + $_.ToUpperInvariant() }) -join "`n"
    $allowedRoot = New-TestHotfix 'Allowed missing targets' $allowedMaster @{}
    $allowedAudit = Audit-Path $allowedRoot
    Assert-Equal $allowedAudit.ExitCode 0 'A hotfix containing only allowed missing calls has no findings'
    Assert-Equal $allowedAudit.Counts['Allowed missing calls ignored'] 93 'Every supplied exception is recognized ignoring case'
    Assert-Equal $allowedAudit.Counts['Required calls missing files'] 0 'Allowed absences are not required missing files'
    Assert-Equal $allowedAudit.Counts['Calls with files present'] 0 'Ignored absences are never counted as present'
    Assert-Equal $allowedAudit.Rows.Count 0 'Ignored calls do not create imaginary inventory files'
    Assert-True ((Get-CoverageSummary $allowedAudit) -match 'File presence result: YES') 'Allowed missing calls permit a successful presence result'
    Assert-True ((Get-CoverageSummary $allowedAudit) -notmatch 'Ignored missing calls \(allowed list\)|dbdefine\.sql|ptfcompx|invalidobjects\.sql') 'Allowed missing calls stay out of the normal summary filename output'

    $presenceRoot = New-TestHotfix 'Master file presence' @'
-- start commented_missing.sql
PROMPT start output_missing.sql
select 'start literal_missing.sql' from dual;
START "payload.pb" argument1
@payload.pb
@@sub\leaf.pb
start DBDEFINE.SQL argument2
@ptfcompx
@@missing\SYS#OPT.VW
start ..\..\outside\dbk_patch_flag.pb
start missing_required.pb
@@wrong\payload.pb
START excluded_missing.txt
start support.txt
'@ @{
        'sql\payload.pb' = 'select 1 from dual;'; 'other\payload.pb' = 'select 2 from dual;'
        'sql\sub\leaf.pb' = 'select 3 from dual;'; 'docs\support.txt' = 'Readme only.'
    }
    $presenceAudit = Audit-Path $presenceRoot
    Assert-Equal $presenceAudit.Counts['Master calls checked'] 11 'Each active call line counts once despite multiple matching copies'
    Assert-Equal $presenceAudit.Counts['Calls with files present'] 4 'Quoted, repeated, caller-relative and excluded-extension files can be present'
    Assert-Equal $presenceAudit.Counts['Allowed missing calls ignored'] 4 'START, @, @@, default suffixes and explicit paths use the exception list'
    Assert-Equal $presenceAudit.Counts['Required calls missing files'] 3 'Missing bare, wrong explicit path and excluded-extension targets are reported'
    Assert-Equal $presenceAudit.Counts['Master calls requiring review'] 0 'Literal calls are fully classified'
    Assert-Equal @($presenceAudit.MasterCalls | Where-Object { $_.Target -match 'commented_missing|output_missing|literal_missing' }).Count 0 'Comments, output and SQL literals never become missing calls'
    Assert-Equal $presenceAudit.Counts['Files not directly referenced'] 0 'Missing targets do not change successful folder-to-master coverage'
    $presenceSummary = Get-CoverageSummary $presenceAudit
    Assert-True ($presenceSummary -match '(?s)Files with no matching call in the master.*Master call file check') 'Presence section follows the existing coverage section'
    Assert-True ($presenceSummary -match 'missing_required.pb \(line 11\)' -and $presenceSummary -match 'wrong\\payload.pb \(line 12\)') 'Missing files include their exact master line numbers'

    $allowedPresentRoot = New-TestHotfix 'Allowed target supplied' '@DBDEFINE.SQL' @{ 'docs\dbdefine.sql' = 'select 1 from dual;' }
    $allowedPresent = Audit-Path $allowedPresentRoot
    Assert-Equal $allowedPresent.Counts['Calls with files present'] 1 'An allowed target actually supplied is counted as present'
    Assert-Equal $allowedPresent.Counts['Allowed missing calls ignored'] 0 'Present exception files are not classified as missing'
    Assert-Equal (Row $allowedPresent 'docs\dbdefine.sql').DirectCallCount 1 'Supplied exception files retain normal call coverage'
    $allowedUncalledRoot = New-TestHotfix 'Allowed target uncalled' 'select 1 from dual;' @{ 'sql\dbdefine.sql' = 'select 2 from dual;' }
    Assert-Equal (Audit-Path $allowedUncalledRoot).Counts['Files not directly referenced'] 1 'The missing-call exception list never exempts an uncalled file'
    $allowedLookalikeRoot = New-TestHotfix 'Allowed target lookalikes' "@old_dbdefine.sql`n@dbdefine.sql.bak`n@dbdefine.ps" @{}
    Assert-Equal (Audit-Path $allowedLookalikeRoot).Counts['Required calls missing files'] 3 'Only whole filenames with the exact extension qualify for an exception'
    $allowedDynamicRoot = New-TestHotfix 'Allowed target dynamic' "@&dir/dbdefine.sql`nSET SUFFIX pb`n@ptfcompx" @{}
    $allowedDynamic = Audit-Path $allowedDynamicRoot
    Assert-Equal $allowedDynamic.Counts['Allowed missing calls ignored'] 0 'Variables and unknown suffixes cannot acquire an exception'
    Assert-Equal $allowedDynamic.Counts['Master calls requiring review'] 2 'Uncertain targets remain visible for review'
    Assert-True ((Get-MasterCallSummary $allowedDynamic) -match 'File presence result: INCOMPLETE') 'Uncertain targets cannot produce a successful presence result'
    $allowedUrlRoot = New-TestHotfix 'Allowed filename in URL' '@https://example.invalid/dbdefine.sql' @{}
    Assert-Equal (Audit-Path $allowedUrlRoot).Counts['Required calls missing files'] 1 'External URLs cannot acquire a filesystem filename exception'
    $ambiguousPresenceRoot = New-TestHotfix 'Ambiguous master target' '@@duplicate.sql' @{
        'one\duplicate.sql' = 'select 1 from dual;'; 'two\duplicate.sql' = 'select 2 from dual;'
    }
    $ambiguousPresence = Audit-Path $ambiguousPresenceRoot
    Assert-Equal $ambiguousPresence.Counts['Master calls requiring review'] 1 'An ambiguous caller-relative target remains visible for review'
    Assert-Equal $ambiguousPresence.ExitCode 2 'A presence review cannot produce a completed audit exit code'
    $allowedNestedRoot = New-TestHotfix 'Nested target scope' '@child.sql' @{ 'sql\child.sql' = '@dbdefine.sql' }
    $allowedNested = Audit-Path $allowedNestedRoot $true
    Assert-Equal $allowedNested.MasterCalls.Count 1 'The new check covers calls in the selected master only'
    Assert-Equal @($allowedNested.References | Where-Object { -not $_.Direct -and $_.Status -eq 'MissingInHotfix' }).Count 1 'Master exceptions do not conceal missing nested calls in detailed reports'

    $settingsDirect = Audit-Fixture 'Settings'
    Assert-Equal (Row $settingsDirect 'sql\default_name.sql').DirectReferenceStatus 'DirectlyReferenced' 'Direct mode uses declared default assumptions only'
    $settingsNested = Audit-Fixture 'Settings' $true
    Assert-Equal $settingsNested.ExitCode 2 'Nested suffix setting makes audit incomplete'
    Assert-Equal (Row $settingsNested 'sql\default_name.sql').DirectReferenceStatus 'NoDirectReferenceFound' 'Nested setting invalidates prior default suffix matches'
    Assert-Equal (Row $settingsNested 'sql\default_name.pb').DirectReferenceStatus 'NoDirectReferenceFound' 'No alternate extension guessed'
    Assert-True (@($settingsNested.References | Where-Object { $_.Status -eq 'Unresolved' -and $_.Target -eq 'default_name' }).Count -eq 1) 'Extensionless target is manual review'

    $context = New-TestHotfix 'Context' '@@sub\driver.sql' @{
        'sql\sub\driver.sql' = "@@leaf.sql`n@leaf.sql`nSTART leaf.sql"
        'sql\sub\leaf.sql' = 'select 1 from dual;'
        'working\leaf.sql' = 'select 2 from dual;'
    }
    $contextAudit = Audit-Path $context $true (Join-Path $context 'working')
    Assert-Equal (Row $contextAudit 'sql\sub\leaf.sql').IndirectCallCount 1 '@@ uses its caller directory'
    Assert-Equal (Row $contextAudit 'working\leaf.sql').IndirectCallCount 2 'START/@ retain override working directory in nested scripts'
    Assert-Equal @($contextAudit.References | Where-Object { $_.Status -eq 'Ambiguous' }).Count 0 'Path context disambiguates duplicate basenames'

    $absolute = New-TestHotfix 'Absolute' '-- placeholder' @{ 'payload.bintext' = 'select 1 from dual;' }
    $outside = Join-Path $work 'Outside\external.sql'
    Set-Content -LiteralPath (Join-Path $absolute 'sql\master.sql') -Encoding UTF8 -Value @(
        ('start "' + (Join-Path $absolute 'sql\..\payload.bintext') + '"'),
        ('@"' + $outside + '"'), '@\\nonexistent-checker-host\share\external.sql',
        '@https://example.invalid/external.sql?x=1&y=2'
    )
    $absoluteAudit = Audit-Path $absolute
    Assert-Equal (Row $absoluteAudit 'payload.bintext').MatchingMethod 'AbsolutePath' 'Normalized absolute path resolves'
    Assert-Equal @($absoluteAudit.References | Where-Object { $_.Status -eq 'OutsideHotfix' }).Count 3 'Absolute external, UNC, URL separated without probing'
    Assert-Equal $absoluteAudit.ExitCode 1 'External reference findings do not claim machine-wide absence'
    Assert-True (-not (Test-InRoot ($absolute + 'Sibling\file.sql') $absolute)) 'Root boundary does not accept a prefix sibling'

    $manual = New-TestHotfix 'Manual' "host echo unsupported`n! echo unsupported`n:r child.sql`n@&name`nstart -`nchild.sql`nSTART`n@'unterminated`n@child.sql" @{ 'sql\child.sql' = 'select 1 from dual;' }
    $manualAudit = Audit-Path $manual
    Assert-Equal @($manualAudit.References | Where-Object { $_.Status -eq 'Unsupported' }).Count 3 'HOST, !, and SQLCMD :r require review'
    Assert-Equal @($manualAudit.References | Where-Object { $_.Status -eq 'Unresolved' }).Count 4 'Variable, continuation, missing operand, unclosed target require review'
    Assert-Equal (Row $manualAudit 'sql\child.sql').DirectCallCount 1 'Malformed command does not hide later valid call'
    Assert-Equal $manualAudit.ExitCode 2 'Unsupported commands cannot yield a clean audit'
    Assert-Equal $manualAudit.MasterCalls.Count 5 'Only START, @ and @@ commands count as master file calls'
    Assert-Equal $manualAudit.Counts['Master calls requiring review'] 4 'Unsupported commands do not inflate unresolved file-call counts'
    $manualSummary = Get-CoverageSummary $manualAudit
    Assert-True ($manualSummary -notmatch 'Master calls requiring (manual )?review:|unsupported or empty target') 'Normal summary omits the manual-review list and empty-target placeholders'
    Assert-True ($manualSummary -match '4 script call\(s\) could not be resolved.*-DetailedReport') 'Actual unresolved script calls retain a concise actionable note'
    $manualDetails = Get-Summary $manualAudit
    Assert-True ($manualDetails -match 'Unresolved / manual review:' -and $manualDetails -match 'host echo unsupported' -and $manualDetails -match 'Empty, dynamic, variable-bearing') 'Detailed reports retain actual source lines and reasons for unresolved and unsupported commands'
    $concat = New-TestHotfix 'Concatenation' "start 'child' || '.sql'" @{ 'sql\child.sql' = 'select 1 from dual;' }
    Assert-Equal (Audit-Path $concat).References[0].Status 'Unresolved' 'Possible filename concatenation requires review'
    $sqlClause = New-TestHotfix 'SqlClause' "select id from tree`nSTART WITH id=1`nconnect by prior id=parent_id;" @{ 'sql\with.sql' = 'select 1 from dual;' }
    Assert-Equal (Row (Audit-Path $sqlClause) 'sql\with.sql').DirectCallCount 0 'SQL START WITH clause cannot call a file named with.sql'
    Assert-Equal (Audit-Path $sqlClause).ExitCode 2 'START WITH clause or unquoted WITH target requires review'
    $extensionless = New-TestHotfix 'Extensionless' '@payload' @{ 'sql\payload.pb' = 'select 1 from dual;'; 'sql\payload.ps' = 'select 1 from dual;' }
    $extensionlessAudit = Audit-Path $extensionless
    Assert-Equal $extensionlessAudit.References[0].Status 'MissingInHotfix' 'Extensionless target never guesses .pb or .ps'
    Assert-True ($extensionlessAudit.References[0].ResolvedPath.EndsWith('payload.sql')) 'Missing extensionless target records assumed .sql path'
    $freeText = New-TestHotfix 'FreeText' "REM q'[`nPROMPT 'never closed`nSPOOL Bob's.log`n@child.sql" @{ 'sql\child.sql' = 'select 1 from dual;' }
    Assert-Equal (Audit-Path $freeText).ExitCode 0 'Free-text comments/logging quotes do not hide calls'
    $controlText = New-TestHotfix 'Control text' "@first.sql`nPAUSE Don't continue before checking the backup`nSET SQLPROMPT Developer's DB>`nCONNECT user/secret'@database`nSTART second.pb`nselect 'multiline SQL:`nSTART decoy.pb`n' from dual;`nselect q'[alternate SQL:`n@decoy.pb`n]' from dual;`n-- START decoy.pb`n/* START decoy.pb */" @{
        'sql\first.sql' = 'select 1 from dual;'; 'sql\second.pb' = 'select 2 from dual;'; 'sql\decoy.pb' = 'select 3 from dual;'
    }
    $controlAudit = Audit-Path $controlText
    Assert-Equal $controlAudit.Issues.Count 0 'SQL*Plus free text cannot poison subsequent SQL literal state'
    Assert-Equal (Row $controlAudit 'sql\first.sql').DirectCallCount 1 'Early master call remains visible before control text'
    Assert-Equal (Row $controlAudit 'sql\second.pb').DirectCallCount 1 'START after unpaired control-text punctuation is detected'
    Assert-Equal (Row $controlAudit 'sql\decoy.pb').DirectCallCount 0 'Real SQL strings, alternate strings and comments still never count as calls'
    $dynamicSql = New-TestHotfix 'Multiline execute immediate' "@first.sql`nBEGIN`n  EXECUTE IMMEDIATE '`n    CREATE TABLE DA.UETD_FLY_EMAILS`n    (AUTHOR VARCHAR2(300))`n    -- START decoy.pb`n    START decoy.pb`n    /* @decoy.pb */`n    TABLESPACE USERS';`n  DBMS_OUTPUT.PUT_LINE('Table Created');`nEND;`n/`nselect 'TIMESTAMPER End Table Update' || to_char(systimestamp, 'YYYY-MON-DD HH24:MI:SSSS') `" `" from dual;`nSTART aputil.ps;`nstart uigtoolsmessage.dat`nstart JSR_PYCHK01C.pb`nUPDATE settings`nSET value = 'multiline value:`nSTART decoy.pb`n'`nWHERE code = 'X';`nSTART final.sql" @{
        'sql\first.sql' = 'select 1 from dual;'; 'sql\decoy.pb' = 'select 2 from dual;'
        'sql\aputil.ps' = 'select 3 from dual;'; 'uig\sql\uigtoolsmessage.dat' = 'select 4 from dual;'
        'uig\sql\JSR_PYCHK01C.pb' = 'select 5 from dual;'; 'sql\final.sql' = 'select 6 from dual;'
    }
    $dynamicAudit = Audit-Path $dynamicSql
    Assert-Equal $dynamicAudit.Issues.Count 0 'Multiline EXECUTE IMMEDIATE and SQL UPDATE literals leave no false unterminated state'
    Assert-Equal $dynamicAudit.References.Count 5 'Dynamic SQL content does not become a SQLPlus invocation or contribute fake calls'
    foreach ($dynamicTarget in @('sql\first.sql','sql\aputil.ps','uig\sql\uigtoolsmessage.dat','uig\sql\JSR_PYCHK01C.pb','sql\final.sql')) {
        Assert-Equal (Row $dynamicAudit $dynamicTarget).DirectCallCount 1 'Every active call after multiline dynamic SQL is retained'
    }
    Assert-Equal (Row $dynamicAudit 'sql\decoy.pb').DirectCallCount 0 'START-looking text inside dynamic SQL and UPDATE literals never counts'
    $copiesRoot = New-TestHotfix 'Cross-folder calls' "START APERROR.DAT`n@`"poerror.dat`"`nstart ..\uig\sql\explicit.pb`n@@caller.pb`nSTART missing\lookalike.pb`nPROMPT START decoy.pb`nselect 'START decoy.pb' from dual;" @{
        'sql\aperror.dat' = 'DA data'; 'uig\sql\aperror.dat' = 'UIG data'; 'cf\sql\aperror.dat' = 'CF data'
        'sql\poerror.dat' = 'DA po'; 'uig\sql\poerror.dat' = 'UIG po'; 'sql\old_aperror.dat' = 'lookalike'
        'sql\explicit.pb' = 'wrong copy'; 'uig\sql\explicit.pb' = 'right copy'
        'sql\caller.pb' = 'caller copy'; 'uig\sql\caller.pb' = 'other copy'
        'sql\lookalike.pb' = 'wrong explicit path'; 'uig\sql\decoy.pb' = 'not called'
    }
    $copiesAudit = Audit-Path $copiesRoot
    foreach ($copyPath in @('sql\aperror.dat','uig\sql\aperror.dat','cf\sql\aperror.dat','sql\poerror.dat','uig\sql\poerror.dat')) {
        Assert-Equal (Row $copiesAudit $copyPath).DirectCallCount 1 'A bare filename directly called in the master covers every exact-name hotfix copy'
        Assert-Equal (Row $copiesAudit $copyPath).MatchingMethod 'FilenamePresence' 'Multiple-copy matches retain their evidence method'
    }
    foreach ($wrongCopy in @('sql\old_aperror.dat','sql\explicit.pb','uig\sql\caller.pb','sql\lookalike.pb','uig\sql\decoy.pb')) {
        Assert-Equal (Row $copiesAudit $wrongCopy).DirectCallCount 0 'Substring lookalikes, wrong explicit paths and ignored text cannot create coverage'
    }
    Assert-Equal (Row $copiesAudit 'uig\sql\explicit.pb').DirectCallCount 1 'An explicit path covers only its exact copy'
    Assert-Equal (Row $copiesAudit 'sql\caller.pb').DirectCallCount 1 '@@ retains caller-relative path matching for duplicate basenames'
    Assert-True ((Get-CoverageSummary $copiesAudit) -match 'Bare filenames.*all exact-name copies') 'Summary discloses multiple-copy filename coverage'
    $copiesNested = Audit-Path $copiesRoot $true
    Assert-True (-not $copiesNested.Cache.ContainsKey((Join-Path $copiesRoot 'uig\sql\aperror.dat'))) 'Nested parsing never reads an extra filename copy by guessing its runtime location'
    $badBlock = New-TestHotfix 'BadBlock' "/* unterminated`n@child.sql" @{ 'sql\child.sql' = 'select 1 from dual;' }
    Assert-Equal (Audit-Path $badBlock).ExitCode 2 'Unterminated block comment makes analysis incomplete'
    Assert-True ((Audit-Path $badBlock).Issues[0].Message -match 'block comment opened at line 1') 'Unclosed comment reports its opening line'
    $badLiteral = New-TestHotfix 'Bad literal' "-- heading`nselect 'unterminated`nSTART child.sql" @{ 'sql\child.sql' = 'select 1 from dual;' }
    $badLiteralAudit = Audit-Path $badLiteral
    Assert-Equal (Row $badLiteralAudit 'sql\child.sql').DirectCallCount 0 'An unclosed real SQL literal does not count its embedded START text'
    Assert-True ($badLiteralAudit.Issues[0].Message -match "SQL literal opened at line 2.*select 'unterminated") 'Unclosed SQL literal reports its opening line and source'
    $changedSyntax = New-TestHotfix 'SyntaxSetting' "set def ^`n@child.sql" @{ 'sql\child.sql' = 'select 1 from dual;' }
    Assert-Equal (Audit-Path $changedSyntax).References[0].Status 'Unresolved' 'Custom substitution setting prevents confident matching'
    $standardDefine = New-TestHotfix 'StandardDefine' "START first.pb`nset define on`n@second.ps`nset def off`n@second.ps`n@&dynamic" @{
        'sql\first.pb' = 'select 1 from dual;'; 'sql\second.ps' = 'select 2 from dual;'
    }
    $standardDefineAudit = Audit-Path $standardDefine
    Assert-Equal (Row $standardDefineAudit 'sql\first.pb').DirectCallCount 1 'SET DEFINE ON preserves literal calls before the setting'
    Assert-Equal (Row $standardDefineAudit 'sql\second.ps').DirectCallCount 2 'SET DEFINE ON/OFF preserves literal calls after the settings'
    Assert-Equal $standardDefineAudit.Issues.Count 0 'Standard DEFINE toggles do not invalidate the parser'
    Assert-Equal @($standardDefineAudit.References | Where-Object { $_.Status -eq 'Unresolved' }).Count 1 'Variable-bearing call still requires review'
    $nestedDefine = New-TestHotfix 'NestedDefine' "@child.sql`n@leaf.pb" @{
        'sql\child.sql' = 'set define on'; 'sql\leaf.pb' = 'select 1 from dual;'
    }
    Assert-Equal (Audit-Path $nestedDefine $true).ExitCode 0 'Standard DEFINE toggle in a nested script preserves literal graph matches'

    $foreign = New-TestHotfix 'Foreign' '@payload.ps1' @{ 'sql\payload.ps1' = "throw 'Do not execute me'" }
    Assert-Equal (Audit-Path $foreign).ExitCode 0 'Any explicit extension remains eligible for direct matching'
    Assert-Equal (Audit-Path $foreign $true).ExitCode 2 'Unsupported nested language is incomplete'
    $binary = New-TestHotfix 'Binary' '@child.pb' @{ 'sql\child.pb' = 'placeholder' }
    [IO.File]::WriteAllBytes((Join-Path $binary 'sql\child.pb'), [byte[]]@(0, 1, 2, 3))
    Assert-Equal (Audit-Path $binary $true).ExitCode 2 'Binary nested content is incomplete'

    $lockedRoot = Join-Path $fixtures 'Clean'
    $lockedMaster = Join-Path $lockedRoot 'sql\master.sql'
    $lock = New-Object IO.FileStream($lockedMaster, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $locked = Audit-Fixture 'Clean'
        Assert-Equal $locked.ExitCode 2 'Unreadable master cannot produce a clean result'
        Assert-True ($locked.Issues.Count -gt 0) 'Unreadable master records reason'
    } finally { $lock.Dispose() }
    $gone = Join-Path $work 'Nonexistent'
    $missingAudit = New-Audit $gone (Join-Path $gone 'sql\master.sql') $gone $false
    Invoke-Audit $missingAudit
    Assert-Equal $missingAudit.ExitCode 2 'Inaccessible/nonexistent root is failed'

    # BOMs override Auto. Auto tries UTF-8 first, then Windows-1252 per file.
    $encoded = New-TestHotfix 'Encoding' '@child.sql' @{ 'sql\child.sql' = 'select 1 from dual;' }
    Set-Content -LiteralPath (Join-Path $encoded 'sql\master.sql') -Value '@child.sql' -Encoding Unicode
    Assert-Equal (Audit-Path $encoded).ExitCode 0 'UTF-16 BOM detected'
    [IO.File]::WriteAllBytes((Join-Path $encoded 'sql\master.sql'), [byte[]]@(64, 99, 104, 105, 108, 100, 46, 115, 113, 108, 13, 10, 45, 45, 32, 233))
    Assert-Equal (Audit-Path $encoded).ExitCode 0 'Default Auto handles legacy Windows bytes without prompting'
    $ScriptEncoding = 'UTF8'
    Assert-Equal (Audit-Path $encoded).ExitCode 2 'Explicit strict UTF-8 remains available'
    $ScriptEncoding = 'Default'
    Assert-Equal (Audit-Path $encoded).ExitCode 0 'Explicit system ANSI encoding supported'
    $ScriptEncoding = 'UTF8'

    $ansiName = 'caf' + [char]0x00E9 + '.sql'
    $ansiRoot = New-TestHotfix 'ANSI master bytes' 'placeholder' @{
        ('sql\' + $ansiName) = 'select 1 from dual;'; 'sql\child.sql' = 'select 2 from dual;'
    }
    $ansiMaster = Join-Path $ansiRoot 'sql\master.sql'
    $ansiPrefix = "@child.sql`n--"
    $ansiText = $ansiPrefix + [string]::new(' ', (40398 - $ansiPrefix.Length)) + [char]0x00A0 + "`n@" + $ansiName
    [IO.File]::WriteAllBytes($ansiMaster, [Text.Encoding]::GetEncoding(1252).GetBytes($ansiText))
    $ansiHash = (Get-FileHash -LiteralPath $ansiMaster -Algorithm SHA256).Hash
    Assert-Equal ([IO.File]::ReadAllBytes($ansiMaster))[40398] 160 'ANSI case reproduces byte A0 at the reported offset'
    $ansiFailed = Audit-Path $ansiRoot
    Assert-Equal $ansiFailed.ExitCode 2 'Invalid UTF-8 is rejected without guessing an ANSI encoding'
    Assert-True (-not $ansiFailed.MasterReadable) 'Partially decoded ANSI master cannot imply completed coverage'
    Assert-True ($ansiFailed.Issues[0].Message -match '\[A0\] at index \d+') 'Failed UTF-8 decoding retains the offending byte and decoder position'
    Assert-True ($ansiFailed.Issues[0].Message -match 'ScriptEncoding Default' -and $ansiFailed.Issues[0].Message -match 'ScriptEncoding Windows1252') 'No-BOM decoding error gives actionable ANSI commands'
    $ScriptEncoding = 'Windows1252'
    $ansiAudit = Audit-Path $ansiRoot
    Assert-Equal $ansiAudit.ExitCode 0 'Explicit Windows1252 parses the entire A0-bearing master'
    Assert-Equal (Row $ansiAudit ('sql\' + $ansiName)).DirectCallCount 1 'Windows1252 preserves an accented target filename'
    Assert-Equal (Row $ansiAudit 'sql\child.sql').DirectCallCount 1 'Calls after the A0 byte remain checked'
    $ansiBomRoot = New-TestHotfix 'ANSI option BOM override' ('@' + $ansiName) @{ ('sql\' + $ansiName) = 'select 1 from dual;' }
    Assert-Equal (Audit-Path $ansiBomRoot).ExitCode 0 'UTF-8 BOM overrides an explicitly selected Windows1252 encoding'
    $binaryRoot = New-TestHotfix 'ANSI binary guard' 'placeholder' @{}
    [IO.File]::WriteAllBytes((Join-Path $binaryRoot 'sql\master.sql'), [byte[]]@(64, 0, 65))
    Assert-Equal (Audit-Path $binaryRoot).ExitCode 2 'Explicit ANSI decoding retains binary/NUL rejection'
    $ScriptEncoding = 'Auto'
    Assert-Equal (Get-FileHash -LiteralPath $ansiMaster -Algorithm SHA256).Hash $ansiHash 'Encoding choices never change source script bytes'

    $linkRoot = New-TestHotfix 'Links' 'select 1 from dual;' @{}
    $targetRoot = Join-Path $work 'ExternalLinkTarget'
    [void](New-Item -ItemType Directory -Path $targetRoot)
    Set-Content -LiteralPath (Join-Path $targetRoot 'external.sql') -Value 'select 1 from dual;'
    [void](New-Item -ItemType Junction -Path (Join-Path $linkRoot 'external') -Value $targetRoot)
    $linkAudit = Audit-Path $linkRoot
    Assert-Equal $linkAudit.Files.Count 1 'Directory junction is not traversed'
    Assert-Equal $linkAudit.ExitCode 2 'Skipped link clearly makes inventory incomplete'

    # Windows PowerShell link getters can make slow/unsupported network calls.
    # Ordinary entries must not evaluate those getters at all.
    $script:ordinaryLinkQueries = 0
    foreach ($attributes in @([IO.FileAttributes]::Normal, [IO.FileAttributes]::Archive, [IO.FileAttributes]::Directory)) {
        $ordinaryItem = [pscustomobject]@{ Attributes = $attributes }
        $ordinaryItem | Add-Member -MemberType ScriptProperty -Name LinkType -Value { $script:ordinaryLinkQueries++; return '' }
        $ordinaryItem | Add-Member -MemberType ScriptProperty -Name Target -Value { $script:ordinaryLinkQueries++; return @() }
        Assert-True (-not (Test-PathLink $ordinaryItem)) 'Ordinary files and directories cannot redirect traversal'
    }
    Assert-Equal $script:ordinaryLinkQueries 0 'Ordinary inventory and validation avoid lazy link metadata queries'
    Assert-True (Test-PathLink ([pscustomobject]@{ Attributes = [IO.FileAttributes]::ReparsePoint; LinkType = 'Junction'; Target = @('outside') })) 'Reparse entries still detect junctions'
    Assert-True (-not (Test-PathLink ([pscustomobject]@{ Attributes = [IO.FileAttributes]::ReparsePoint; LinkType = ''; Target = @() }))) 'Cloud placeholders retain ordinary-file behavior'

    $longPlainLine = 'select ' + [string]::new('a', 100000) + ' from dual;'
    $plainSqlRoot = New-TestHotfix 'Plain SQL workload' ($longPlainLine + "`nPROMPT @decoy.pb`n@payload.pb") @{
        'sql\payload.pb' = 'select 1 from dual;'; 'sql\decoy.pb' = 'select 2 from dual;'
    }
    $plainSqlAudit = Audit-Path $plainSqlRoot
    Assert-Equal (Row $plainSqlAudit 'sql\payload.pb').DirectCallCount 1 'Long ordinary SQL lines preserve subsequent active calls'
    Assert-Equal (Row $plainSqlAudit 'sql\decoy.pb').DirectCallCount 0 'Free-text commands remain excluded in optimized lexing'

    Write-Host 'Core assertions passed; checking real launcher, reports and automation exits.'
    $cleanRun = Run-Cli @('-HotfixPath', (Join-Path $fixtures 'Clean'), '-MasterPath', 'sql\master.sql', '-NonInteractive') 'clean-batch' $true
    Assert-Equal $cleanRun.ExitCode 0 'BAT launcher preserves exit zero and accepts spaces'
    Assert-Equal @(Get-ChildItem -LiteralPath $cleanRun.Folder -File).Count 1 'Default run creates exactly one file'
    $cleanSummary = Get-Content -Raw -LiteralPath $cleanRun.SummaryPath
    Assert-True ($cleanSummary -match 'Result: YES - all checked files are called by the master\.' -and $cleanSummary -match 'Files called by master: 1' -and $cleanSummary -match 'Files with no matching call: 0') 'Clean summary directly answers file coverage'
    Assert-True ((Get-Content -Raw -LiteralPath $cleanRun.Log).Contains($cleanSummary.TrimEnd())) 'CMD prints the same summary saved in the TXT'
    Assert-True ($cleanSummary -match '0KB files were not found\.') 'A real clean CMD run explicitly reports no zero-byte files'
    $zeroRun = Run-Cli @('-HotfixPath', $zeroRoot, '-MasterPath', 'sql\master.sql') 'zero-byte-cmd' $true
    Assert-Equal $zeroRun.ExitCode 1 'Normal CMD mode keeps zero-byte findings even when call coverage passes'
    Assert-True ((Get-Content -Raw -LiteralPath $zeroRun.SummaryPath) -match '0KB files found: 7') 'Real CMD output includes the recursive zero-byte count'
    $ignoredZeroRun = Run-Cli @('-HotfixPath', $ignoredOnlyRoot, '-MasterPath', 'sql\master.sql') 'ignored-zero-byte-cmd' $true
    Assert-Equal $ignoredZeroRun.ExitCode 0 'The four ignored empty-file extensions do not fail a real CMD run'
    $cliDocHotfix = 'V12-023-2-02-HF-ALC-07'
    $cliDocRoot = New-TestHotfix $cliDocHotfix ("@empty.sql`n@" + $cliDocHotfix + '.docx') @{
        'sql\empty.sql' = 'placeholder'
        'documentation\V12-022-2-02-HF-BLC-01.docx' = 'placeholder'
        'documentation\Hotfix Installation Instructions for V12C.docx' = 'Keep the installation instructions.'
    }
    [IO.File]::WriteAllBytes((Join-Path $cliDocRoot 'sql\empty.sql'), [byte[]]@())
    [IO.File]::WriteAllBytes((Join-Path $cliDocRoot 'documentation\V12-022-2-02-HF-BLC-01.docx'), [byte[]]@(80,75,3,4,0,255))
    $cliDocHash = (Get-FileHash -LiteralPath (Join-Path $cliDocRoot 'documentation\V12-022-2-02-HF-BLC-01.docx') -Algorithm SHA256).Hash
    $cliInstructions = Join-Path $cliDocRoot 'documentation\Hotfix Installation Instructions for V12C.docx'
    $cliInstructionsHash = (Get-FileHash -LiteralPath $cliInstructions -Algorithm SHA256).Hash
    $cliDocRun = Run-Cli @('-HotfixPath', $cliDocRoot, '-MasterPath', 'sql\master.sql') 'documentation-and-zero' $true
    Assert-Equal $cliDocRun.ExitCode 1 'Real CMD mode renames the hotfix document and reports empty SQL files'
    Assert-Equal (Get-FileHash -LiteralPath (Join-Path $cliDocRoot ('documentation\' + $cliDocHotfix + '.docx')) -Algorithm SHA256).Hash $cliDocHash 'Real CMD mode preserves document bytes while changing its hotfix/build name'
    Assert-Equal (Get-FileHash -LiteralPath $cliInstructions -Algorithm SHA256).Hash $cliInstructionsHash 'Real CMD mode leaves the installation instructions untouched'
    $cliDocSummary = Get-Content -Raw -LiteralPath $cliDocRun.SummaryPath
    Assert-True ($cliDocSummary -match 'Documentation renamed:' -and $cliDocSummary -match '0KB files found: 1' -and $cliDocSummary -match '(?m)^  sql\\empty.sql\r?$') 'The saved summary includes the DOCX rename and exact zero-byte path'
    Assert-True ($cliDocSummary -match 'Required calls missing files: 0') 'Real master call resolution sees the renamed DOCX before checking targets'
    Assert-True ((Get-Content -Raw -LiteralPath $cliDocRun.Log).Contains($cliDocSummary.TrimEnd())) 'CMD and TXT contain identical documentation and zero-byte results'
    $cliDocDetailed = Run-Cli @('-HotfixPath', $cliDocRoot, '-MasterPath', 'sql\master.sql', '-DetailedReport') 'documentation-and-zero-details'
    Assert-Equal $cliDocDetailed.ExitCode 1 'Detailed mode preserves zero-byte findings on a rerun'
    $cliDocDetailedSummary = Get-Content -Raw -LiteralPath $cliDocDetailed.SummaryPath
    Assert-True ($cliDocDetailedSummary -match '0KB file check' -and $cliDocDetailedSummary -notmatch 'Documentation renamed:') 'Detailed reruns retain zero-byte reporting without repeating an already matching DOCX rename'
    Assert-True ((Get-Content -Raw -LiteralPath $cliDocDetailed.CombinedPath) -match '0KB files found: 1') 'Detailed combined totals include zero-byte findings'
    Assert-Equal (Split-Path -Leaf $cleanRun.SummaryPath) 'summary_Clean.txt' 'Normal summary filename uses the hotfix folder name'
    Assert-True ((Split-Path -Leaf $cleanRun.Folder) -match '^\d{8}_\d{4}(AM|PM)_Clean$') 'Normal report folder has the requested readable date, time and hotfix name'
    $exampleHotfix = 'V12-020-2-02N-HF-AMI-16'
    $exampleRoot = New-TestHotfix $exampleHotfix '@child.sql' @{
        'sql\child.sql' = 'select 1 from dual;'
        'v12hotfixinstall\v12hotfixinstall.pl' = '# Preserve this header.'
    }
    $exampleInstaller = Join-Path $exampleRoot 'v12hotfixinstall\v12hotfixinstall.pl'
    $exampleOriginal = '# Preserve this header.' + "`r`n" + 'my $hotfix = "V12-YYY-Y-YY-HF-YYY-YY"; # Preserve this comment.' + "`r`n"
    [IO.File]::WriteAllText($exampleInstaller, $exampleOriginal, [Text.UTF8Encoding]::new($false))
    $timeBeforeRun = Get-ReportTimestamp
    $exampleRun = Run-Cli @('-HotfixPath', $exampleRoot, '-MasterPath', 'sql\master.sql') 'named-hotfix' $true
    $timeAfterRun = Get-ReportTimestamp
    Assert-Equal $exampleRun.ExitCode 0 'A real CMD run synchronizes the installer and completes both checks'
    Assert-Equal (Split-Path -Leaf $exampleRun.SummaryPath) ('summary_' + $exampleHotfix + '.txt') 'The exact user-supplied hotfix example is used in the summary filename'
    $actualFolderName = Split-Path -Leaf $exampleRun.Folder
    Assert-True ($actualFolderName -ceq ($timeBeforeRun + '_' + $exampleHotfix) -or $actualFolderName -ceq ($timeAfterRun + '_' + $exampleHotfix)) 'A real CMD report folder uses the current Toronto date/time and exact hotfix name'
    Assert-Equal ([IO.File]::ReadAllText($exampleInstaller)) ($exampleOriginal.Replace('V12-YYY-Y-YY-HF-YYY-YY', $exampleHotfix)) 'A real CMD run changes only the installer hotfix value'
    $exampleSummary = Get-Content -Raw -LiteralPath $exampleRun.SummaryPath
    Assert-True ($exampleSummary -match 'Installer updated:' -and (Get-Content -Raw -LiteralPath $exampleRun.Log).Contains($exampleSummary.TrimEnd())) 'The installer result and named output path match in CMD and TXT'
    $firstReportHash = (Get-FileHash -LiteralPath $exampleRun.SummaryPath -Algorithm SHA256).Hash
    $exampleInstallerHash = (Get-FileHash -LiteralPath $exampleInstaller -Algorithm SHA256).Hash
    $exampleInstallerTime = [IO.File]::GetLastWriteTimeUtc($exampleInstaller)
    $exampleRerun = Run-Cli @('-HotfixPath', $exampleRoot, '-MasterPath', 'sql\master.sql') 'named-hotfix' $true
    Assert-Equal $exampleRerun.ExitCode 0 'A real CMD rerun skips an already matching installer'
    Assert-Equal $exampleRerun.SummaryPaths.Count 2 'A repeated CMD run creates another named summary instead of overwriting the first'
    Assert-Equal (Get-FileHash -LiteralPath $exampleRun.SummaryPath -Algorithm SHA256).Hash $firstReportHash 'The first named summary remains unchanged after a rerun'
    Assert-Equal (Get-FileHash -LiteralPath $exampleInstaller -Algorithm SHA256).Hash $exampleInstallerHash 'A real CMD rerun leaves a matching installer unchanged'
    Assert-Equal ([IO.File]::GetLastWriteTimeUtc($exampleInstaller).Ticks) $exampleInstallerTime.Ticks 'A real CMD rerun preserves a matching installer modification time'
    $progressLog = Get-Content -Raw -LiteralPath $cleanRun.Log
    Assert-True ($progressLog -match '(?s)Validating hotfix and master paths.*Scanning hotfix folders.*Inventory complete: 2 files.*Reading master and checking calls.*Preparing coverage results.*Saving summary') 'Real CMD run reports validation, inventory, parsing, and writing stages'
    Assert-True ($cleanSummary -notmatch 'Detected resolved calls|CallChains|Unresolved / manual review|combined totals') 'Default summary omits detailed call trace sections'
    $cliHookHotfix = 'V12-023-2-02-HF-AMA-27'
    $cliHookFiles = @{ 'sql\payload.pb' = 'select 1 from dual;' }
    foreach ($suffix in $hookSuffixes) { $cliHookFiles['sql\' + $oldHookPrefix + '.' + $suffix] = '# Real CMD hook rename for ' + $suffix }
    $cliHookMaster = "@payload.pb`n" + (($hookSuffixes | ForEach-Object { 'START ' + $cliHookHotfix + '.' + $_ }) -join "`n")
    $cliHookRoot = New-TestHotfix $cliHookHotfix $cliHookMaster $cliHookFiles
    $cliHookHashes = @{}
    foreach ($suffix in $hookSuffixes) { $cliHookHashes[$suffix] = (Get-FileHash -LiteralPath (Join-Path $cliHookRoot ('sql\' + $oldHookPrefix + '.' + $suffix)) -Algorithm SHA256).Hash }
    $cliHookRun = Run-Cli @('-HotfixPath', $cliHookRoot, '-MasterPath', 'sql\master.sql') 'hook-renames' $true
    Assert-Equal $cliHookRun.ExitCode 0 'The real CMD launcher renames all hooks before checking master call targets'
    foreach ($suffix in $hookSuffixes) {
        Assert-Equal (Get-FileHash -LiteralPath (Join-Path $cliHookRoot ('sql\' + $cliHookHotfix + '.' + $suffix)) -Algorithm SHA256).Hash $cliHookHashes[$suffix] 'The real CMD workflow preserves hook bytes under the new name'
    }
    $cliHookSummary = Get-Content -Raw -LiteralPath $cliHookRun.SummaryPath
    Assert-Equal @([regex]::Matches($cliHookSummary, '(?m)^Script renamed:')).Count 5 'The saved summary records exactly the five actual hook renames'
    Assert-True ((Get-Content -Raw -LiteralPath $cliHookRun.Log).Contains($cliHookSummary.TrimEnd())) 'The hook rename results match between CMD and TXT'
    Assert-True ($cliHookSummary -match ('(?m)^Executed by: ' + [regex]::Escape([Environment]::UserName) + '\r?$')) 'Hook rename summaries retain the current execution username'
    $cliHookRerun = Run-Cli @('-HotfixPath', $cliHookRoot, '-MasterPath', 'sql\master.sql') 'hook-renames' $true
    Assert-Equal $cliHookRerun.ExitCode 0 'The CMD workflow skips already renamed hooks on a repeated run'
    Assert-True ((Get-Content -Raw -LiteralPath $cliHookRerun.SummaryPath) -notmatch 'Script renamed:') 'A repeated CMD run does not print redundant rename messages'
    Assert-True ($cleanSummary -match 'File presence result: YES' -and $cleanSummary -match 'Required calls missing files: 0') 'A clean real CMD run checks master targets too'
    $presenceRun = Run-Cli @('-HotfixPath', $presenceRoot, '-MasterPath', 'sql\master.sql') 'presence-batch' $true
    Assert-Equal $presenceRun.ExitCode 1 'Missing master targets fail a normal CMD run even when every supplied file is called'
    $presenceTxt = Get-Content -Raw -LiteralPath $presenceRun.SummaryPath
    Assert-True ($presenceTxt -match 'Result: YES - all checked files are called' -and $presenceTxt -match 'File presence result: NO - 3 required call') 'The two checks show independent results'
    Assert-True ($presenceTxt -match 'Allowed missing calls ignored: 4') 'Saved summary distinguishes ignored absences'
    Assert-True ($presenceTxt -notmatch 'Ignored missing calls \(allowed list\)|Master calls requiring (manual )?review:|unsupported or empty target') 'Real CMD/TXT summary omits both redundant lists'
    Assert-True ((Get-Content -Raw -LiteralPath $presenceRun.Log).Contains($presenceTxt.TrimEnd())) 'CMD and TXT show the same new section'
    $allowedRun = Run-Cli @('-HotfixPath', $allowedRoot, '-MasterPath', 'sql\master.sql') 'allowed-batch' $true
    Assert-Equal $allowedRun.ExitCode 0 'All supplied exceptions pass in a real normal CMD run'
    $allowedOutput = Get-Content -Raw -LiteralPath $allowedRun.Log
    Assert-True ($allowedOutput -match 'Allowed missing calls ignored: 93' -and $allowedOutput -notmatch 'dbdefine\.sql|ptfcompx|invalidobjects\.sql|Ignored missing calls \(allowed list\)') 'Real CMD run prints only the allowed missing count without the ignored filenames'
    $manualRun = Run-Cli @('-HotfixPath', $manual, '-MasterPath', 'sql\master.sql') 'concise-unresolved'
    Assert-Equal $manualRun.ExitCode 2 'Concise unresolved output preserves an incomplete exit code'
    $manualTxt = Get-Content -Raw -LiteralPath $manualRun.SummaryPath
    Assert-True ($manualTxt -match 'Master calls checked: 5' -and $manualTxt -match '4 script call\(s\) could not be resolved' -and $manualTxt -notmatch 'Master calls requiring (manual )?review:|unsupported or empty target') 'Real normal run reports actual script-call counts and a short uncertainty note'
    Assert-True ((Get-Content -Raw -LiteralPath $manualRun.Log).Contains($manualTxt.TrimEnd())) 'Concise unresolved CMD output matches its saved TXT'
    $allowedDetailedRun = Run-Cli @('-HotfixPath', $allowedRoot, '-MasterPath', 'sql\master.sql', '-DetailedReport') 'allowed-details'
    Assert-Equal $allowedDetailedRun.ExitCode 0 'Allowed missing calls also pass in detailed mode'
    $allowedCsv = @(Import-Csv -LiteralPath (Join-Path $allowedDetailedRun.Folder '01_Allowed_missing_targets_references.csv'))
    Assert-Equal @($allowedCsv | Where-Object { $_.Status -eq 'IgnoredMissing' }).Count 93 'Detailed references retain allowed-call evidence with a distinct status'
    Assert-True ((Get-Content -Raw -LiteralPath $allowedDetailedRun.SummaryPath) -match 'Master call file check') 'Detailed text includes the new presence section'
    Assert-True ((Get-Content -Raw -LiteralPath $allowedDetailedRun.SummaryPath) -notmatch 'Ignored missing calls \(allowed list\):') 'Detailed text also omits the repeated ignored-call list'
    $ansiAutoRun = Run-Cli @('-HotfixPath', $ansiRoot, '-MasterPath', 'sql\master.sql', '-NonInteractive') 'ansi-auto-cmd' $true
    Assert-Equal $ansiAutoRun.ExitCode 0 'CMD automatic encoding completes without an encoding response'
    Assert-True ((Get-Content -Raw -LiteralPath $ansiAutoRun.SummaryPath) -match 'Encoding fallback:.*Windows1252' ) 'Automatic encoding choice is recorded in the single summary'
    Assert-True ((Get-Content -Raw -LiteralPath $ansiAutoRun.Log) -notmatch 'Encoding retry Y/N|Retry this file') 'Automatic CMD run never requests encoding confirmation'
    $ansiFailureRun = Run-Cli @('-HotfixPath', $ansiRoot, '-MasterPath', 'sql\master.sql', '-ScriptEncoding', 'UTF8') 'ansi-guidance'
    Assert-Equal $ansiFailureRun.ExitCode 2 'Real process keeps incomplete status for invalid UTF-8'
    Assert-True ((Get-Content -Raw -LiteralPath $ansiFailureRun.SummaryPath) -match 'Hotfix-Checker.bat -ScriptEncoding Default') 'Saved failed summary includes the executable ANSI workaround'
    Assert-True ((Get-Content -Raw -LiteralPath $ansiFailureRun.Log) -notmatch 'Retry this file as Windows-1252\?') 'Batch paths never prompt for an encoding retry'
    $ansiSuccessRun = Run-Cli @('-HotfixPath', $ansiRoot, '-MasterPath', 'sql\master.sql', '-ScriptEncoding', 'Windows1252') 'ansi-cmd' $true
    Assert-Equal $ansiSuccessRun.ExitCode 0 'CMD launcher forwards the explicit Windows1252 encoding'
    Assert-True ((Get-Content -Raw -LiteralPath $ansiSuccessRun.SummaryPath) -match 'Files called by master: 2') 'Explicit ANSI CMD run reports the complete file coverage'
    $uncalledRoot = New-TestHotfix 'UncalledFile' 'select 1 from dual;' @{ 'sql\unused.sql' = 'select 2 from dual;' }
    $findingRun = Run-Cli @('-HotfixPath', $uncalledRoot, '-MasterPath', 'sql\master.sql') 'findings-batch' $true
    Assert-Equal $findingRun.ExitCode 1 'BAT launcher preserves findings exit one'
    $findingSummary = Get-Content -Raw -LiteralPath $findingRun.SummaryPath
    Assert-True ($findingSummary -match 'Result: NO - 1 file\(s\)' -and $findingSummary -match '  sql\\unused\.sql') 'Missing coverage is clearly identified by relative filename'
    Assert-True ($findingSummary -notmatch '\[NoDirectReferenceFound; NotChecked\]') 'Missing file list has no internal status annotations'
    $simplePartial = Run-Cli @('-HotfixPath', (Join-Path $fixtures 'Hotfix one'), '-MasterPath', 'sql\master.sql') 'simple-incomplete' $true
    $partialSummary = Get-Content -Raw -LiteralPath $simplePartial.SummaryPath
    Assert-Equal $simplePartial.ExitCode 2 'Simple summary preserves incomplete coverage status'
    Assert-Equal @(Get-ChildItem -LiteralPath $simplePartial.Folder -File).Count 1 'Incomplete default run still creates only one TXT'
    Assert-True ($partialSummary -match 'Files checked: 27' -and $partialSummary -match 'Files called by master: 16' -and $partialSummary -match 'Files with no matching call: 11') 'Simple counts include every exact basename directly called in the master'
    Assert-True ($partialSummary -match 'Result: 11 file\(s\) have no matching call in the master\.' -and $partialSummary -notmatch 'Result: YES|Some content or calls could not be checked|File presence results are provisional') 'Incomplete summaries retain findings and omit the repeated status notes'
    $partialList = ($partialSummary -split '(?m)^\*  Files with no matching call in the master +\*\r?\n\*+\r?\n')[1] -split '\r?\n\r?\n\*+\r?\n\*  Master call file check' | Select-Object -First 1
    Assert-Equal @($partialList -split '\r?\n' | Where-Object { $_.Trim() }).Count 11 'All 11 uncalled files appear once in the plain list'
    Assert-True ($partialList -match '(?m)^  sql\\subfolder\\indirect\.sql\r?$' -and $partialList -notmatch '(?m)^  sql\\py_post\.pb\r?$') 'List includes indirectly called files and excludes direct matches'
    $coveredExtras = New-TestHotfix 'CoveredExtras' "@child.sql`n@child.sql`n@not-in-hotfix.sql" @{ 'sql\child.sql' = 'select 1 from dual;' }
    $coverageOnly = Run-Cli @('-HotfixPath', $coveredExtras, '-MasterPath', 'sql\master.sql') 'coverage-only'
    Assert-Equal $coverageOnly.ExitCode 1 'Default mode reports required call targets missing from the hotfix'
    $repeatedOnlyRoot = New-TestHotfix 'Repeated present target' "@child.sql`n@child.sql" @{ 'sql\child.sql' = 'select 1 from dual;' }
    $repeatedOnly = Run-Cli @('-HotfixPath', $repeatedOnlyRoot, '-MasterPath', 'sql\master.sql') 'repeated-present'
    Assert-Equal $repeatedOnly.ExitCode 0 'Repeated calls alone still pass both normal checks'
    $detailedExtras = Run-Cli @('-HotfixPath', $coveredExtras, '-MasterPath', 'sql\master.sql', '-DetailedReport') 'covered-details'
    Assert-Equal $detailedExtras.ExitCode 1 'Detailed mode retains extra-target and repetition findings'
    $nestedRun = Run-Cli @('-HotfixPath', (Join-Path $fixtures 'Hotfix one'), '-MasterPath', 'sql\master.sql', '-IncludeNested', '-DetailedReport') 'nested-batch' $true
    Assert-Equal $nestedRun.ExitCode 2 'BAT launcher preserves incomplete exit two'
    $fileCsv = @(Import-Csv -LiteralPath (Join-Path $nestedRun.Folder '01_Hotfix_one_files.csv'))
    $refCsv = @(Import-Csv -LiteralPath (Join-Path $nestedRun.Folder '01_Hotfix_one_references.csv'))
    Assert-Equal $fileCsv.Count 27 'Report has exactly one row per eligible file'
    Assert-Equal $refCsv.Count 25 'References CSV contains every matching file for direct and reached calls'
    Assert-Equal @($fileCsv | Where-Object { $_.AuditStatus -eq 'Incomplete' }).Count 27 'Export preserves audit status'
    Assert-True ((Get-Content -Raw -LiteralPath $nestedRun.SummaryPath) -match 'Unresolved / manual review') 'Text report includes manual review section'
    Assert-True ((Get-Content -Raw -LiteralPath $nestedRun.Log) -match [regex]::Escape($nestedRun.Folder)) 'Console shows full report paths'
    Assert-True ((Get-Content -Raw -LiteralPath $nestedRun.Log) -notmatch 'Press Enter to close this window') 'Noninteractive automation has no final wait'
    $repeatRun = Run-Cli @('-HotfixPath', (Join-Path $fixtures 'Clean'), '-MasterPath', 'sql\master.sql') 'clean-batch' $true
    Assert-True ($repeatRun.Folder -ne $cleanRun.Folder -or @(Get-ChildItem -LiteralPath (Split-Path -Parent $cleanRun.Folder) -Directory).Count -eq 2) 'Previous run is preserved'

    $inputFile = Join-Path $work 'inputs.csv'
    @(
        [pscustomobject]@{ HotfixPath = (Join-Path $fixtures 'Hotfix one'); MasterPath = 'sql\master.sql'; WorkingDirectory = '' },
        [pscustomobject]@{ HotfixPath = (Join-Path $fixtures 'Hotfix two'); MasterPath = 'sql\master.sql'; WorkingDirectory = '' },
        [pscustomobject]@{ HotfixPath = $gone; MasterPath = 'sql\master.sql'; WorkingDirectory = '' }
    ) | Export-Csv -LiteralPath $inputFile -NoTypeInformation -Encoding UTF8
    $simpleMulti = Run-Cli @('-InputCsv', $inputFile) 'simple-multiple'
    Assert-Equal $simpleMulti.ExitCode 2 'Separate summaries preserve invalid hotfix status while checking other hotfixes'
    Assert-Equal $simpleMulti.SummaryPaths.Count 3 'Every selected hotfix gets its own summary'
    Assert-Equal @(Get-ChildItem -LiteralPath $simpleMulti.ReportRoot -Directory).Count 3 'Every selected hotfix gets its own report folder'
    $multiSummary = ($simpleMulti.SummaryPaths | ForEach-Object { Get-Content -Raw -LiteralPath $_ }) -join "`n"
    Assert-Equal @([regex]::Matches($multiSummary, '(?m)^Hotfix:')).Count 3 'The separate summaries cover every selected hotfix'
    Assert-True ((Get-Content -Raw -LiteralPath $simpleMulti.Log) -match 'Hotfixes checked: 3' -and $multiSummary -match 'Result: COULD NOT CHECK') 'Failed hotfix cannot look like complete zero-file coverage'
    foreach ($summaryFile in $simpleMulti.SummaryPaths) {
        $savedSummary = Get-Content -Raw -LiteralPath $summaryFile
        Assert-True ((Get-Content -Raw -LiteralPath $simpleMulti.Log).Contains($savedSummary.TrimEnd())) 'Multiple-hotfix CMD output matches each saved summary'
        Assert-Equal @([regex]::Matches($savedSummary, '(?m)^Hotfix:')).Count 1 'Each summary describes exactly one hotfix'
        Assert-Equal @(Get-ChildItem -LiteralPath (Split-Path -Parent $summaryFile) -File).Count 1 'A normal hotfix report folder contains only its own TXT'
    }
    $multi = Run-Cli @('-InputCsv', $inputFile, '-DetailedReport') 'multiple'
    Assert-Equal $multi.ExitCode 2 'Combined incomplete status takes precedence'
    Assert-Equal @(Get-ChildItem -LiteralPath $multi.ReportRoot -Filter '*_files.csv' -Recurse -File).Count 3 'Independent report for each hotfix including invalid hotfix'
    $combined = Get-Content -Raw -LiteralPath $multi.CombinedPath
    Assert-True ($combined -match 'Hotfixes reviewed: 3' -and $combined -match 'Eligible files checked: 27' -and $combined -match 'Files directly referenced: 16') 'Combined totals are correct and readable'
    Assert-True ($combined -match 'Ambiguous references: 0' -and $combined -match 'Call targets not found within scanned hotfixes: 3') 'Combined reference findings are totaled'
    Assert-True ($combined -match 'Files referenced only indirectly: Not checked') 'Direct-only combined report does not imply nested checking'
    $failedCsv = Get-ChildItem -LiteralPath $multi.ReportRoot -Filter '03_Nonexistent_files.csv' -Recurse -File | Select-Object -First 1
    Assert-Equal @(Import-Csv -LiteralPath $failedCsv.FullName).Count 0 'Failed audit still has header-only CSV'
    $failure = Run-Cli @('-HotfixPath', (Join-Path $fixtures 'Clean'), '-MasterPath', 'sql\absent.sql') 'missing-master'
    Assert-Equal $failure.ExitCode 2 'Missing master produces incomplete reports'
    $failureSummary = Get-Content -Raw -LiteralPath $failure.SummaryPath
    Assert-True ($failureSummary -match 'COULD NOT CHECK' -and $failureSummary -match 'Selected master does not exist' -and $failureSummary -notmatch 'Result: YES') 'Simple failure summary explains why coverage is unavailable'
    $lock = New-Object IO.FileStream($lockedMaster, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $lockedRun = Run-Cli @('-HotfixPath', $lockedRoot, '-MasterPath', 'sql\master.sql') 'locked-summary'
        $lockedSummary = Get-Content -Raw -LiteralPath $lockedRun.SummaryPath
        Assert-Equal $lockedRun.ExitCode 2 'Locked master preserves incomplete exit in simple mode'
        Assert-True ($lockedSummary -match 'COULD NOT CHECK' -and $lockedSummary -notmatch 'Files with no matching call: 0|Result: YES') 'Unreadable master never produces a misleading coverage summary'
    } finally { $lock.Dispose() }
    $outsideMaster = Run-Cli @('-HotfixPath', (Join-Path $fixtures 'Clean'), '-MasterPath', (Join-Path $fixtures 'Hotfix one\sql\master.sql')) 'outside-master'
    Assert-Equal $outsideMaster.ExitCode 2 'Manual/batch master must remain within its hotfix'

    $badReport = Join-Path $fixtures 'Clean\must-not-create-reports'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checker -HotfixPath (Join-Path $fixtures 'Clean') -MasterPath 'sql\master.sql' -ReportDirectory $badReport > (Join-Path $work 'bad-report.log') 2>&1
    Assert-Equal $LASTEXITCODE 2 'Reports inside hotfix refused'
    Assert-True (-not (Test-Path -LiteralPath $badReport)) 'Report guard runs before any hotfix write'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checker -HotfixPath (Split-Path -Parent $checker) -MasterPath 'tests\fixtures\Clean\sql\master.sql' > (Join-Path $work 'utility-inside.log') 2>&1
    Assert-Equal $LASTEXITCODE 2 'Utility inside scanned hotfix refused'
    $reportLink = Join-Path $work 'report-link'
    [void](New-Item -ItemType Junction -Path $reportLink -Value (Join-Path $fixtures 'Clean'))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checker -HotfixPath (Join-Path $fixtures 'Clean') -MasterPath 'sql\master.sql' -ReportDirectory $reportLink > (Join-Path $work 'report-link.log') 2>&1
    Assert-Equal $LASTEXITCODE 2 'Report junction cannot bypass outside-hotfix rule'
    # One malformed input must not prevent other hotfix rows from being audited.
    @(
        [pscustomobject]@{ HotfixPath = 'C:relative'; MasterPath = 'sql\master.sql' },
        [pscustomobject]@{ HotfixPath = (Join-Path $fixtures 'Clean'); MasterPath = 'sql\master.sql' }
    ) | Export-Csv -LiteralPath $inputFile -NoTypeInformation -Encoding UTF8
    $badInput = Run-Cli @('-InputCsv', $inputFile, '-DetailedReport') 'bad-input'
    Assert-Equal $badInput.ExitCode 2 'Malformed hotfix path recorded as failure'
    Assert-Equal @(Import-Csv -LiteralPath (Join-Path $badInput.Folder '02_Clean_files.csv')).Count 1 'Valid hotfix after malformed path is still audited'

    $interactiveRoot = New-TestHotfix 'Interactive one' '@payload.pb' @{
        'sql\01-decoy.sql' = 'select 1 from dual;'; 'sql\payload.pb' = 'select 2 from dual;'
    }
    $manualRoot = New-TestHotfix 'Interactive two' 'select 1 from dual;' @{
        'manual\chosen.sql' = '@@leaf.sql'; 'manual\leaf.sql' = 'select 2 from dual;'
    }
    $interactive = Run-Interactive $checker @($gone, $interactiveRoot, $interactiveRoot, ($interactiveRoot + '\'), $manualRoot, '', '99', '2', 'M', $lockedMaster, 'M', 'manual\chosen.sql') 'interactive'
    Assert-Equal $interactive.ExitCode 1 'Interactive multiple-hotfix workflow completes with findings'
    Assert-True ($interactive.Output -match 'Invalid hotfix:' -and $interactive.Output -match 'Invalid master:') 'Interactive validation re-prompts for bad input'
    Assert-True ($interactive.Output -match [regex]::Escape('Selected master: ' + (Join-Path $interactiveRoot 'sql\master.sql'))) 'Master selected by number, not default first SQL file'
    Assert-True ($interactive.Output -match [regex]::Escape('Selected master: ' + (Join-Path $manualRoot 'manual\chosen.sql'))) 'Manual selection outside sql directory accepted within hotfix'
    Assert-True ($interactive.Output -match 'Hotfixes checked: 2' -and $interactive.Output -notmatch 'COULD NOT CHECK|Some content or calls could not be checked') 'Interactive hotfixes have separate completed summaries'
    Assert-True ($interactive.Output -match [regex]::Escape('Added hotfix: ' + $interactiveRoot)) 'Accepted folder is visibly acknowledged'
    Assert-Equal @([regex]::Matches($interactive.Output, 'Already added:')).Count 2 'Duplicate entries are acknowledged and not added twice'
    # ConsoleHost does not emit Read-Host prompt text when stdin is redirected.
    Assert-True ($interactive.Output -match 'Press Enter on the empty prompt to continue to master selection') 'Accepted and duplicate inputs explain how to advance'
    Assert-True ($interactive.Output -match 'Hotfixes selected: Next, confirm or select a master for each hotfix\.') 'Blank input advances to master selection using the requested prompt'
    $autoRoot = New-TestHotfix 'Auto master hotfix' '-- Decoy master, not the detected master.' @{
        'sql\AUTO MASTER HOTFIX.SQL' = '@payload.pb';
        'sql\payload.pb' = 'select 1 from dual;';
        'manual\chosen.sql' = '@@leaf.sql'; 'manual\leaf.sql' = 'select 2 from dual;'
    }
    $autoMaster = (Get-Item -LiteralPath (Join-Path $autoRoot 'sql\Auto master hotfix.sql')).FullName
    $acceptedAuto = Run-Interactive $checker @($autoRoot, '', '', 'maybe', ' y ') 'auto-confirm' -VerifyKeepOpen
    Assert-True $acceptedAuto.HeldForClose 'Confirmed automatic master retains the final interactive wait'
    Assert-Equal $acceptedAuto.ExitCode 1 'Confirmed automatic master preserves coverage result'
    Assert-True ($acceptedAuto.Output -match [regex]::Escape('Detected master: ' + $autoMaster)) 'Folder-name master is detected ignoring case and with spaces'
    Assert-True ($acceptedAuto.Output -match 'the master script for this hotfix\? \(Y/N\)') 'Detected master requires an explicit confirmation'
    Assert-Equal @([regex]::Matches($acceptedAuto.Output, 'Please enter Y or N\.')).Count 2 'Blank and invalid answers do not accept the master'
    Assert-True ($acceptedAuto.Output -match [regex]::Escape('Selected master: ' + $autoMaster) -and $acceptedAuto.Output -notmatch 'Select the master for:') 'Y uses the detected master without displaying the selection menu'
    Assert-True ($acceptedAuto.Output -match 'Files called by master: 1') 'Confirmed master is actually read for file coverage'
    $rejectedAuto = Run-Interactive $checker @($autoRoot, '', 'n', 'M', 'manual\chosen.sql') 'auto-reject'
    Assert-Equal $rejectedAuto.ExitCode 1 'Manual choice after N preserves coverage result'
    Assert-True ($rejectedAuto.Output -match 'Select the master for:' -and $rejectedAuto.Output -match [regex]::Escape('Selected master: ' + (Join-Path $autoRoot 'manual\chosen.sql'))) 'N opens the menu and honors a manually entered master'
    Assert-True ($interactive.Output -match 'No master matching the hotfix folder name was found') 'Missing folder-name master falls back to the existing menu'
    $launchCopy = Join-Path $work 'Double click utility'
    [void](New-Item -ItemType Directory -Path $launchCopy)
    Copy-Item -LiteralPath $checker, $launcher -Destination $launchCopy
    $paused = Run-Interactive (Join-Path $launchCopy 'Hotfix-Checker.bat') @((Join-Path $fixtures 'Clean'), '', '2', 'x') 'double-click' $true
    Assert-Equal $paused.ExitCode 0 'No-argument BAT run completes and preserves result'
    Assert-True ($paused.Output -match 'Press any key to continue') 'Double-click launcher displays pause prompt'
    Assert-True ($paused.Output -notmatch 'Press Enter to close this window') 'BAT owns its pause without a second script pause'
    $doubleClickReports = @(Get-ChildItem -LiteralPath (Join-Path $launchCopy 'reports') -Recurse -File)
    Assert-Equal $doubleClickReports.Count 1 'Double-click launcher saves exactly one summary TXT'
    Assert-True ($paused.Output.Contains((Get-Content -Raw -LiteralPath $doubleClickReports[0].FullName).TrimEnd())) 'Double-click CMD displays the saved summary'
    $menu20Files = @{ 'sql\payload.pb' = 'select 1 from dual;' }
    for ($menuIndex = 1; $menuIndex -le 19; $menuIndex++) {
        $menu20Files[('sql\00-{0:D2}.sql' -f $menuIndex)] = '-- Other SQL file, not the selected master.'
    }
    $menu20Root = New-TestHotfix 'Menu twenty' "SET DEFINE ON`nstart payload.pb" $menu20Files
    $selection20 = Run-Interactive $checker @($menu20Root, '', '20') 'selection20' -VerifyKeepOpen
    Assert-True $selection20.HeldForClose 'Direct PowerShell launch stays alive after selecting master 20'
    Assert-Equal $selection20.ExitCode 1 'Selecting master 20 completes and preserves findings status'
    Assert-True ($selection20.Output -match [regex]::Escape('Selected master: ' + (Join-Path $menu20Root 'sql\master.sql'))) 'Master 20 is selected correctly'
    Assert-True ($selection20.Output -match 'Files called by master: 1') 'Standard DEFINE ON in master 20 does not erase direct matches'
    $failedInteractive = Run-Interactive $checker @((Join-Path $fixtures 'Clean'), '', '2') 'failed-interactive' -VerifyKeepOpen -ReportOverride $badReport
    Assert-True $failedInteractive.HeldForClose 'An unexpected interactive failure remains visible until Enter'
    Assert-Equal $failedInteractive.ExitCode 2 'Interactive failure preserves exit two after the wait'
    Assert-True ($failedInteractive.Output -match 'INCOMPLETE / FAILED:.*ReportDirectory must be outside') 'Interactive failure explains its actual cause'
    $noWait = Run-Interactive $checker @((Join-Path $fixtures 'Clean'), '', '2') 'no-pause' -NoFinalPause
    Assert-Equal $noWait.ExitCode 0 'Explicit NoPause preserves interactive audit result'
    Assert-True ($noWait.Output -notmatch 'Press Enter to close this window') 'Explicit NoPause disables the final script wait'

    $mixedName = 'ni' + [char]0x00F1 + 'o.pb'
    $retryRoot = New-TestHotfix 'Retry hotfix' 'placeholder' @{
        ('sql\' + $ansiName) = 'select 1 from dual;'; 'sql\child.sql' = ('@' + $mixedName)
        ('sql\' + $mixedName) = 'select 2 from dual;'
    }
    $retryMaster = Join-Path $retryRoot 'sql\Retry hotfix.sql'
    Move-Item -LiteralPath (Join-Path $retryRoot 'sql\master.sql') -Destination $retryMaster
    [IO.File]::WriteAllBytes($retryMaster, [Text.Encoding]::GetEncoding(1252).GetBytes($ansiText))
    [IO.File]::WriteAllText((Join-Path $retryRoot 'sql\child.sql'), ('@' + $mixedName), [Text.UTF8Encoding]::new($false))
    $retryHash = (Get-FileHash -LiteralPath $retryMaster -Algorithm SHA256).Hash
    $retryAccepted = Run-Interactive $checker @($retryRoot, '', 'Y') 'retry-accepted' -VerifyKeepOpen -Nested
    Assert-True $retryAccepted.HeldForClose 'Successful encoding retry retains the final interactive wait'
    Assert-Equal $retryAccepted.ExitCode 1 'Confirmed per-file retry preserves direct versus indirect coverage status'
    Assert-True ($retryAccepted.Output -notmatch 'Retry this file|Encoding retry Y/N|UTF-8 decoding failed for') 'Default encoding completes without a retry question or error screen'
    Assert-True ($retryAccepted.Output -match 'Files called by master: 2' -and $retryAccepted.Output -notmatch 'COULD NOT CHECK|Some content or calls could not be checked') 'Retry checks calls before and after the invalid UTF-8 byte'
    $retrySummaryFile = @(Get-ChildItem -LiteralPath (Join-Path $work 'retry-accepted-reports') -Filter 'summary_*.txt' -File -Recurse)
    $retrySummary = Get-Content -Raw -LiteralPath $retrySummaryFile[0].FullName
    Assert-Equal @([regex]::Matches($retrySummary, '(?m)^Encoding fallback:')).Count 1 'Automatic per-file fallback is recorded once and leaves UTF-8 child decoding unchanged'
    Assert-True $retryAccepted.Output.Contains($retrySummary.TrimEnd()) 'Retried console summary matches the single TXT'
    Assert-Equal (Get-FileHash -LiteralPath $retryMaster -Algorithm SHA256).Hash $retryHash 'Interactive retry preserves source bytes'
    $retryDetailed = Run-Interactive $checker @($retryRoot, '', 'Y') 'retry-mixed-details' -Nested -Detailed
    Assert-Equal $retryDetailed.ExitCode 1 'Mixed-encoding detailed audit completes with the same coverage status'
    $retryFilesCsv = @(Get-ChildItem -LiteralPath (Join-Path $work 'retry-mixed-details-reports') -Filter '*_files.csv' -File -Recurse)
    Assert-Equal $retryFilesCsv.Count 1 'Detailed retry writes exactly one hotfix files CSV'
    $retryMixedRow = @(Import-Csv -LiteralPath $retryFilesCsv[0].FullName | Where-Object { $_.RelativeFilePath -ceq ('sql\' + $mixedName) })
    Assert-Equal $retryMixedRow.Count 1 'UTF-8 child target retains its exact accented filename'
    Assert-Equal $retryMixedRow[0].IndirectCallCount 1 'Retrying the ANSI master leaves the UTF-8 child decoder unchanged'
    $retryStrict = Run-Interactive $checker @($retryRoot, '', 'Y') 'strict-encoding' -VerifyKeepOpen -StrictUtf8
    Assert-Equal $retryStrict.ExitCode 2 'Explicit UTF8 keeps invalid legacy bytes incomplete'
    Assert-True ($retryStrict.Output -match 'COULD NOT CHECK' -and $retryStrict.Output -notmatch '(?m)^Encoding fallback:|Retry this file') 'Explicit strict decoding never silently changes encoding or asks for a retry'
    $retryDoubleClick = Run-Interactive (Join-Path $launchCopy 'Hotfix-Checker.bat') @($retryRoot, '', 'Y', 'x') 'retry-double-click' $true
    Assert-Equal $retryDoubleClick.ExitCode 1 'Double-click BAT supports an encoding retry without extra arguments'
    Assert-True ($retryDoubleClick.Output -match 'Files called by master: 2' -and $retryDoubleClick.Output -match 'Press any key to continue') 'Double-click retry finishes coverage and retains its pause'
    $badBomRoot = New-TestHotfix 'Retry invalid BOM' 'placeholder' @{}
    $badBomMaster = Join-Path $badBomRoot 'sql\Retry invalid BOM.sql'
    Move-Item -LiteralPath (Join-Path $badBomRoot 'sql\master.sql') -Destination $badBomMaster
    [IO.File]::WriteAllBytes($badBomMaster, [byte[]]@(239, 187, 191, 160))
    $badBomInteractive = Run-Interactive $checker @($badBomRoot, '', 'Y') 'retry-bad-bom'
    Assert-Equal $badBomInteractive.ExitCode 2 'Malformed BOM-declared UTF-8 remains incomplete'
    Assert-True ($badBomInteractive.Output -notmatch 'Retry this file as Windows-1252\?') 'A declared Unicode BOM never receives an ANSI retry prompt'

    Write-Host 'Checking malicious data, path aliases, and report write protections.'
    $sharpName = 'stra' + [char]0x00DF + 'e.sql'
    $unicodeRoot = New-TestHotfix 'Unicode files' 'START strasse.sql' @{ ('sql\' + $sharpName) = '-- A different filename.' }
    Assert-Equal (Row (Audit-Path $unicodeRoot) ('sql\' + $sharpName)).DirectCallCount 0 'Unicode linguistic equivalence cannot satisfy a different filename'
    Set-Content -LiteralPath (Join-Path $unicodeRoot 'sql\strasse.sql') -Value 'select 1 from dual;' -Encoding UTF8
    $unicodeAudit = Audit-Path $unicodeRoot
    Assert-Equal $unicodeAudit.Rows.Count 2 'Distinct Unicode and ASCII filenames retain separate inventory rows'
    Assert-Equal (Row $unicodeAudit 'sql\strasse.sql').DirectCallCount 1 'Exact ASCII filename remains matched'
    Assert-Equal (Row $unicodeAudit ('sql\' + $sharpName)).DirectCallCount 0 'Exact match does not cover the Unicode lookalike'
    Set-Content -LiteralPath (Join-Path $unicodeRoot 'sql\master.sql') -Value @('START strasse.sql', ('START ' + $sharpName)) -Encoding UTF8
    Assert-Equal (Audit-Path $unicodeRoot).Repeated.Count 0 'Distinct filenames cannot become a false repeated target'
    $unicodeNested = New-Audit $unicodeRoot (Join-Path (Join-Path $unicodeRoot 'sql') $sharpName) (Join-Path $unicodeRoot 'sql') $true
    Set-Content -LiteralPath $unicodeNested.Master -Value '@strasse.sql' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $unicodeRoot 'sql\strasse.sql') -Value '@leaf.pb' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $unicodeRoot 'sql\leaf.pb') -Value 'select 1 from dual;' -Encoding UTF8
    Invoke-Audit $unicodeNested
    Assert-Equal (Row $unicodeNested 'sql\leaf.pb').DirectCallCount 0 'Unicode lookalike source is not mistaken for the selected master'
    Assert-Equal (Row $unicodeNested 'sql\leaf.pb').IndirectCallCount 1 'Unicode lookalike source still has its nested calls inspected'

    $unsafeCells = @('=1+1', '+1+1', '-1+1', '@SUM(1,1)', '   =1+1', '=1+2";,=1+2', ([string][char]0xFF1D + '1+1'))
    $csvPath = Join-Path $work 'unsafe-cells.csv'
    Write-ReportCsv @($unsafeCells | ForEach-Object { [pscustomobject]@{ Value = $_ } }) @('Value') $csvPath
    $csvValues = @(Import-Csv -LiteralPath $csvPath)
    Assert-Equal $csvValues.Count $unsafeCells.Count 'CSV quoting preserves one row for every untrusted value'
    for ($cellIndex = 0; $cellIndex -lt $unsafeCells.Count; $cellIndex++) {
        Assert-Equal $csvValues[$cellIndex].Value ('text:' + $unsafeCells[$cellIndex]) 'Formula-like CSV cells have a stable visible text prefix'
        Assert-Equal @($csvValues[$cellIndex].PSObject.Properties).Count 1 'Quote/separator payload cannot create extra CSV columns'
    }
    $escapeText = 'HOST echo ' + [char]27 + '[2J' + [char]0x202E + 'spoof'
    $escapeRoot = New-TestHotfix 'Terminal escape' $escapeText @{ 'sql\unused.pb' = 'select 1 from dual;' }
    $escapedRun = Run-Cli @('-HotfixPath', $escapeRoot, '-MasterPath', 'sql\master.sql', '-DetailedReport') 'terminal-controls'
    $escapedLog = Get-Content -Raw -LiteralPath $escapedRun.Log
    $escapedTxt = Get-Content -Raw -LiteralPath $escapedRun.SummaryPath
    Assert-True ($escapedLog.IndexOf([char]27) -lt 0 -and $escapedTxt.IndexOf([char]0x202E) -lt 0) 'CMD and TXT cannot execute terminal escapes or hide text direction'
    Assert-True ($escapedTxt.Contains('\u001B') -and $escapedTxt.Contains('\u202E')) 'Unsafe controls remain visible as escaped evidence'
    $noExecuteMarker = Join-Path $work 'must-not-execute.txt'
    $noExecuteRoot = New-TestHotfix 'Never execute' ('HOST echo bad > "' + $noExecuteMarker + '"') @{}
    [void](Audit-Path $noExecuteRoot)
    Assert-True (-not (Test-Path -LiteralPath $noExecuteMarker)) 'HOST source text cannot create files or execute commands'

    $protectedOutput = Join-Path $work 'protected-output.txt'
    Set-Content -LiteralPath $protectedOutput -Value 'Preserve these bytes.' -Encoding UTF8
    $protectedHash = (Get-FileHash -LiteralPath $protectedOutput -Algorithm SHA256).Hash
    $writeRejected = $false
    try { Write-ReportText $protectedOutput @('Overwrite attempt.') } catch { $writeRejected = $true }
    Assert-True $writeRejected 'Report writer refuses to overwrite an existing file'
    Assert-Equal (Get-FileHash -LiteralPath $protectedOutput -Algorithm SHA256).Hash $protectedHash 'Rejected write preserves the existing file bytes'
    $hardlinkReport = Join-Path $work 'hardlink-report.txt'
    [void](New-Item -ItemType HardLink -Path $hardlinkReport -Value $protectedOutput)
    $writeRejected = $false
    try { Write-ReportText $hardlinkReport @('Overwrite attempt.') } catch { $writeRejected = $true }
    Assert-True $writeRejected 'Report writer refuses a hardlink to an existing file'
    Assert-Equal (Get-FileHash -LiteralPath $protectedOutput -Algorithm SHA256).Hash $protectedHash 'Hardlink target cannot be overwritten by report creation'

    # Query the actual alias: renaming fixtures can change their 8.3 names.
    if (-not ('HotfixCheckerTestPaths' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Text;
using System.Runtime.InteropServices;
public static class HotfixCheckerTestPaths {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern uint GetShortPathName(string longPath, StringBuilder shortPath, uint capacity);
}
'@
    }
    $longRoot = Join-Path $fixtures 'Hotfix one'
    $shortBuffer = [Text.StringBuilder]::new(32768)
    $shortLength = [HotfixCheckerTestPaths]::GetShortPathName($longRoot, $shortBuffer, [uint32]$shortBuffer.Capacity)
    $shortRoot = if ($shortLength -gt 0 -and $shortLength -lt $shortBuffer.Capacity) { $shortBuffer.ToString() } else { '' }
    if ($shortRoot -and -not (Test-SamePath $shortRoot $longRoot) -and (Test-Path -LiteralPath $shortRoot -PathType Container)) {
        $savedReportAudits = $script:ReportAudits
        try {
            $script:ReportAudits = @((Audit-Fixture 'Hotfix one'))
            $aliasDestination = Join-Path $shortRoot 'must-not-create-alias-reports'
            $aliasRejected = $false
            try { Assert-ReportLocation $aliasDestination } catch { $aliasRejected = $_.Exception.Message -match 'outside ALL scanned hotfixes' }
            Assert-True $aliasRejected 'Physical report guard catches a Windows 8.3 hotfix alias'
            Assert-True (-not (Test-Path -LiteralPath $aliasDestination)) 'Short-name guard writes nothing to the hotfix'
        } finally { $script:ReportAudits = $savedReportAudits }
    } else { Write-Host 'SKIP: Windows did not provide a distinct short-name alias for the hotfix fixture.' }
    foreach ($invalidPath in @('\\.\NUL', '\\?\C:\probe', (Join-Path $work 'master.sql:secret.sql'), (Join-Path $work 'NUL.sql'),
        (Join-Path $work 'CON.txt'), (Join-Path $work 'COM1.sql'), (Join-Path $work 'CONIN$'), (Join-Path $work 'CONOUT$'),
        (Join-Path $work ('bad' + [char]27 + 'name')))) {
        $pathRejected = $false
        try { [void](Get-NormalPath $invalidPath) } catch { $pathRejected = $true }
        Assert-True $pathRejected ('Device, stream, or control-character path is rejected: ' + (ConvertTo-SafeText $invalidPath))
    }

    $spoofRoot = 'C:\invalid' + "`nResult: Completed with no findings."
    $spoofAudit = New-Audit $spoofRoot ('sql\bad' + "`nmaster.sql") ("`nWorking spoof") $false
    $spoofAudit.InputError = 'Invalid path.'; $spoofAudit.NormalizedRoot = $false
    Invoke-Audit $spoofAudit
    $spoofSummary = Get-Summary $spoofAudit
    Assert-Equal @([regex]::Matches($spoofSummary, '(?m)^Result:')).Count 1 'Malformed CSV input cannot inject a second result into a detailed summary'
    Assert-True ($spoofSummary.Contains('\u000AResult:') -and $spoofSummary.Contains('\u000AWorking spoof')) 'Invalid input line breaks remain visible as evidence'

    $largeRoot = New-TestHotfix 'Large script' 'placeholder' @{ 'sql\payload.pb' = 'select 1 from dual;' }
    [IO.File]::WriteAllText((Join-Path $largeRoot 'sql\master.sql'), "@payload.pb`n--" + [string]::new('a', 1MB), [Text.UTF8Encoding]::new($false))
    $limitedRun = Run-Cli @('-HotfixPath', $largeRoot, '-MasterPath', 'sql\master.sql', '-MaxScriptSizeMB', '1') 'large-limited'
    Assert-Equal $limitedRun.ExitCode 2 'Oversized input produces an incomplete check instead of unbounded allocation'
    $limitedSummary = Get-Content -Raw -LiteralPath $limitedRun.SummaryPath
    Assert-True ($limitedSummary -match 'COULD NOT CHECK' -and $limitedSummary -match 'exceeds the 1 MB read limit') 'Size limit explains why coverage is unavailable'
    $largerLimitRun = Run-Cli @('-HotfixPath', $largeRoot, '-MasterPath', 'sql\master.sql', '-MaxScriptSizeMB', '2') 'large-allowed'
    Assert-Equal $largerLimitRun.ExitCode 0 'Increasing the explicit size limit preserves legitimate larger scripts'
    foreach ($bomPage in @(65001, 1200, 1201, 12000, 12001)) {
        $bomRoot = New-TestHotfix ('BOM-' + $bomPage) 'placeholder' @{ 'sql\payload.pb' = 'select 1 from dual;' }
        $bomEncoding = [Text.Encoding]::GetEncoding($bomPage)
        [IO.File]::WriteAllBytes((Join-Path $bomRoot 'sql\master.sql'), ($bomEncoding.GetPreamble() + $bomEncoding.GetBytes('@payload.pb')))
        Assert-Equal (Audit-Path $bomRoot).ExitCode 0 'Strict decoding recognizes every supported Unicode BOM'
    }
    Assert-Equal (Fixture-Hashes) $before 'All fixture file paths and bytes remain unchanged'
    Write-Host ("PASS: $script:assertions assertions. Logs/reports: $work")
    exit 0
} catch {
    Write-Host ('FAIL: ' + $_.Exception.Message)
    Write-Host $_.ScriptStackTrace
    Write-Host ('Artifacts retained at: ' + $work)
    exit 1
}
