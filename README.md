# Release Script Checker

Checks which files in a release folder are directly called by a selected SQL
master. It only reads files; it never executes scripts or modifies the release.

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

Encoding is automatic by default: Unicode BOMs take precedence; otherwise the
checker tries strict UTF-8, then Windows-1252 if UTF-8 decoding fails. It does
not ask an encoding question. Each fallback appears in the summary and applies
only to that file, so UTF-8 child scripts retain their decoding. Source files
are never rewritten. Use `-ScriptEncoding UTF8` to require strict UTF-8.

The same summary appears in the CMD window and in **one `summary.txt` file** under
`reports\<timestamp>` beside the utility. Multiple selected releases are included
in that one file. The window stays open so you can read the result.

While checking, the console shows validation, folder scanning, master reading,
and saving stages. Longer scans also show file or parsed-line counts. These
progress messages do not add anything to the saved summary.

Example summary:

```text
Result: NO - 2 file(s) have no matching call in the master.
Files checked: 5
Files called by master: 3
Files with no matching call: 2

Files with no matching call in the master:
  sql\extra_patch.sql
  sql\unused_package.pkb
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

## Optional details and automation

`-DetailedReport` enables the previous full text reports, files/reference CSVs,
and combined totals. These details are optional; normal runs save only the one
summary TXT. `-IncludeNested` inspects reachable scripts, but files called only
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
CSV consumers must account for that prefix. Source files remain unchanged.

Each parsed script is limited to 64 MB by default. Use `-MaxScriptSizeMB 128` for
larger legitimate scripts. Exceeding the limit produces an incomplete result.
Detailed reports include source lines and arguments: keep them in a folder you
control. See [SECURITY-AUDIT.md](SECURITY-AUDIT.md) for the review and remaining
limitations, including concurrent filesystem changes and large directory trees.

Default exit codes: `0` all checked files have matching master calls; `1` some
files have no matching call; `2` the check is incomplete or failed. The highest
code wins for multiple releases. In detailed mode, extra/missing targets,
repetitions, and cycles can also produce `1`.

## Verification

```bat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-Checker.ps1
```

Tests cover parsing, direct versus indirect calls, exclusions, safe reports,
matching CMD/TXT summaries, multiple releases in one TXT, error handling, and
keeping the interactive window open. See `tests\README.md`. Generated test
reports stay under `tests\.work`, outside the fixture releases.
