#requires -Version 5.1
<#
.SYNOPSIS
Release Script Checker: read-only static SQL*Plus reference auditing.
.DESCRIPTION
No arguments starts the release/master selection workflow. Supplied releases and
masters are paired by array position; relative master/working paths use the release
root. Reports and this utility must be outside every supplied release.
Exit codes: 0 completed/no findings; 1 completed/findings; 2 incomplete or failed.
#>
[CmdletBinding()]
param(
    [string[]]$ReleasePath,
    [string[]]$MasterPath,
    [string[]]$WorkingDirectory,
    [switch]$IncludeNested,
    [switch]$DetailedReport,
    [string]$ReportDirectory = '',
    [string]$InputCsv,
    [ValidateSet('UTF8', 'Default', 'Unicode', 'BigEndianUnicode')]
    [string]$ScriptEncoding = 'UTF8',
    [ValidateRange(1, 1024)][int]$MaxScriptSizeMB = 64,
    [switch]$NonInteractive,
    [switch]$NoPause,
    [switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:ExcludedExtensions = @('.ear', '.java', '.war', '.bc', '.zip',
    '.docx', '.wft', '.perl', '.pl', '.txt', '.cmd', '.sh', '.bat', '.undeploy')
$script:ReportAudits = @()

function New-PathMap { return [Collections.Hashtable]::new([StringComparer]::OrdinalIgnoreCase) }
function Test-SamePath([string]$Left, [string]$Right) { return [string]::Equals($Left, $Right, [StringComparison]::OrdinalIgnoreCase) }

function ConvertTo-SafeText([string]$Text, [switch]$Multiline) {
    $pattern = if ($Multiline) { '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F\p{Cf}\u2028\u2029]' } else { '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]' }
    return [regex]::Replace($Text, $pattern, { param($m) '\u{0:X4}' -f [int]$m.Value[0] })
}
function Write-Console([string]$Message) { Write-Host (ConvertTo-SafeText $Message -Multiline) }

function Get-PhysicalPath([string]$Path) {
    if (-not ('ReleaseChecker.NativePaths' -as [type])) {
        Add-Type -TypeDefinition @'
using System; using System.Text; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
namespace ReleaseChecker {
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
    return [ReleaseChecker.NativePaths]::Resolve($cursor).TrimEnd('\') + $suffix
}

function Test-LocationInRoot([string]$Path, [string]$Root) {
    return ((Test-InRoot $Path $Root) -or ((Test-Path -LiteralPath $Root -PathType Container) -and
        (Test-InRoot (Get-PhysicalPath $Path) (Get-PhysicalPath $Root))))
}

function Assert-ReportLocation([string]$Path) {
    foreach ($audit in $script:ReportAudits) {
        if ($audit.NormalizedRoot -and (Test-LocationInRoot $Path $audit.Root)) { throw "ReportDirectory must be outside ALL scanned releases: $($audit.Root)" }
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
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Audit.Root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        # Keep partial results if a directory emits a read error.
        $readErrors = @()
        $items = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue -ErrorVariable readErrors)
        foreach ($e in $readErrors) { Add-Issue $Audit "Directory read error: $e" $directory }
        foreach ($item in $items) {
            $isLink = Test-PathLink $item
            if ($item.PSIsContainer) {
                if ($isLink) { Add-Issue $Audit 'Directory link skipped; inventory is incomplete.' $item.FullName }
                else { $pending.Push($item.FullName) }
            } else {
                $file = [pscustomobject]@{
                    FullPath = $item.FullName; RelativePath = (Get-RelativePath $item.FullName $Audit.Root)
                    Name = $item.Name; Extension = $item.Extension.ToLowerInvariant()
                    Excluded = ($script:ExcludedExtensions -contains $item.Extension)
                    IsLink = $isLink
                }
                [void]$Audit.Files.Add($file)
                $Audit.ByPath[$file.FullPath] = $file
                if (-not $Audit.ByName.ContainsKey($file.Name)) {
                    $Audit.ByName[$file.Name] = New-Object System.Collections.ArrayList
                }
                [void]$Audit.ByName[$file.Name].Add($file)
                if ($isLink) { Add-Issue $Audit 'File link inventoried but not followed or matched.' $item.FullName }
            }
        }
    }
}

function Get-CodeLine([string]$Line, $State) {
    # A small lexer: comments only outside quotes, doubled quote escapes, and
    # Oracle q'[...]' (including multiline literals). Keep path quotes intact.
    $out = New-Object Text.StringBuilder
    $startedInLiteral = ($State.Quote -ne '' -or $State.AlternateEnd -ne '')
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
        if ($c -eq '/' -and $next -eq '*') { $State.Block = $true; [void]$out.Append('  '); $i++; continue }
        if (-not $hasToken -and -not [char]::IsWhiteSpace($c)) {
            $rest = $Line.Substring($i)
            # These SQL*Plus commands contain free text, not SQL string literals.
            if ($rest -match '^(?i:REM(?:A(?:R(?:K)?)?)?|PRO(?:M(?:P(?:T)?)?)?|SPO(?:O(?:L)?)?|DEF(?:I(?:N(?:E)?)?)?|UNDEF\w*|ACC(?:E(?:P(?:T)?)?)?|COL(?:U(?:M(?:N)?)?)?|TTI\w*|BTI\w*)(?:\s|$)') {
                return [pscustomobject]@{ Text = ''; StartedInLiteral = $startedInLiteral }
            }
            $hasToken = $true
        }
        if (($c -eq 'q' -or $c -eq 'Q') -and $next -eq "'" -and $i + 2 -lt $Line.Length) {
            $delimiter = [string]$Line[$i + 2]
            $pairs = @{ '[' = ']'; '(' = ')'; '{' = '}'; '<' = '>' }
            $State.AlternateEnd = if ($pairs.ContainsKey($delimiter)) { $pairs[$delimiter] } else { $delimiter }
            [void]$out.Append($Line.Substring($i, 3)); $i += 2; continue
        }
        if ($c -eq "'" -or $c -eq '"') { $State.Quote = [string]$c }
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

function Read-Script([string]$Path) {
    $calls = New-Object System.Collections.ArrayList
    $issues = New-Object System.Collections.ArrayList
    $suffixUnknown = $false; $syntaxUnknown = $false; $readSucceeded = $false
    $state = @{ Block = $false; Quote = ''; AlternateEnd = '' }
    try {
        # Decode the complete byte array: .NET Framework StreamReader can drop
        # an incomplete UTF-8 sequence at EOF without flushing its decoder.
        $bytes = Read-ScriptBytes $Path
        $codePage = @{ UTF8 = 65001; Default = [Text.Encoding]::Default.CodePage; Unicode = 1200; BigEndianUnicode = 1201 }[$ScriptEncoding]
        $offset = 0
        foreach ($bom in @(@('FF-FE-00-00', 12000, 4), @('00-00-FE-FF', 12001, 4),
            @('EF-BB-BF', 65001, 3), @('FF-FE', 1200, 2), @('FE-FF', 1201, 2))) {
            if ($bytes.Length -ge $bom[2] -and [BitConverter]::ToString($bytes, 0, $bom[2]) -eq $bom[0]) {
                $codePage = $bom[1]; $offset = $bom[2]; break
            }
        }
        $encoding = [Text.Encoding]::GetEncoding($codePage, [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback)
        $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
        if ($text.IndexOf([char]0) -ge 0) { throw 'Binary/NUL content is not a supported SQL*Plus text script.' }
        $lines = [regex]::Split($text, '\r\n|\n|\r')
        $readSucceeded = $true
        for ($n = 0; $n -lt $lines.Length; $n++) {
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
            throw 'Unterminated block comment or SQL literal; analysis may be incomplete.'
        }
    } catch {
        [void]$issues.Add([pscustomobject]@{ SourceFile = $Path; LineNumber = 0;
            Message = "Script read/parse error: $($_.Exception.Message)"; SourceText = '' })
    }
    return [pscustomobject]@{ Calls = @($calls); Issues = @($issues);
        SuffixUnknown = $suffixUnknown; SyntaxUnknown = $syntaxUnknown; ReadSucceeded = $readSucceeded }
}

function Resolve-Call($Call, $Audit, [string]$Chain, [bool]$Direct) {
    $r = [pscustomobject]@{
        ReleaseRoot = $Audit.Root; SelectedMaster = $Audit.Master; SourceFile = $Call.SourceFile
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
        $r.Status = 'OutsideRelease'; $r.Notes = 'External URL; not fetched or checked.'; return $r
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
                $r.Status = 'OutsideRelease'; $r.ResolvedPath = $path
                $r.Notes += 'Outside scanned release; existence elsewhere is not checked.'; return $r
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
                $r.Status = 'MissingInRelease'; $r.ResolvedPath = $path
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
    if (-not $Audit.Cache.ContainsKey($Path)) { $Audit.Cache[$Path] = Read-Script $Path }
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
        $reference = Resolve-Call $call $Audit $edgeChain (Test-SamePath $Path $Audit.Master)
        [void]$Audit.References.Add($reference)
        if ($Audit.Nested -and $reference.Status -eq 'Resolved') {
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

function New-Audit([string]$Root, [string]$Master, [string]$Working, [bool]$Nested) {
    return [pscustomobject]@{
        Root = $Root; Master = $Master; WorkingDirectory = $Working; Nested = $Nested
        Encoding = $ScriptEncoding
        Files = (New-Object System.Collections.ArrayList); ByPath = (New-PathMap); ByName = (New-PathMap)
        References = (New-Object System.Collections.ArrayList); Issues = (New-Object System.Collections.ArrayList)
        Rows = @(); Cache = (New-PathMap); Visited = (New-PathMap); ModelIssues = (New-Object System.Collections.ArrayList)
        SuffixUnknown = $false; SyntaxUnknown = $false; ModelChanged = $false
        ExitCode = 2; Counts = @{}; Summary = ''; ReportPaths = @(); Repeated = @(); MasterReadable = $false
        InputError = ''; NormalizedRoot = $true
    }
}

function Invoke-Audit($Audit) {
    try {
        if ($Audit.InputError) { throw $Audit.InputError }
        Assert-NoPathLinks $Audit.Root
        if (-not (Test-Path -LiteralPath $Audit.Root -PathType Container)) { throw 'Release directory does not exist or is inaccessible.' }
        if (-not (Test-InRoot $Audit.Master $Audit.Root)) { throw 'Selected master must be within this release.' }
        if ([IO.Path]::GetExtension($Audit.Master) -ine '.sql') { throw 'Selected master must be a .sql file.' }
        Assert-NoPathLinks $Audit.Master
        if (-not (Test-Path -LiteralPath $Audit.Master -PathType Leaf)) { throw 'Selected master does not exist or is inaccessible.' }
        if (-not (Test-Path -LiteralPath $Audit.WorkingDirectory -PathType Container)) { throw 'Assumed working directory does not exist or is inaccessible.' }
        Assert-NoPathLinks $Audit.WorkingDirectory
        Get-Inventory $Audit
        if (-not $Audit.ByPath.ContainsKey($Audit.Master)) { throw 'Selected master was not accessible in the inventory.' }
        $inventoryIssues = @($Audit.Issues)
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
    } catch { Add-Issue $Audit $_.Exception.Message $Audit.Root }
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
            ReleaseRoot = $Audit.Root; SelectedMaster = $Audit.Master; RelativeFilePath = $file.RelativePath
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
    $Audit.Counts = Get-AuditCounts $Audit
    $incomplete = ($Audit.Issues.Count -gt 0 -or @($Audit.References | Where-Object { $_.Status -in @('Unresolved', 'Unsupported') }).Count -gt 0)
    $findings = (@($Audit.Rows | Where-Object { $_.DirectReferenceStatus -ne 'DirectlyReferenced' }).Count -gt 0 -or
        @($Audit.References | Where-Object { $_.Status -ne 'Resolved' -or $_.Cycle }).Count -gt 0 -or $Audit.Repeated.Count -gt 0)
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
        @('Unsupported invocations', 'Unsupported'), @('Call targets not found within scanned release', 'MissingInRelease'), @('References outside scanned release', 'OutsideRelease'))) {
        $counts[$entry[0]] = @($Audit.References | Where-Object { $_.Status -eq $entry[1] }).Count
    }
    $counts['Repeated targets'] = $Audit.Repeated.Count
    $counts['Cycles'] = @($Audit.References | Where-Object { $_.Cycle }).Count
    $counts['Read errors / other incomplete-analysis reasons'] = $Audit.Issues.Count
    return $counts
}

function Get-CoverageSummary($Audit) {
    $s = New-Object 'System.Collections.Generic.List[string]'
    $s.Add('Release: ' + (ConvertTo-SafeText $Audit.Root))
    $s.Add('Selected master: ' + (ConvertTo-SafeText $Audit.Master))
    if (-not $Audit.MasterReadable) {
        $s.Add('Result: COULD NOT CHECK - the release or master could not be read.')
        if ($Audit.Issues.Count) { $s.Add('Reason: ' + (ConvertTo-SafeText $Audit.Issues[0].Message)) }
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
        $s.Add('Note: Some content or calls could not be checked. Files below have no confirmed call; review unresolved calls if needed.')
        if ($Audit.Issues.Count) { $s.Add('Reason: ' + (ConvertTo-SafeText $Audit.Issues[0].Message)) }
    } elseif (@($Audit.References | Where-Object { $_.Status -eq 'Ambiguous' }).Count) {
        $s.Add('Note: An ambiguous filename could not be matched to a specific file.')
    }
    $s.Add('')
    $s.Add('Files with no matching call in the master:')
    if (-not $notDirect.Count) { $s.Add('  (none)') }
    foreach ($row in $notDirect) { $s.Add('  ' + $row.RelativeFilePath) }
    return ($s -join [Environment]::NewLine)
}

function Get-Summary($Audit) {
    $s = New-Object 'System.Collections.Generic.List[string]'
    $notDirect = @($Audit.Rows | Where-Object { $_.DirectReferenceStatus -ne 'DirectlyReferenced' })
    $s.Add('Release Script Checker - static references only; no release scripts were executed.')
    $s.Add('Release: ' + (ConvertTo-SafeText $Audit.Root)); $s.Add('Selected master: ' + (ConvertTo-SafeText $Audit.Master))
    $s.Add('Result: ' + $(if ($Audit.ExitCode -eq 2) { 'INCOMPLETE / FAILED - coverage is provisional.' } elseif ($Audit.ExitCode -eq 1) { 'Completed with findings.' } else { 'Completed with no findings.' }))
    $s.Add('Mode: ' + $(if ($Audit.Nested) { 'Direct and reachable nested calls' } else { 'Direct master calls only' }))
    $s.Add('Assumed working directory (START/@): ' + (ConvertTo-SafeText $Audit.WorkingDirectory))
    $s.Add('Script encoding without BOM: ' + $Audit.Encoding + ' (Unicode BOM overrides).')
    $s.Add('@@ resolves relative to its caller. Default suffix: .sql unless flagged as unknown.')
    $s.Add('UniqueFilename is an inventory match, not proof of runtime lookup. SQLPATH is not searched.')
    foreach ($entry in $Audit.Counts.GetEnumerator()) {
        if ($Audit.Nested -or $entry.Key -ne 'Files referenced only indirectly') { $s.Add($entry.Key + ': ' + $entry.Value) }
    }
    $s.Add(''); $s.Add('Not directly called by the selected master (supporting files may not require execution):')
    if (-not $notDirect.Count) { $s.Add('  (none found in the accessible inventory)') }
    foreach ($group in @($notDirect | Group-Object Extension | Sort-Object Name)) {
        $s.Add('  ' + $group.Name)
        foreach ($row in $group.Group) {
            $s.Add('    ' + $row.RelativeFilePath + ' [' + $row.DirectReferenceStatus + '; ' + $row.IndirectReferenceStatus + ']')
        }
    }
    foreach ($section in @(
        @{ Title = 'Ambiguous references'; Status = @('Ambiguous') },
        @{ Title = 'Unresolved / manual review'; Status = @('Unresolved', 'Unsupported') },
        @{ Title = 'Call targets not found within scanned release'; Status = @('MissingInRelease') },
        @{ Title = 'References outside scanned release (not checked externally)'; Status = @('OutsideRelease') }
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
        Write-Console ("`nNo master matching the release folder name was found. Select the master manually.")
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
    Write-Console '  M. Enter a master .sql path manually (relative to release or absolute)'
    while ($true) {
        $choice = Read-Host 'Master number, M, or a file path'
        $index = 0
        if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $sqlFiles.Count) { return $sqlFiles[$index - 1].FullPath }
        if ($choice -ieq 'M') { $choice = Read-Host 'Master .sql path' }
        try {
            $master = Get-NormalPath $choice $Root
            if (-not (Test-InRoot $master $Root) -or [IO.Path]::GetExtension($master) -ine '.sql') { throw 'Choose a .sql file inside this release.' }
            Assert-NoPathLinks $master
            if (-not (Test-Path -LiteralPath $master -PathType Leaf)) { throw 'File does not exist or is inaccessible.' }
            return $master
        } catch { Write-Console ('Invalid master: ' + $_.Exception.Message) }
    }
}

function Invoke-Checker {
    if ($Help) {
        Write-Console 'Release Script Checker - Windows PowerShell 5.1'
        Write-Console 'No arguments: release paths, automatic master detection and Y/N confirmation.'
        Write-Console 'Parameters: -ReleasePath <paths> -MasterPath <paths> [-WorkingDirectory <paths>]'
        Write-Console '            [-IncludeNested] [-ReportDirectory <path>] [-NonInteractive]'
        Write-Console '            [-DetailedReport] (optional CSVs and full call details)'
        Write-Console '            [-NoPause] (disable the final wait in an interactive script run)'
        Write-Console '            [-ScriptEncoding UTF8|Default|Unicode|BigEndianUnicode] [-MaxScriptSizeMB 64]'
        Write-Console 'Alternative batch input: -InputCsv <csv> with ReleasePath,MasterPath,WorkingDirectory columns.'
        Write-Console 'See README.md for examples and exit codes (0 / 1 / 2).'
        return 0
    }
    $jobs = New-Object System.Collections.ArrayList
    if ($InputCsv) {
        if ($ReleasePath -or $MasterPath -or $WorkingDirectory) { throw 'InputCsv cannot be combined with ReleasePath, MasterPath, or WorkingDirectory.' }
        $records = @(Import-Csv -LiteralPath $InputCsv)
        if (-not $records.Count) { throw 'Input CSV has no release rows.' }
        foreach ($record in $records) {
            if (-not $record.PSObject.Properties['ReleasePath'] -or -not $record.PSObject.Properties['MasterPath']) { throw 'CSV requires ReleasePath and MasterPath columns.' }
            $wd = if ($record.PSObject.Properties['WorkingDirectory']) { $record.WorkingDirectory } else { '' }
            [void]$jobs.Add(@{ Release = $record.ReleasePath; Master = $record.MasterPath; Working = $wd })
        }
    } elseif ($ReleasePath -or $MasterPath -or $NonInteractive) {
        if (-not $ReleasePath -or -not $MasterPath -or $ReleasePath.Count -ne $MasterPath.Count) { throw 'Supply one MasterPath for each ReleasePath; no prompts are used when paths are supplied.' }
        if ($WorkingDirectory -and $WorkingDirectory.Count -ne 1 -and $WorkingDirectory.Count -ne $ReleasePath.Count) { throw 'WorkingDirectory must have one value, or one per release.' }
        for ($i = 0; $i -lt $ReleasePath.Count; $i++) {
            $wd = if (-not $WorkingDirectory) { '' } elseif ($WorkingDirectory.Count -eq 1) { $WorkingDirectory[0] } else { $WorkingDirectory[$i] }
            [void]$jobs.Add(@{ Release = $ReleasePath[$i]; Master = $MasterPath[$i]; Working = $wd })
        }
    } else {
        Write-Console 'Release Script Checker - check files called by the master'
        Write-Console 'Enter release folders one per line; submit a blank line when finished.'
        while ($true) {
            $prompt = if ($jobs.Count) { 'Another release folder (press Enter to choose masters)' } else { 'Release folder' }
            $entered = Read-Host $prompt
            if ([string]::IsNullOrWhiteSpace($entered)) { break }
            try {
                $root = Get-NormalPath $entered
                Assert-NoPathLinks $root
                if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Directory does not exist or is inaccessible.' }
                if (Test-InRoot $PSScriptRoot $root) { throw 'The utility must be outside the release folder.' }
                if (@($jobs | Where-Object { Test-SamePath $_.Release $root }).Count) {
                    Write-Console ('Already added: ' + $root)
                    Write-Console 'Press Enter on the empty prompt to continue to master selection, or enter a different release folder.'
                    continue
                }
                [void]$jobs.Add(@{ Release = $root; Master = ''; Working = '' })
                Write-Console ('Added release: ' + $root)
                Write-Console 'Press Enter on the empty prompt to continue to master selection, or enter another release folder.'
            } catch { Write-Console ('Invalid release: ' + $_.Exception.Message) }
        }
        if (-not $jobs.Count) { Write-Console 'No releases selected.'; return 2 }
        Write-Console ('Releases selected: ' + $jobs.Count + '. Next, confirm or select a master for each release.')
        if ($WorkingDirectory -and $WorkingDirectory.Count -ne 1 -and $WorkingDirectory.Count -ne $jobs.Count) { throw 'WorkingDirectory must have one value, or one per release.' }
        for ($i = 0; $i -lt $jobs.Count; $i++) {
            $jobs[$i].Master = Select-Master $jobs[$i].Release
            if ($WorkingDirectory) { $jobs[$i].Working = if ($WorkingDirectory.Count -eq 1) { $WorkingDirectory[0] } else { $WorkingDirectory[$i] } }
        }
    }
    $audits = New-Object System.Collections.ArrayList
    foreach ($job in $jobs) {
        $root = [string]$job.Release; $master = [string]$job.Master; $wd = [string]$job.Working
        $inputError = ''; $normalizedRoot = $false
        try {
            $root = Get-NormalPath $job.Release; $normalizedRoot = $true
            $master = Get-NormalPath $job.Master $root
            $wd = if ($job.Working) { Get-NormalPath $job.Working $root } else { [IO.Path]::GetDirectoryName($master) }
        } catch { $inputError = 'Invalid release/master/working path: ' + $_.Exception.Message }
        if ($normalizedRoot -and (Test-LocationInRoot $PSScriptRoot $root)) { throw "Move the utility outside the scanned release: $root" }
        $audit = New-Audit $root $master $wd ([bool]$IncludeNested)
        $audit.InputError = $inputError; $audit.NormalizedRoot = $normalizedRoot
        [void]$audits.Add($audit)
    }
    if (-not $ReportDirectory) { $ReportDirectory = Join-Path $PSScriptRoot 'reports' }
    $reportRoot = Get-NormalPath $ReportDirectory
    $script:ReportAudits = @($audits)
    Assert-ReportLocation $reportRoot
    $runFolder = Join-Path $reportRoot ((Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $runFolder)
    Assert-ReportLocation $runFolder
    $script:LastRunFolder = $runFolder
    $fileColumns = @('ReleaseRoot', 'SelectedMaster', 'RelativeFilePath', 'Extension', 'DirectReferenceStatus', 'IndirectReferenceStatus', 'MatchingMethod', 'ReferenceSourceFile', 'SourceLineNumbers', 'NumberOfDetectedCalls', 'DirectCallCount', 'IndirectCallCount', 'CallChains', 'Notes', 'AuditStatus')
    $refColumns = @('ReleaseRoot', 'SelectedMaster', 'SourceFile', 'LineNumber', 'SourceText', 'Command', 'Target', 'Arguments', 'Direct', 'Status', 'MatchingMethod', 'ResolvedPath', 'Candidates', 'CallChain', 'Notes', 'Cycle')
    $overall = 0; $index = 0
    $coverageSummaries = New-Object 'System.Collections.Generic.List[string]'
    foreach ($audit in $audits) {
        $index++
        Write-Console ("`nChecking release: " + (ConvertTo-SafeText $audit.Root))
        if ($DetailedReport) { Write-Console ('Selected master: ' + (ConvertTo-SafeText $audit.Master)) }
        Invoke-Audit $audit
        if (-not $DetailedReport) {
            # Simple mode answers file coverage only. Extra/missing call targets,
            # repeated calls and cycles do not make complete coverage fail.
            if ($audit.ExitCode -ne 2) {
                $audit.ExitCode = if ($audit.Counts['Files not directly referenced']) { 1 } else { 0 }
            }
            $coverageSummaries.Add((Get-CoverageSummary $audit))
            if ($audit.ExitCode -gt $overall) { $overall = $audit.ExitCode }
            continue
        }
        $audit.Summary = Get-Summary $audit
        $name = ($audit.Root.TrimEnd('\') -split '\\')[-1] -replace '[^a-zA-Z0-9._-]', '_'
        if (-not $name) { $name = 'InvalidRelease' }
        $stem = '{0:D2}_{1}' -f $index, $name
        $txt = Join-Path $runFolder ($stem + '_summary.txt')
        $csv = Join-Path $runFolder ($stem + '_files.csv')
        $refsCsv = Join-Path $runFolder ($stem + '_references.csv')
        Write-ReportText $txt @($audit.Summary)
        Write-ReportCsv @($audit.Rows) $fileColumns $csv
        Write-ReportCsv @($audit.References) $refColumns $refsCsv
        $audit.ReportPaths = @($txt, $csv, $refsCsv)
        Write-Console "`n$($audit.Summary)"
        Write-Console "`nReports:"
        foreach ($report in $audit.ReportPaths) { Write-Console ('  ' + $report) }
        if ($audit.ExitCode -gt $overall) { $overall = $audit.ExitCode }
    }
    if (-not $DetailedReport) {
        $summaryPath = Join-Path $runFolder 'summary.txt'
        $summary = 'Release Script Checker' + [Environment]::NewLine
        if ($audits.Count -gt 1) { $summary += 'Releases checked: ' + $audits.Count + [Environment]::NewLine }
        $summary += [Environment]::NewLine + ($coverageSummaries -join ([Environment]::NewLine + [Environment]::NewLine))
        $summary += [Environment]::NewLine + [Environment]::NewLine + 'Summary saved to: ' + $summaryPath
        Write-ReportText $summaryPath @($summary)
        Write-Console ("`n" + $summary)
        return $overall
    }
    $totals = @('Release Script Checker - combined totals', ('Releases reviewed: ' + $audits.Count))
    foreach ($label in $audits[0].Counts.Keys) {
        $value = ($audits | ForEach-Object { $_.Counts[$label] } | Measure-Object -Sum).Sum
        if ($label -eq 'Files referenced only indirectly' -and -not $IncludeNested) { $value = 'Not checked (direct-only mode)' }
        if ($label -eq 'Unresolved references') {
            $value += ($audits | ForEach-Object { $_.Counts['Unsupported invocations'] } | Measure-Object -Sum).Sum
            $displayLabel = 'Unresolved / unsupported references'
        } elseif ($label -eq 'Unsupported invocations') { continue }
        else { $displayLabel = $label.Replace('scanned release', 'scanned releases') }
        $totals += $displayLabel + ': ' + $value
    }
    $totals += 'Incomplete / failed releases: ' + @($audits | Where-Object { $_.ExitCode -eq 2 }).Count
    $totals += 'Overall exit code: ' + $overall
    $totals = $totals -join [Environment]::NewLine
    $combined = Join-Path $runFolder 'combined_summary.txt'
    Write-ReportText $combined @($totals)
    Write-Console "`n$totals`nCombined summary: $combined"
    return $overall
}

# Dot sourcing exposes the functions to the built-in regression harness only.
if ($MyInvocation.InvocationName -ne '.') {
    $interactiveRun = (-not $ReleasePath -and -not $MasterPath -and -not $InputCsv -and -not $NonInteractive -and -not $Help)
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
