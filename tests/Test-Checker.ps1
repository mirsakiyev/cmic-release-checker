#requires -Version 5.1
# No Pester, modules, SQL*Plus, or third-party test dependencies are needed.
$ErrorActionPreference = 'Stop'
$checker = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Check-Release.ps1'))
$launcher = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Check-Release.bat'))
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
function New-TestRelease([string]$Name, [string]$MasterText, [hashtable]$Files) {
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
    $folders = @(); if (Test-Path -LiteralPath $reportRoot) { $folders = @(Get-ChildItem -LiteralPath $reportRoot -Directory) }
    $folder = if ($folders.Count) { $folders[0].FullName } else { '' }
    return [pscustomobject]@{ ExitCode = $processCode; Folder = $folder; Log = $log }
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
    $expected = @(Import-Csv -LiteralPath (Join-Path $testRoot 'expected-release-one.csv'))
    foreach ($nested in @($false, $true)) {
        $audit = Audit-Fixture 'Release one' $nested
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
        Assert-Equal @($audit.References | Where-Object { $_.Status -eq 'Ambiguous' }).Count 0 'Direct bare filenames cover exact copies across release folders'
        Assert-Equal @($audit.References | Where-Object { $_.Status -eq 'MissingInRelease' }).Count 2 'Wrong explicit path and missing call both reported'
        Assert-Equal @($audit.References | Where-Object { $_.Target -eq 'wrong\py_post.pb' -and $_.Status -eq 'MissingInRelease' }).Count 1 'Wrong path cannot use basename fallback'
        Assert-Equal @($audit.References | Where-Object { $_.LineNumber -eq 18 -and $_.Target -eq 'py_post.pb' }).Count 1 'Original source line retained'
        $quoted = @($audit.References | Where-Object { $_.Target -eq 'subfolder\script with spaces.pb' })[0]
        Assert-Equal $quoted.Arguments 'argument1 "argument two"' 'Arguments are separate from quoted target'
        Assert-True ((Row $audit 'docs\unique.DATA').Notes -match 'runtime SQL\*Plus lookup is not established') 'Unique filename caveat appears in CSV'
        Assert-Equal @($audit.References | Where-Object { $_.Cycle }).Count $(if ($nested) { 1 } else { 0 }) 'Cycle detection stops recursion'
        Assert-Equal $audit.Repeated.Count $(if ($nested) { 4 } else { 3 }) 'Repeated static calls grouped per matching release file'
        Assert-Equal @($audit.References | Where-Object { $_.SourceFile -like '*unrelated.sql' }).Count 0 'Unrelated scripts never contribute coverage'
        if ($nested) {
            $indirect = Row $audit 'sql\subfolder\indirect.sql'
            Assert-True ($indirect.CallChains -match 'master.sql:22 -> sql\\subfolder\\post_install.sql:1') 'Indirect chain contains master and caller lines'
            Assert-True ((Get-Summary $audit) -match 'Files not directly referenced: 11') 'Indirectly called file remains in not-direct total'
        }
    }
    Assert-Equal (Audit-Fixture 'Clean').ExitCode 0 'Clean fixture exit zero'
    Assert-Equal (Audit-Fixture 'Clean' $true).ExitCode 0 'Clean nested audit exit zero'
    $second = Audit-Fixture 'Release two'
    Assert-Equal $second.ExitCode 1 'Completed fixture with findings exit one'
    Assert-Equal $second.References[0].Status 'MissingInRelease' 'Another release cannot satisfy a missing call'

    $settingsDirect = Audit-Fixture 'Settings'
    Assert-Equal (Row $settingsDirect 'sql\default_name.sql').DirectReferenceStatus 'DirectlyReferenced' 'Direct mode uses declared default assumptions only'
    $settingsNested = Audit-Fixture 'Settings' $true
    Assert-Equal $settingsNested.ExitCode 2 'Nested suffix setting makes audit incomplete'
    Assert-Equal (Row $settingsNested 'sql\default_name.sql').DirectReferenceStatus 'NoDirectReferenceFound' 'Nested setting invalidates prior default suffix matches'
    Assert-Equal (Row $settingsNested 'sql\default_name.pb').DirectReferenceStatus 'NoDirectReferenceFound' 'No alternate extension guessed'
    Assert-True (@($settingsNested.References | Where-Object { $_.Status -eq 'Unresolved' -and $_.Target -eq 'default_name' }).Count -eq 1) 'Extensionless target is manual review'

    $context = New-TestRelease 'Context' '@@sub\driver.sql' @{
        'sql\sub\driver.sql' = "@@leaf.sql`n@leaf.sql`nSTART leaf.sql"
        'sql\sub\leaf.sql' = 'select 1 from dual;'
        'working\leaf.sql' = 'select 2 from dual;'
    }
    $contextAudit = Audit-Path $context $true (Join-Path $context 'working')
    Assert-Equal (Row $contextAudit 'sql\sub\leaf.sql').IndirectCallCount 1 '@@ uses its caller directory'
    Assert-Equal (Row $contextAudit 'working\leaf.sql').IndirectCallCount 2 'START/@ retain override working directory in nested scripts'
    Assert-Equal @($contextAudit.References | Where-Object { $_.Status -eq 'Ambiguous' }).Count 0 'Path context disambiguates duplicate basenames'

    $absolute = New-TestRelease 'Absolute' '-- placeholder' @{ 'payload.bintext' = 'select 1 from dual;' }
    $outside = Join-Path $work 'Outside\external.sql'
    Set-Content -LiteralPath (Join-Path $absolute 'sql\master.sql') -Encoding UTF8 -Value @(
        ('start "' + (Join-Path $absolute 'sql\..\payload.bintext') + '"'),
        ('@"' + $outside + '"'), '@\\nonexistent-checker-host\share\external.sql',
        '@https://example.invalid/external.sql?x=1&y=2'
    )
    $absoluteAudit = Audit-Path $absolute
    Assert-Equal (Row $absoluteAudit 'payload.bintext').MatchingMethod 'AbsolutePath' 'Normalized absolute path resolves'
    Assert-Equal @($absoluteAudit.References | Where-Object { $_.Status -eq 'OutsideRelease' }).Count 3 'Absolute external, UNC, URL separated without probing'
    Assert-Equal $absoluteAudit.ExitCode 1 'External reference findings do not claim machine-wide absence'
    Assert-True (-not (Test-InRoot ($absolute + 'Sibling\file.sql') $absolute)) 'Root boundary does not accept a prefix sibling'

    $manual = New-TestRelease 'Manual' "host echo unsupported`n! echo unsupported`n:r child.sql`n@&name`nstart -`nchild.sql`nSTART`n@'unterminated`n@child.sql" @{ 'sql\child.sql' = 'select 1 from dual;' }
    $manualAudit = Audit-Path $manual
    Assert-Equal @($manualAudit.References | Where-Object { $_.Status -eq 'Unsupported' }).Count 3 'HOST, !, and SQLCMD :r require review'
    Assert-Equal @($manualAudit.References | Where-Object { $_.Status -eq 'Unresolved' }).Count 4 'Variable, continuation, missing operand, unclosed target require review'
    Assert-Equal (Row $manualAudit 'sql\child.sql').DirectCallCount 1 'Malformed command does not hide later valid call'
    Assert-Equal $manualAudit.ExitCode 2 'Unsupported commands cannot yield a clean audit'
    $concat = New-TestRelease 'Concatenation' "start 'child' || '.sql'" @{ 'sql\child.sql' = 'select 1 from dual;' }
    Assert-Equal (Audit-Path $concat).References[0].Status 'Unresolved' 'Possible filename concatenation requires review'
    $sqlClause = New-TestRelease 'SqlClause' "select id from tree`nSTART WITH id=1`nconnect by prior id=parent_id;" @{ 'sql\with.sql' = 'select 1 from dual;' }
    Assert-Equal (Row (Audit-Path $sqlClause) 'sql\with.sql').DirectCallCount 0 'SQL START WITH clause cannot call a file named with.sql'
    Assert-Equal (Audit-Path $sqlClause).ExitCode 2 'START WITH clause or unquoted WITH target requires review'
    $extensionless = New-TestRelease 'Extensionless' '@payload' @{ 'sql\payload.pb' = 'select 1 from dual;'; 'sql\payload.ps' = 'select 1 from dual;' }
    $extensionlessAudit = Audit-Path $extensionless
    Assert-Equal $extensionlessAudit.References[0].Status 'MissingInRelease' 'Extensionless target never guesses .pb or .ps'
    Assert-True ($extensionlessAudit.References[0].ResolvedPath.EndsWith('payload.sql')) 'Missing extensionless target records assumed .sql path'
    $freeText = New-TestRelease 'FreeText' "REM q'[`nPROMPT 'never closed`nSPOOL Bob's.log`n@child.sql" @{ 'sql\child.sql' = 'select 1 from dual;' }
    Assert-Equal (Audit-Path $freeText).ExitCode 0 'Free-text comments/logging quotes do not hide calls'
    $controlText = New-TestRelease 'Control text' "@first.sql`nPAUSE Don't continue before checking the backup`nSET SQLPROMPT Developer's DB>`nCONNECT user/secret'@database`nSTART second.pb`nselect 'multiline SQL:`nSTART decoy.pb`n' from dual;`nselect q'[alternate SQL:`n@decoy.pb`n]' from dual;`n-- START decoy.pb`n/* START decoy.pb */" @{
        'sql\first.sql' = 'select 1 from dual;'; 'sql\second.pb' = 'select 2 from dual;'; 'sql\decoy.pb' = 'select 3 from dual;'
    }
    $controlAudit = Audit-Path $controlText
    Assert-Equal $controlAudit.Issues.Count 0 'SQL*Plus free text cannot poison subsequent SQL literal state'
    Assert-Equal (Row $controlAudit 'sql\first.sql').DirectCallCount 1 'Early master call remains visible before control text'
    Assert-Equal (Row $controlAudit 'sql\second.pb').DirectCallCount 1 'START after unpaired control-text punctuation is detected'
    Assert-Equal (Row $controlAudit 'sql\decoy.pb').DirectCallCount 0 'Real SQL strings, alternate strings and comments still never count as calls'
    $dynamicSql = New-TestRelease 'Multiline execute immediate' "@first.sql`nBEGIN`n  EXECUTE IMMEDIATE '`n    CREATE TABLE DA.UETD_FLY_EMAILS`n    (AUTHOR VARCHAR2(300))`n    -- START decoy.pb`n    START decoy.pb`n    /* @decoy.pb */`n    TABLESPACE USERS';`n  DBMS_OUTPUT.PUT_LINE('Table Created');`nEND;`n/`nselect 'TIMESTAMPER End Table Update' || to_char(systimestamp, 'YYYY-MON-DD HH24:MI:SSSS') `" `" from dual;`nSTART aputil.ps;`nstart uigtoolsmessage.dat`nstart JSR_PYCHK01C.pb`nUPDATE settings`nSET value = 'multiline value:`nSTART decoy.pb`n'`nWHERE code = 'X';`nSTART final.sql" @{
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
    $copiesRoot = New-TestRelease 'Cross-folder calls' "START APERROR.DAT`n@`"poerror.dat`"`nstart ..\uig\sql\explicit.pb`n@@caller.pb`nSTART missing\lookalike.pb`nPROMPT START decoy.pb`nselect 'START decoy.pb' from dual;" @{
        'sql\aperror.dat' = 'DA data'; 'uig\sql\aperror.dat' = 'UIG data'; 'cf\sql\aperror.dat' = 'CF data'
        'sql\poerror.dat' = 'DA po'; 'uig\sql\poerror.dat' = 'UIG po'; 'sql\old_aperror.dat' = 'lookalike'
        'sql\explicit.pb' = 'wrong copy'; 'uig\sql\explicit.pb' = 'right copy'
        'sql\caller.pb' = 'caller copy'; 'uig\sql\caller.pb' = 'other copy'
        'sql\lookalike.pb' = 'wrong explicit path'; 'uig\sql\decoy.pb' = 'not called'
    }
    $copiesAudit = Audit-Path $copiesRoot
    foreach ($copyPath in @('sql\aperror.dat','uig\sql\aperror.dat','cf\sql\aperror.dat','sql\poerror.dat','uig\sql\poerror.dat')) {
        Assert-Equal (Row $copiesAudit $copyPath).DirectCallCount 1 'A bare filename directly called in the master covers every exact-name release copy'
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
    $badBlock = New-TestRelease 'BadBlock' "/* unterminated`n@child.sql" @{ 'sql\child.sql' = 'select 1 from dual;' }
    Assert-Equal (Audit-Path $badBlock).ExitCode 2 'Unterminated block comment makes analysis incomplete'
    Assert-True ((Audit-Path $badBlock).Issues[0].Message -match 'block comment opened at line 1') 'Unclosed comment reports its opening line'
    $badLiteral = New-TestRelease 'Bad literal' "-- heading`nselect 'unterminated`nSTART child.sql" @{ 'sql\child.sql' = 'select 1 from dual;' }
    $badLiteralAudit = Audit-Path $badLiteral
    Assert-Equal (Row $badLiteralAudit 'sql\child.sql').DirectCallCount 0 'An unclosed real SQL literal does not count its embedded START text'
    Assert-True ($badLiteralAudit.Issues[0].Message -match "SQL literal opened at line 2.*select 'unterminated") 'Unclosed SQL literal reports its opening line and source'
    $changedSyntax = New-TestRelease 'SyntaxSetting' "set def ^`n@child.sql" @{ 'sql\child.sql' = 'select 1 from dual;' }
    Assert-Equal (Audit-Path $changedSyntax).References[0].Status 'Unresolved' 'Custom substitution setting prevents confident matching'
    $standardDefine = New-TestRelease 'StandardDefine' "START first.pb`nset define on`n@second.ps`nset def off`n@second.ps`n@&dynamic" @{
        'sql\first.pb' = 'select 1 from dual;'; 'sql\second.ps' = 'select 2 from dual;'
    }
    $standardDefineAudit = Audit-Path $standardDefine
    Assert-Equal (Row $standardDefineAudit 'sql\first.pb').DirectCallCount 1 'SET DEFINE ON preserves literal calls before the setting'
    Assert-Equal (Row $standardDefineAudit 'sql\second.ps').DirectCallCount 2 'SET DEFINE ON/OFF preserves literal calls after the settings'
    Assert-Equal $standardDefineAudit.Issues.Count 0 'Standard DEFINE toggles do not invalidate the parser'
    Assert-Equal @($standardDefineAudit.References | Where-Object { $_.Status -eq 'Unresolved' }).Count 1 'Variable-bearing call still requires review'
    $nestedDefine = New-TestRelease 'NestedDefine' "@child.sql`n@leaf.pb" @{
        'sql\child.sql' = 'set define on'; 'sql\leaf.pb' = 'select 1 from dual;'
    }
    Assert-Equal (Audit-Path $nestedDefine $true).ExitCode 0 'Standard DEFINE toggle in a nested script preserves literal graph matches'

    $foreign = New-TestRelease 'Foreign' '@payload.ps1' @{ 'sql\payload.ps1' = "throw 'Do not execute me'" }
    Assert-Equal (Audit-Path $foreign).ExitCode 0 'Any explicit extension remains eligible for direct matching'
    Assert-Equal (Audit-Path $foreign $true).ExitCode 2 'Unsupported nested language is incomplete'
    $binary = New-TestRelease 'Binary' '@child.pb' @{ 'sql\child.pb' = 'placeholder' }
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
    $encoded = New-TestRelease 'Encoding' '@child.sql' @{ 'sql\child.sql' = 'select 1 from dual;' }
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
    $ansiRoot = New-TestRelease 'ANSI master bytes' 'placeholder' @{
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
    $ansiBomRoot = New-TestRelease 'ANSI option BOM override' ('@' + $ansiName) @{ ('sql\' + $ansiName) = 'select 1 from dual;' }
    Assert-Equal (Audit-Path $ansiBomRoot).ExitCode 0 'UTF-8 BOM overrides an explicitly selected Windows1252 encoding'
    $binaryRoot = New-TestRelease 'ANSI binary guard' 'placeholder' @{}
    [IO.File]::WriteAllBytes((Join-Path $binaryRoot 'sql\master.sql'), [byte[]]@(64, 0, 65))
    Assert-Equal (Audit-Path $binaryRoot).ExitCode 2 'Explicit ANSI decoding retains binary/NUL rejection'
    $ScriptEncoding = 'Auto'
    Assert-Equal (Get-FileHash -LiteralPath $ansiMaster -Algorithm SHA256).Hash $ansiHash 'Encoding choices never change source script bytes'

    $linkRoot = New-TestRelease 'Links' 'select 1 from dual;' @{}
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
    $plainSqlRoot = New-TestRelease 'Plain SQL workload' ($longPlainLine + "`nPROMPT @decoy.pb`n@payload.pb") @{
        'sql\payload.pb' = 'select 1 from dual;'; 'sql\decoy.pb' = 'select 2 from dual;'
    }
    $plainSqlAudit = Audit-Path $plainSqlRoot
    Assert-Equal (Row $plainSqlAudit 'sql\payload.pb').DirectCallCount 1 'Long ordinary SQL lines preserve subsequent active calls'
    Assert-Equal (Row $plainSqlAudit 'sql\decoy.pb').DirectCallCount 0 'Free-text commands remain excluded in optimized lexing'

    Write-Host 'Core assertions passed; checking real launcher, reports and automation exits.'
    $cleanRun = Run-Cli @('-ReleasePath', (Join-Path $fixtures 'Clean'), '-MasterPath', 'sql\master.sql', '-NonInteractive') 'clean-batch' $true
    Assert-Equal $cleanRun.ExitCode 0 'BAT launcher preserves exit zero and accepts spaces'
    Assert-Equal @(Get-ChildItem -LiteralPath $cleanRun.Folder -File).Count 1 'Default run creates exactly one file'
    $cleanSummary = Get-Content -Raw -LiteralPath (Join-Path $cleanRun.Folder 'summary.txt')
    Assert-True ($cleanSummary -match 'Result: YES - all checked files are called by the master\.' -and $cleanSummary -match 'Files called by master: 1' -and $cleanSummary -match 'Files with no matching call: 0') 'Clean summary directly answers file coverage'
    Assert-True ((Get-Content -Raw -LiteralPath $cleanRun.Log).Contains($cleanSummary.TrimEnd())) 'CMD prints the same summary saved in the TXT'
    $progressLog = Get-Content -Raw -LiteralPath $cleanRun.Log
    Assert-True ($progressLog -match '(?s)Validating release and master paths.*Scanning release folders.*Inventory complete: 2 files.*Reading master and checking calls.*Preparing coverage results.*Saving summary') 'Real CMD run reports validation, inventory, parsing, and writing stages'
    Assert-True ($cleanSummary -notmatch 'Detected resolved calls|CallChains|Unresolved / manual review|combined totals') 'Default summary omits detailed call trace sections'
    $ansiAutoRun = Run-Cli @('-ReleasePath', $ansiRoot, '-MasterPath', 'sql\master.sql', '-NonInteractive') 'ansi-auto-cmd' $true
    Assert-Equal $ansiAutoRun.ExitCode 0 'CMD automatic encoding completes without an encoding response'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $ansiAutoRun.Folder 'summary.txt')) -match 'Encoding fallback:.*Windows1252' ) 'Automatic encoding choice is recorded in the single summary'
    Assert-True ((Get-Content -Raw -LiteralPath $ansiAutoRun.Log) -notmatch 'Encoding retry Y/N|Retry this file') 'Automatic CMD run never requests encoding confirmation'
    $ansiFailureRun = Run-Cli @('-ReleasePath', $ansiRoot, '-MasterPath', 'sql\master.sql', '-ScriptEncoding', 'UTF8') 'ansi-guidance'
    Assert-Equal $ansiFailureRun.ExitCode 2 'Real process keeps incomplete status for invalid UTF-8'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $ansiFailureRun.Folder 'summary.txt')) -match 'Check-Release.bat -ScriptEncoding Default') 'Saved failed summary includes the executable ANSI workaround'
    Assert-True ((Get-Content -Raw -LiteralPath $ansiFailureRun.Log) -notmatch 'Retry this file as Windows-1252\?') 'Batch paths never prompt for an encoding retry'
    $ansiSuccessRun = Run-Cli @('-ReleasePath', $ansiRoot, '-MasterPath', 'sql\master.sql', '-ScriptEncoding', 'Windows1252') 'ansi-cmd' $true
    Assert-Equal $ansiSuccessRun.ExitCode 0 'CMD launcher forwards the explicit Windows1252 encoding'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $ansiSuccessRun.Folder 'summary.txt')) -match 'Files called by master: 2') 'Explicit ANSI CMD run reports the complete file coverage'
    $uncalledRoot = New-TestRelease 'UncalledFile' 'select 1 from dual;' @{ 'sql\unused.sql' = 'select 2 from dual;' }
    $findingRun = Run-Cli @('-ReleasePath', $uncalledRoot, '-MasterPath', 'sql\master.sql') 'findings-batch' $true
    Assert-Equal $findingRun.ExitCode 1 'BAT launcher preserves findings exit one'
    $findingSummary = Get-Content -Raw -LiteralPath (Join-Path $findingRun.Folder 'summary.txt')
    Assert-True ($findingSummary -match 'Result: NO - 1 file\(s\)' -and $findingSummary -match '  sql\\unused\.sql') 'Missing coverage is clearly identified by relative filename'
    Assert-True ($findingSummary -notmatch '\[NoDirectReferenceFound; NotChecked\]') 'Missing file list has no internal status annotations'
    $simplePartial = Run-Cli @('-ReleasePath', (Join-Path $fixtures 'Release one'), '-MasterPath', 'sql\master.sql') 'simple-incomplete' $true
    $partialSummary = Get-Content -Raw -LiteralPath (Join-Path $simplePartial.Folder 'summary.txt')
    Assert-Equal $simplePartial.ExitCode 2 'Simple summary preserves incomplete coverage status'
    Assert-Equal @(Get-ChildItem -LiteralPath $simplePartial.Folder -File).Count 1 'Incomplete default run still creates only one TXT'
    Assert-True ($partialSummary -match 'Files checked: 27' -and $partialSummary -match 'Files called by master: 16' -and $partialSummary -match 'Files with no matching call: 11') 'Simple counts include every exact basename directly called in the master'
    Assert-True ($partialSummary -match 'Some content or calls could not be checked' -and $partialSummary -notmatch 'Result: YES') 'Unresolved calls cannot produce a false clean result'
    $partialList = ($partialSummary -split 'Files with no matching call in the master:\r?\n')[1] -split '\r?\n\r?\nSummary saved to:' | Select-Object -First 1
    Assert-Equal @($partialList -split '\r?\n' | Where-Object { $_.Trim() }).Count 11 'All 11 uncalled files appear once in the plain list'
    Assert-True ($partialList -match '(?m)^  sql\\subfolder\\indirect\.sql\r?$' -and $partialList -notmatch '(?m)^  sql\\py_post\.pb\r?$') 'List includes indirectly called files and excludes direct matches'
    $coveredExtras = New-TestRelease 'CoveredExtras' "@child.sql`n@child.sql`n@not-in-release.sql" @{ 'sql\child.sql' = 'select 1 from dual;' }
    $coverageOnly = Run-Cli @('-ReleasePath', $coveredExtras, '-MasterPath', 'sql\master.sql') 'coverage-only'
    Assert-Equal $coverageOnly.ExitCode 0 'Default mode checks coverage without treating extra or repeated targets as uncalled release files'
    $detailedExtras = Run-Cli @('-ReleasePath', $coveredExtras, '-MasterPath', 'sql\master.sql', '-DetailedReport') 'covered-details'
    Assert-Equal $detailedExtras.ExitCode 1 'Detailed mode retains extra-target and repetition findings'
    $nestedRun = Run-Cli @('-ReleasePath', (Join-Path $fixtures 'Release one'), '-MasterPath', 'sql\master.sql', '-IncludeNested', '-DetailedReport') 'nested-batch' $true
    Assert-Equal $nestedRun.ExitCode 2 'BAT launcher preserves incomplete exit two'
    $fileCsv = @(Import-Csv -LiteralPath (Join-Path $nestedRun.Folder '01_Release_one_files.csv'))
    $refCsv = @(Import-Csv -LiteralPath (Join-Path $nestedRun.Folder '01_Release_one_references.csv'))
    Assert-Equal $fileCsv.Count 27 'Report has exactly one row per eligible file'
    Assert-Equal $refCsv.Count 25 'References CSV contains every matching file for direct and reached calls'
    Assert-Equal @($fileCsv | Where-Object { $_.AuditStatus -eq 'Incomplete' }).Count 27 'Export preserves audit status'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $nestedRun.Folder '01_Release_one_summary.txt')) -match 'Unresolved / manual review') 'Text report includes manual review section'
    Assert-True ((Get-Content -Raw -LiteralPath $nestedRun.Log) -match [regex]::Escape($nestedRun.Folder)) 'Console shows full report paths'
    Assert-True ((Get-Content -Raw -LiteralPath $nestedRun.Log) -notmatch 'Press Enter to close this window') 'Noninteractive automation has no final wait'
    $repeatRun = Run-Cli @('-ReleasePath', (Join-Path $fixtures 'Clean'), '-MasterPath', 'sql\master.sql') 'clean-batch' $true
    Assert-True ($repeatRun.Folder -ne $cleanRun.Folder -or @(Get-ChildItem -LiteralPath (Split-Path -Parent $cleanRun.Folder) -Directory).Count -eq 2) 'Previous run is preserved'

    $inputFile = Join-Path $work 'inputs.csv'
    @(
        [pscustomobject]@{ ReleasePath = (Join-Path $fixtures 'Release one'); MasterPath = 'sql\master.sql'; WorkingDirectory = '' },
        [pscustomobject]@{ ReleasePath = (Join-Path $fixtures 'Release two'); MasterPath = 'sql\master.sql'; WorkingDirectory = '' },
        [pscustomobject]@{ ReleasePath = $gone; MasterPath = 'sql\master.sql'; WorkingDirectory = '' }
    ) | Export-Csv -LiteralPath $inputFile -NoTypeInformation -Encoding UTF8
    $simpleMulti = Run-Cli @('-InputCsv', $inputFile) 'simple-multiple'
    Assert-Equal $simpleMulti.ExitCode 2 'Single summary preserves invalid release status while checking other releases'
    Assert-Equal @(Get-ChildItem -LiteralPath $simpleMulti.Folder -File).Count 1 'Multiple releases are collected in one TXT'
    $multiSummary = Get-Content -Raw -LiteralPath (Join-Path $simpleMulti.Folder 'summary.txt')
    Assert-Equal @([regex]::Matches($multiSummary, '(?m)^Release:')).Count 3 'One TXT includes a separate coverage summary for every selected release'
    Assert-True ($multiSummary -match 'Releases checked: 3' -and $multiSummary -match 'Result: COULD NOT CHECK') 'Failed release cannot look like complete zero-file coverage'
    Assert-True ((Get-Content -Raw -LiteralPath $simpleMulti.Log).Contains($multiSummary.TrimEnd())) 'Multiple-release CMD summary matches the one TXT'
    $multi = Run-Cli @('-InputCsv', $inputFile, '-DetailedReport') 'multiple'
    Assert-Equal $multi.ExitCode 2 'Combined incomplete status takes precedence'
    Assert-Equal @(Get-ChildItem -LiteralPath $multi.Folder -Filter '*_files.csv').Count 3 'Independent report for each release including invalid release'
    $combined = Get-Content -Raw -LiteralPath (Join-Path $multi.Folder 'combined_summary.txt')
    Assert-True ($combined -match 'Releases reviewed: 3' -and $combined -match 'Eligible files checked: 27' -and $combined -match 'Files directly referenced: 16') 'Combined totals are correct and readable'
    Assert-True ($combined -match 'Ambiguous references: 0' -and $combined -match 'Call targets not found within scanned releases: 3') 'Combined reference findings are totaled'
    Assert-True ($combined -match 'Files referenced only indirectly: Not checked') 'Direct-only combined report does not imply nested checking'
    Assert-Equal @(Import-Csv -LiteralPath (Join-Path $multi.Folder '03_Nonexistent_files.csv')).Count 0 'Failed audit still has header-only CSV'
    $failure = Run-Cli @('-ReleasePath', (Join-Path $fixtures 'Clean'), '-MasterPath', 'sql\absent.sql') 'missing-master'
    Assert-Equal $failure.ExitCode 2 'Missing master produces incomplete reports'
    $failureSummary = Get-Content -Raw -LiteralPath (Join-Path $failure.Folder 'summary.txt')
    Assert-True ($failureSummary -match 'COULD NOT CHECK' -and $failureSummary -match 'Selected master does not exist' -and $failureSummary -notmatch 'Result: YES') 'Simple failure summary explains why coverage is unavailable'
    $lock = New-Object IO.FileStream($lockedMaster, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $lockedRun = Run-Cli @('-ReleasePath', $lockedRoot, '-MasterPath', 'sql\master.sql') 'locked-summary'
        $lockedSummary = Get-Content -Raw -LiteralPath (Join-Path $lockedRun.Folder 'summary.txt')
        Assert-Equal $lockedRun.ExitCode 2 'Locked master preserves incomplete exit in simple mode'
        Assert-True ($lockedSummary -match 'COULD NOT CHECK' -and $lockedSummary -notmatch 'Files with no matching call: 0|Result: YES') 'Unreadable master never produces a misleading coverage summary'
    } finally { $lock.Dispose() }
    $outsideMaster = Run-Cli @('-ReleasePath', (Join-Path $fixtures 'Clean'), '-MasterPath', (Join-Path $fixtures 'Release one\sql\master.sql')) 'outside-master'
    Assert-Equal $outsideMaster.ExitCode 2 'Manual/batch master must remain within its release'

    $badReport = Join-Path $fixtures 'Clean\must-not-create-reports'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checker -ReleasePath (Join-Path $fixtures 'Clean') -MasterPath 'sql\master.sql' -ReportDirectory $badReport > (Join-Path $work 'bad-report.log') 2>&1
    Assert-Equal $LASTEXITCODE 2 'Reports inside release refused'
    Assert-True (-not (Test-Path -LiteralPath $badReport)) 'Report guard runs before any release write'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checker -ReleasePath (Split-Path -Parent $checker) -MasterPath 'tests\fixtures\Clean\sql\master.sql' > (Join-Path $work 'utility-inside.log') 2>&1
    Assert-Equal $LASTEXITCODE 2 'Utility inside scanned release refused'
    $reportLink = Join-Path $work 'report-link'
    [void](New-Item -ItemType Junction -Path $reportLink -Value (Join-Path $fixtures 'Clean'))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checker -ReleasePath (Join-Path $fixtures 'Clean') -MasterPath 'sql\master.sql' -ReportDirectory $reportLink > (Join-Path $work 'report-link.log') 2>&1
    Assert-Equal $LASTEXITCODE 2 'Report junction cannot bypass outside-release rule'
    # One malformed input must not prevent other release rows from being audited.
    @(
        [pscustomobject]@{ ReleasePath = 'C:relative'; MasterPath = 'sql\master.sql' },
        [pscustomobject]@{ ReleasePath = (Join-Path $fixtures 'Clean'); MasterPath = 'sql\master.sql' }
    ) | Export-Csv -LiteralPath $inputFile -NoTypeInformation -Encoding UTF8
    $badInput = Run-Cli @('-InputCsv', $inputFile, '-DetailedReport') 'bad-input'
    Assert-Equal $badInput.ExitCode 2 'Malformed release path recorded as failure'
    Assert-Equal @(Import-Csv -LiteralPath (Join-Path $badInput.Folder '02_Clean_files.csv')).Count 1 'Valid release after malformed path is still audited'

    $interactiveRoot = New-TestRelease 'Interactive one' '@payload.pb' @{
        'sql\01-decoy.sql' = 'select 1 from dual;'; 'sql\payload.pb' = 'select 2 from dual;'
    }
    $manualRoot = New-TestRelease 'Interactive two' 'select 1 from dual;' @{
        'manual\chosen.sql' = '@@leaf.sql'; 'manual\leaf.sql' = 'select 2 from dual;'
    }
    $interactive = Run-Interactive $checker @($gone, $interactiveRoot, $interactiveRoot, ($interactiveRoot + '\'), $manualRoot, '', '99', '2', 'M', $lockedMaster, 'M', 'manual\chosen.sql') 'interactive'
    Assert-Equal $interactive.ExitCode 1 'Interactive multiple-release workflow completes with findings'
    Assert-True ($interactive.Output -match 'Invalid release:' -and $interactive.Output -match 'Invalid master:') 'Interactive validation re-prompts for bad input'
    Assert-True ($interactive.Output -match [regex]::Escape('Selected master: ' + (Join-Path $interactiveRoot 'sql\master.sql'))) 'Master selected by number, not default first SQL file'
    Assert-True ($interactive.Output -match [regex]::Escape('Selected master: ' + (Join-Path $manualRoot 'manual\chosen.sql'))) 'Manual selection outside sql directory accepted within release'
    Assert-True ($interactive.Output -match 'Releases checked: 2' -and $interactive.Output -notmatch 'COULD NOT CHECK|Some content or calls could not be checked') 'Interactive releases have separate completed results in one summary'
    Assert-True ($interactive.Output -match [regex]::Escape('Added release: ' + $interactiveRoot)) 'Accepted folder is visibly acknowledged'
    Assert-Equal @([regex]::Matches($interactive.Output, 'Already added:')).Count 2 'Duplicate entries are acknowledged and not added twice'
    # ConsoleHost does not emit Read-Host prompt text when stdin is redirected.
    Assert-True ($interactive.Output -match 'Press Enter on the empty prompt to continue to master selection') 'Accepted and duplicate inputs explain how to advance'
    Assert-True ($interactive.Output -match 'Releases selected: 2\. Next, confirm or select a master for each release\.') 'Blank input advances to master selection with the correct release count'
    $autoRoot = New-TestRelease 'Auto master hotfix' '-- Decoy master, not the detected master.' @{
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
    Assert-True ($interactive.Output -match 'No master matching the release folder name was found') 'Missing folder-name master falls back to the existing menu'
    $launchCopy = Join-Path $work 'Double click utility'
    [void](New-Item -ItemType Directory -Path $launchCopy)
    Copy-Item -LiteralPath $checker, $launcher -Destination $launchCopy
    $paused = Run-Interactive (Join-Path $launchCopy 'Check-Release.bat') @((Join-Path $fixtures 'Clean'), '', '2', 'x') 'double-click' $true
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
    $menu20Root = New-TestRelease 'Menu twenty' "SET DEFINE ON`nstart payload.pb" $menu20Files
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
    $retryRoot = New-TestRelease 'Retry hotfix' 'placeholder' @{
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
    $retrySummaryFile = @(Get-ChildItem -LiteralPath (Join-Path $work 'retry-accepted-reports') -Filter summary.txt -File -Recurse)
    $retrySummary = Get-Content -Raw -LiteralPath $retrySummaryFile[0].FullName
    Assert-Equal @([regex]::Matches($retrySummary, '(?m)^Encoding fallback:')).Count 1 'Automatic per-file fallback is recorded once and leaves UTF-8 child decoding unchanged'
    Assert-True $retryAccepted.Output.Contains($retrySummary.TrimEnd()) 'Retried console summary matches the single TXT'
    Assert-Equal (Get-FileHash -LiteralPath $retryMaster -Algorithm SHA256).Hash $retryHash 'Interactive retry preserves source bytes'
    $retryDetailed = Run-Interactive $checker @($retryRoot, '', 'Y') 'retry-mixed-details' -Nested -Detailed
    Assert-Equal $retryDetailed.ExitCode 1 'Mixed-encoding detailed audit completes with the same coverage status'
    $retryFilesCsv = @(Get-ChildItem -LiteralPath (Join-Path $work 'retry-mixed-details-reports') -Filter '*_files.csv' -File -Recurse)
    Assert-Equal $retryFilesCsv.Count 1 'Detailed retry writes exactly one release files CSV'
    $retryMixedRow = @(Import-Csv -LiteralPath $retryFilesCsv[0].FullName | Where-Object { $_.RelativeFilePath -ceq ('sql\' + $mixedName) })
    Assert-Equal $retryMixedRow.Count 1 'UTF-8 child target retains its exact accented filename'
    Assert-Equal $retryMixedRow[0].IndirectCallCount 1 'Retrying the ANSI master leaves the UTF-8 child decoder unchanged'
    $retryStrict = Run-Interactive $checker @($retryRoot, '', 'Y') 'strict-encoding' -VerifyKeepOpen -StrictUtf8
    Assert-Equal $retryStrict.ExitCode 2 'Explicit UTF8 keeps invalid legacy bytes incomplete'
    Assert-True ($retryStrict.Output -match 'COULD NOT CHECK' -and $retryStrict.Output -notmatch '(?m)^Encoding fallback:|Retry this file') 'Explicit strict decoding never silently changes encoding or asks for a retry'
    $retryDoubleClick = Run-Interactive (Join-Path $launchCopy 'Check-Release.bat') @($retryRoot, '', 'Y', 'x') 'retry-double-click' $true
    Assert-Equal $retryDoubleClick.ExitCode 1 'Double-click BAT supports an encoding retry without extra arguments'
    Assert-True ($retryDoubleClick.Output -match 'Files called by master: 2' -and $retryDoubleClick.Output -match 'Press any key to continue') 'Double-click retry finishes coverage and retains its pause'
    $badBomRoot = New-TestRelease 'Retry invalid BOM' 'placeholder' @{}
    $badBomMaster = Join-Path $badBomRoot 'sql\Retry invalid BOM.sql'
    Move-Item -LiteralPath (Join-Path $badBomRoot 'sql\master.sql') -Destination $badBomMaster
    [IO.File]::WriteAllBytes($badBomMaster, [byte[]]@(239, 187, 191, 160))
    $badBomInteractive = Run-Interactive $checker @($badBomRoot, '', 'Y') 'retry-bad-bom'
    Assert-Equal $badBomInteractive.ExitCode 2 'Malformed BOM-declared UTF-8 remains incomplete'
    Assert-True ($badBomInteractive.Output -notmatch 'Retry this file as Windows-1252\?') 'A declared Unicode BOM never receives an ANSI retry prompt'

    Write-Host 'Checking malicious data, path aliases, and report write protections.'
    $sharpName = 'stra' + [char]0x00DF + 'e.sql'
    $unicodeRoot = New-TestRelease 'Unicode files' 'START strasse.sql' @{ ('sql\' + $sharpName) = '-- A different filename.' }
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
    $escapeRoot = New-TestRelease 'Terminal escape' $escapeText @{ 'sql\unused.pb' = 'select 1 from dual;' }
    $escapedRun = Run-Cli @('-ReleasePath', $escapeRoot, '-MasterPath', 'sql\master.sql', '-DetailedReport') 'terminal-controls'
    $escapedLog = Get-Content -Raw -LiteralPath $escapedRun.Log
    $escapedTxt = Get-Content -Raw -LiteralPath (Join-Path $escapedRun.Folder '01_Terminal_escape_summary.txt')
    Assert-True ($escapedLog.IndexOf([char]27) -lt 0 -and $escapedTxt.IndexOf([char]0x202E) -lt 0) 'CMD and TXT cannot execute terminal escapes or hide text direction'
    Assert-True ($escapedTxt.Contains('\u001B') -and $escapedTxt.Contains('\u202E')) 'Unsafe controls remain visible as escaped evidence'
    $noExecuteMarker = Join-Path $work 'must-not-execute.txt'
    $noExecuteRoot = New-TestRelease 'Never execute' ('HOST echo bad > "' + $noExecuteMarker + '"') @{}
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

    $shortRoot = Join-Path $fixtures 'RELEAS~1'
    if (Test-Path -LiteralPath $shortRoot -PathType Container) {
        $savedReportAudits = $script:ReportAudits
        try {
            $script:ReportAudits = @((Audit-Fixture 'Release one'))
            $aliasDestination = Join-Path $shortRoot 'must-not-create-alias-reports'
            $aliasRejected = $false
            try { Assert-ReportLocation $aliasDestination } catch { $aliasRejected = $_.Exception.Message -match 'outside ALL scanned releases' }
            Assert-True $aliasRejected 'Physical report guard catches a Windows 8.3 release alias'
            Assert-True (-not (Test-Path -LiteralPath $aliasDestination)) 'Short-name guard writes nothing to the release'
        } finally { $script:ReportAudits = $savedReportAudits }
    }
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

    $largeRoot = New-TestRelease 'Large script' 'placeholder' @{ 'sql\payload.pb' = 'select 1 from dual;' }
    [IO.File]::WriteAllText((Join-Path $largeRoot 'sql\master.sql'), "@payload.pb`n--" + [string]::new('a', 1MB), [Text.UTF8Encoding]::new($false))
    $limitedRun = Run-Cli @('-ReleasePath', $largeRoot, '-MasterPath', 'sql\master.sql', '-MaxScriptSizeMB', '1') 'large-limited'
    Assert-Equal $limitedRun.ExitCode 2 'Oversized input produces an incomplete check instead of unbounded allocation'
    $limitedSummary = Get-Content -Raw -LiteralPath (Join-Path $limitedRun.Folder 'summary.txt')
    Assert-True ($limitedSummary -match 'COULD NOT CHECK' -and $limitedSummary -match 'exceeds the 1 MB read limit') 'Size limit explains why coverage is unavailable'
    $largerLimitRun = Run-Cli @('-ReleasePath', $largeRoot, '-MasterPath', 'sql\master.sql', '-MaxScriptSizeMB', '2') 'large-allowed'
    Assert-Equal $largerLimitRun.ExitCode 0 'Increasing the explicit size limit preserves legitimate larger scripts'
    foreach ($bomPage in @(65001, 1200, 1201, 12000, 12001)) {
        $bomRoot = New-TestRelease ('BOM-' + $bomPage) 'placeholder' @{ 'sql\payload.pb' = 'select 1 from dual;' }
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
