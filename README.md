# Release Script Checker

Checks which files in a release folder are directly called by a selected SQL
master, then checks whether the files called by that master are present in the
hotfix folder. It also synchronizes the installer's `my $hotfix` value with the
release folder name and renames the five supported Perl/undeploy scripts inside
`sql` to match that name. It never executes release scripts.

## Use

Keep `Check-Release.bat` and `Check-Release.ps1` together outside your releases.
Double-click **Check-Release.bat**:

1. Enter a release folder. Press Enter at the next empty prompt to continue.
   You can also enter more release folders before the blank line.
2. The checker detects `sql\<release folder name>.sql` and asks whether it is the
   master for this hotfix. Enter `Y` to use it. Enter `N` to choose another master
   by number or use `M` to enter its path. If no matching file exists, the manual
   selection menu appears automatically. Names are matched ignoring case.
3. Read the result, counts, and list of files with no matching call in the master.
   The next section checks master calls for missing files and shows only a count
   for allowed missing calls.

Encoding is automatic by default: Unicode BOMs take precedence; otherwise the
checker tries strict UTF-8, then Windows-1252 if UTF-8 decoding fails. It does
not ask an encoding question. Each fallback appears in the summary and applies
only to that file, so UTF-8 child scripts retain their decoding. SQL source files
are never rewritten. Use `-ScriptEncoding UTF8` to require strict UTF-8.

The same summary appears in the CMD window and in a named file beside the utility:

```text
reports\DATE_TIME_HOTFIX\summary_HOTFIX.txt
reports\20261015_1215PM_V12-020-2-02N-HF-AMI-16\summary_V12-020-2-02N-HF-AMI-16.txt
```

`DATE` is `yyyyMMdd`; `TIME` is `hhmmAM`/`hhmmPM` using the current time in
America/Toronto, including daylight saving time. `HOTFIX` is the selected release
folder name. Each selected hotfix gets its own folder and summary, including
multi-hotfix runs. If the folder already exists, `_2`, `_3`, and so on are added
to the folder name to preserve earlier reports. The window stays open so you can
read the result.

Every summary starts with `Executed by: <current Windows username>` before the
release path. The username is detected automatically from the account running
the script and is included in normal, detailed, and combined summaries.

While checking, the console shows validation, folder scanning, master reading,
and saving stages. Longer scans also show file or parsed-line counts. These
progress messages do not add anything to the saved summary.

Example summary:

```text
Release Script Checker

Executed by: Aslan.Mirsakiyev
Release: C:\Aslan\TEMP\V12-023-2-02-HF-AMA-21
Selected master: C:\Aslan\TEMP\V12-023-2-02-HF-AMA-21\sql\V12-023-2-02-HF-AMA-21.sql
Result: NO - 2 file(s) have no matching call in the master.
Files checked: 5
Files called by master: 3
Files with no matching call: 2

Files with no matching call in the master:
  sql\extra_patch.sql
  sql\unused_package.pkb

Master call file check (hotfix folder):
File presence result: NO - 1 required call(s) have no matching file in the hotfix folder.
Master calls checked: 5
Calls with files present: 3
Allowed missing calls ignored: 1
Required calls missing files: 1

Required files missing from hotfix folder (master line numbers):
  missing_patch.pb (line 12)

```

## From CMD

```bat
Check-Release.bat -ReleasePath "D:\testing\V12-024-2-02-HF-ALC-03" -MasterPath "sql\V12-024-2-02-HF-ALC-03.sql" -NonInteractive
```

Use `-ReportDirectory "C:\ReleaseAudits"` to change where the summary is saved.
Reports must be outside every selected release. Existing reports are preserved.
Windows PowerShell 5.1 is required; no additional tools or modules are needed.

## What counts as called

- Only active `START` (`STA`/`STAR`), `@`, and `@@` calls in the selected master
  count. Comments, quoted SQL literals, and output commands do not count.
- Names match case-insensitively as whole filenames/paths, including quoted paths
  with spaces. A bare `START`/`@` filename in the master covers every exact-name
  copy across release folders: `START aperror.dat` covers both `sql\aperror.dat`
  and `uig\sql\aperror.dat`. The summary notes this filename-presence match;
  it does not establish which copy SQL*Plus executes. Extensionless calls assume
  `.sql`.
- All release files are checked recursively except the selected master and files
  ending in `.ear`, `.java`, `.war`, `.bc`, `.zip`, `.docx`, `.wft`, `.perl`, `.pl`,
  `.txt`, `.cmd`, `.sh`, `.bat`, `.undeploy`, `.properties`, `.jar`, or `.deploy`. These exclusions ignore case.
- Calls with explicit paths use exact path matching. `START`/`@` paths use the
  master folder by default; `@@` uses the calling script's folder.
  `-WorkingDirectory` overrides the `START`/`@` base. An explicit wrong path never
  falls back to a matching filename. Nested reads follow the resolved primary
  path; extra filename copies are not read by guessing their runtime location.
- Multiline SQL and `EXECUTE IMMEDIATE` literals stay within the SQL parser's
  quote state. START-looking text inside them never counts, and active calls
  after the closing quote remain visible. SQL*Plus prompts and control text
  cannot leave an open SQL literal that hides later calls.
- Variables, ambiguous filenames, unsupported calls, read errors, and skipped
  links require review. A short note appears when the check is incomplete.
  An uncalled supporting file does not necessarily indicate a deployment error.

## Master calls missing from the hotfix

The second check uses the same active-call parser and path matching rules as the
coverage check. It checks direct calls in the selected master against the entire
recursive hotfix inventory, including targets whose extensions are excluded from
the first check. Each call line counts once, even if its filename matches several
copies. Missing required calls include the target and master line number.
Explicit paths must match their path within the hotfix; targets outside the
hotfix also count as absent from it. External locations are never searched.

The separate `$script:AllowedMissingCallTargets` list near the top of
`Check-Release.ps1` contains all 93 supplied exception entries. Edit that list to
maintain the exceptions. It matches whole filenames ignoring case, including
path-qualified calls. Extensionless calls such as `ptfcompx` assume `.sql`.
The same exceptions apply to `START`, `@`, and `@@` master calls. A listed
target absent from the hotfix contributes to **Allowed missing calls ignored**
and does not fail either report mode. The ignored filenames are not printed in
the summary. A listed file supplied in the hotfix is checked normally, including
whether it has a master call.

Comments, output text, and SQL string literals do not count as calls. Dynamic or
malformed targets, unsupported invocations, and unknown suffixes still require
review; the exception list does not turn an uncertain call into a pass. A read
error or incomplete inventory makes the presence result provisional.
The file-check counts include only `START`, `@`, and `@@` calls. Generic
unsupported-command diagnostics, such as those for `EXEC`, `CALL`, or `HOST`,
remain in the detailed audit. The normal summary omits the manual-review list;
unresolved script calls receive a short note directing you to `-DetailedReport`,
where source lines and reasons are available. Detailed reference CSVs also
retain the `IgnoredMissing` status for allowed absences.
`-IncludeNested` retains its existing nested diagnostics; the new section and
its exceptions apply only to calls in the selected master.

## Optional details and automation

`-DetailedReport` enables the previous full text reports, files/reference CSVs,
and combined totals. Detailed summaries also use `summary_HOTFIX.txt` inside
each hotfix's named folder. Multi-hotfix detailed runs save combined totals in
a separate `DATE_TIME_Combined` folder. These details are optional; normal runs
save only one summary TXT per hotfix. `-IncludeNested` inspects reachable scripts, but files called only
indirectly still have no direct call in the master.

For multiple releases from CMD, use `-InputCsv inputs.csv` with columns
`ReleasePath,MasterPath,WorkingDirectory` (the last column is optional).
PowerShell callers can pass paired arrays to `-ReleasePath` and `-MasterPath`.
Use `-ScriptEncoding Default` for legacy Windows ANSI scripts using the laptop's
active code page. Use `-ScriptEncoding Windows1252` when the source is known to
use Western Windows-1252, regardless of the laptop's locale. The default
`-ScriptEncoding Auto` uses the per-file UTF-8/Windows-1252 fallback above in
both interactive and automated runs. Explicit encoding options apply to every
no-BOM script; they disable fallback. Unicode BOMs always take precedence, and
malformed BOM-declared Unicode remains an error.
`-NoPause` disables the final wait when
running the PowerShell script interactively. `-Help` lists parameters.

If a mapped drive is slow, use `Check-Release.bat -Verbose` to show each folder
being scanned and each script being read. The last message identifies the
operation waiting on Windows or the server. Ordinary files are checked without
querying PowerShell's extra link metadata; junctions and symbolic links still
retain their safety checks. A disconnected or unresponsive share can still wait
for Windows network timeouts.

## Security and limits

The checker treats release scripts as data. It never evaluates variables or runs
their commands. Report locations are checked against Windows filesystem paths,
including short-name aliases, and checked again before each write. Reports use
fresh folders and refuse to overwrite existing files or hardlinks.

Terminal controls and invisible direction markers are shown as `\uXXXX` escapes.
Formula-like values in detailed CSVs receive a visible `text:` prefix; downstream
CSV consumers must account for that prefix. Release SQL file contents remain
unchanged. The only release changes are the installer assignment update and
the five supported script filename changes described below.

## Hotfix script filenames

Before scanning the hotfix, the checker looks directly inside its `sql` folder
for files beginning with `V12-` (ignoring case) and ending with one of these suffixes:

- `.aftercopy.perl`
- `.beforecopy.perl`
- `.beforedeploy.perl`
- `.last.perl`
- `.undeploy`

Each matching file is renamed to `HOTFIX` plus its suffix. For example,
`v12-023-2-02-hf-ama-01.aftercopy.perl` becomes
`V12-023-2-02-HF-AMA-21.aftercopy.perl` when the release folder is
`V12-023-2-02-HF-AMA-21`. The hotfix name uses the release folder's casing, and
the suffixes use the lowercase spelling above. Case-only differences are fixed.

File contents and modification times are preserved. Already matching names and
absent suffixes are skipped. Other suffixes, `.pl` files, backups, unrelated
prefixes, and files in subfolders are left alone. Renames appear in the summary
only when a name actually changes. The audit inventories the final filenames;
it does not rewrite calls inside SQL or Perl files.

If more than one file matches a suffix, or its destination already exists, those
files are preserved and the run reports an incomplete result with the reason.
Other unambiguous suffixes can still be renamed. Symbolic links and junctions
are not followed for renames.

## Installer hotfix name

When a readable master is checked, the checker looks for
`HOTFIX\v12hotfixinstall\v12hotfixinstall.pl`. If present, it updates only the
value of the active literal assignment to match the release folder name:

```perl
my $hotfix = "V12-020-2-02N-HF-AMI-16";
```

An already matching value leaves the file's bytes and modification time unchanged.
A missing installer is skipped. Comments, other variables, whitespace, line
endings, the encoding, and any byte-order mark are preserved. The checker does
not execute the Perl file. An actual edit is noted in the summary.

If the installer cannot be updated, or the checker cannot find exactly one
literal `my $hotfix` assignment, the run reports the reason and exits with `2`.
It does not guess which assignment to change or write through symbolic links,
junctions, or hardlinks. Installer decoding recognizes
Unicode BOMs, otherwise UTF-8 with a Windows-1252 fallback, independently of
the SQL `-ScriptEncoding` setting.

Each parsed script is limited to 64 MB by default. Use `-MaxScriptSizeMB 128` for
larger legitimate scripts. Exceeding the limit produces an incomplete result.
Detailed reports include source lines and arguments: keep them in a folder you
control. See [SECURITY-AUDIT.md](SECURITY-AUDIT.md) for the review and remaining
limitations, including concurrent filesystem changes and large directory trees.

Default exit codes: `0` all checked files have matching master calls and all
required master calls have files in the hotfix; `1` either check has findings;
`2` the check is incomplete or failed. Allowed missing calls do not produce
findings. The highest code wins for multiple releases. In detailed mode,
nested missing targets, repetitions, and cycles can also produce `1`.

## Verification

```bat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-Checker.ps1
```

Tests cover parsing, direct versus indirect calls, exclusions, safe reports,
matching CMD/TXT summaries, separate reports for multiple releases, error handling, and
keeping the interactive window open. They also cover missing master targets,
all 93 exception entries, exact filename matching, and independent results for
the two checks, report naming/collisions, installer edits with encoding,
line-ending, and no-op preservation, and hook renames with case normalization,
content preservation, and conflict handling. See `tests\README.md`. Generated test
reports stay under `tests\.work`, outside the fixture releases.
