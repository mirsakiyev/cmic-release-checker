# Release Script Checker security review

Reviewed on October 12, 2026, using Windows PowerShell 5.1.19041.7725.
The scope was the complete checker source, CMD launcher, configuration and
documentation, test harness, fixtures, and distributable ZIP contents. The real
hotfix was used to verify unchanged behavior; its deployment SQL was not audited
for database vulnerabilities. There are no downloaded runtime dependencies or
configured Git remotes. This was a local source review and regression assessment,
not a cloud scan or independent penetration test.

## Findings and fixes

Severity considers a desktop utility running with the current user's permissions.
No critical or high-severity issue was identified in the reviewed state.

| Finding | Severity | Evidence and final behavior |
| --- | --- | --- |
| CSV formula interpretation | Medium | The earlier CSV writer preserved `=1+1` as a cell value. Untrusted values are now quoted as CSV data, control characters are escaped, and formula-like beginnings receive a visible `text:` prefix. Tests include quotes, separators, leading spaces, and fullwidth operator characters. |
| Unicode filename collisions | Medium | A master calling `strasse.sql` incorrectly covered a different file named `straße.sql`, due to PowerShell's linguistic hashtable comparer. Inventory indexes, caches, traversal, master/source identity, direct matches, and repeated-target aggregation now use ordinal case-insensitive filename comparison. Exact matches still work. |
| Windows device path normalization | Medium | On .NET Framework, normalizing an ordinary-looking `NUL.sql` path produced `\\.\NUL`. Validation now runs before and after normalization. DOS device names, console devices, device namespaces, alternate streams, drive-relative paths, and control characters are rejected. |
| Report overwrite and hardlinks | Low | The previous report writers could truncate an existing destination. Reports now use exclusive `FileMode.CreateNew` creation, full GUID run-folder names, and destination checks before each write. Regression tests preserve the bytes of both an existing file and its hardlink target. |
| Filesystem aliases in location checks | Defense in depth | The former lexical containment check missed an 8.3 short-name alias. On this OneDrive checkout, the separate link check already rejected that alias, so a complete write bypass was not reproduced. Report and utility location checks now additionally resolve Windows filesystem identities through metadata-only handles. The alias regression is rejected as being inside the release before any directory is created. |
| Terminal and report spoofing | Low | Release text could contain terminal escape sequences or invisible direction controls. Output now shows these as `\uXXXX` evidence. Invalid CSV input line breaks are escaped in structured summary fields, preventing an injected second result line. |
| Unbounded script byte allocation | Low | The earlier reader allocated the entire script without a size limit. The new reader checks size before allocation, closes handles on success or failure, and disallows concurrent file writers while reading. The default limit is 64 MB per parsed script; `-MaxScriptSizeMB` permits an explicit increase up to 1024 MB. Oversized input produces an incomplete result. |

The native path helper contains fixed, application-owned C# source and uses only
Windows metadata APIs. Release content is never passed to the compiler or
evaluated as PowerShell, SQL, shell commands, variables, or expressions.

## Review and verification

- All **712 assertions passed** under Windows PowerShell 5.1, including the 601
  original security-review assertions. Existing parser,
  matching, reports, encoding, error handling, nested traversal, and interactive
  behavior cases were retained alongside the security regressions.
- Real child PowerShell and CMD processes verified master auto-detection and Y/N
  confirmation, manual fallback, selecting master number 20, keeping the window
  open, exit codes, and the single default TXT matching the console summary.
- Test fixtures' paths and SHA-256 hashes remained unchanged.
- The old and updated checkers produced identical coverage summaries and exit
  codes for the real hotfix: **53 checked, 25 called, 28 with no matching call**.
  Both retained the incomplete result for unsupported content. All release file
  paths and SHA-256 hashes were unchanged across these runs.
- AST parsing found no syntax errors, dynamic invocation operators, or commands
  for expression evaluation, process launching, downloading, deletion, module
  importing, or persistent execution-policy changes in the checker. Manual
  review also inspected file and native API calls. A source/fixture scan found
  no matches for common private-key, access-token, and credential patterns; this
  does not guarantee the absence of every possible secret.
- Packaging checks compare each ZIP entry with its staged source by SHA-256.
  Generated reports, temporary test cases, and actual release data are excluded.

The launcher uses `-NoProfile` and a process-local execution-policy argument; it
does not change the machine's policy or request elevation. References outside
the supplied release are reported without probing or fetching their targets.
An explicitly supplied UNC release or report folder still involves normal
Windows network filesystem access.

## Simplification and compatibility

Shared counts replace duplicated per-release and combined-report calculations.
One strict encoding/BOM table replaces separate decoder construction branches.
Common report writers centralize text escaping and safe file creation. The CMD
launcher is **8 lines instead of 11**, retaining its single interactive pause.

The PowerShell source is **1026 lines instead of 842**, including the mapped-drive
and encoding follow-ups below. Removed duplication was
offset by the added security protections. No lexer, resolution, validation,
read-only safeguard, or established feature was removed to force a smaller
source file. Master detection, all 17 exclusions, one default TXT for multiple
releases, optional detailed reports, and optional nested checking are preserved.

Detailed CSV consumers must account for the new visible `text:` prefix on
formula-like values and `\uXXXX` escapes. These transformations affect reports,
not source files or the filename values used for coverage matching.

## Remaining limits

- Path checks and file opens are separate operations. Another process able to
  rename or replace a parent directory between them can still create a race.
  Use a report directory you control; permissions are inherited from that
  directory. This utility is not an operating-system sandbox.
- A release can change between inventory and script reads. Static results are
  a snapshot, not an atomic deployment manifest. Per-file read locks do not
  lock the entire release tree.
- Per-script size and nested-depth limits do not impose a total inventory,
  CPU, or memory budget. Very large trees, long lines, many reachable scripts,
  or detailed reports can still consume substantial resources.
- Live UNC, mapped-drive, and DFS environments were not integration-tested in
  this review. If Windows cannot resolve filesystem metadata or access a
  required path, the checker fails the check instead of assuming containment.
- The parser remains conservative. Unsupported commands, dynamic targets,
  inaccessible content, and unmodeled SQL*Plus settings require manual review.
  Static filename coverage does not prove successful deployment execution.
- Detailed reports retain source text and arguments. They can contain sensitive
  values from the release; no automatic secret redaction is performed. The
  checker does not upload or transmit reports.

## Mapped-drive performance follow-up

A reported stall after `Checking release` involved a mapped network drive.
Inspection found that the checker evaluated PowerShell's lazy `LinkType` and
`Target` properties for every inventory entry. Provider metadata queries on
ordinary files were unnecessary. The checker now examines the cached
`ReparsePoint` attribute first and queries link properties only for reparse
entries. Junction checks and cloud-placeholder handling remain covered by tests.
The exact stall on the user's work share could not be reproduced here.

Ordinary SQL lines without quote/comment markers and without an active literal
or block-comment state also avoid character-by-character lexing. All other
lines retain the full lexer. Phase messages and throttled file/line progress
make ongoing work visible; `-Verbose` adds folder and script details. The saved
summary stays unchanged. Native Windows calls can still wait on server timeouts.

On this host, a test modeling slow metadata getters made 60 extra queries before
the fix and zero after it for 20 ordinary-entry checks. A 10,000-line ordinary
SQL sample took 5.143 seconds before and 1.416 seconds after, with the same one
call detected. These are local measurements, not live network benchmarks or
performance guarantees. The 612-assertion suite and real-hotfix comparison
passed; real release files retained their hashes and coverage results.

## Legacy encoding follow-up

After the mapped-drive scan completed, a work master failed strict UTF-8 decoding
on byte A0. A legacy ANSI encoding is a possible cause; the file's actual encoding
was not inferred automatically. `-ScriptEncoding Default` already selects the
Windows PowerShell host's active code page. `-ScriptEncoding Windows1252` now
provides an explicit Western Windows-1252 choice independent of that locale.

The earlier interactive encoding confirmation has been replaced at the user's
request. The default is now `Auto`: strict UTF-8 first, with Windows-1252 fallback
only for a no-BOM file that fails UTF-8 decoding. Both interactive and automated
runs continue without an encoding question. Every fallback is recorded in the
summary, applies only to that file, and leaves UTF-8 child decoding unchanged.
Explicit `-ScriptEncoding UTF8` retains strict rejection without fallback.

Malformed BOM content still reports an error without an ANSI retry, BOMs still
take precedence, binary/NUL rejection remains enabled, and no source bytes are
changed. Tests reproduce an A0-bearing master around the reported offset,
preserve accented filenames and a UTF-8 child, and verify calls after the byte.
Actual PowerShell and CMD processes cover automatic fallback, strict decoding,
the final pause, and console/TXT agreement. The real-hotfix coverage
and source hashes remain unchanged.

## Master coverage and multiline SQL follow-up

The supplied TOR-21 master reproduced a parser defect: multiline PL/SQL `EXECUTE
IMMEDIATE` was classified as a one-line SQL*Plus invocation, and its quote state
was reset. Closing literal quotes then opened false literals and hid later calls.
Dynamic SQL now retains its multiline quote state, while embedded START-looking
text stays excluded. SQL*Plus PAUSE and control text no longer create SQL literal
state from prompt or credential punctuation. Genuine unterminated comments and
literals identify their opening line and source.

For the user's filename-coverage requirement, a bare START/@ filename in the
master now covers every ordinal, case-insensitive exact basename in the release.
This explicitly includes copies in `sql` and `uig\sql`. Reports identify these
as filename-presence matches; this is not proof that every copy executes.
Explicit paths, @@ caller-relative paths, Unicode lookalikes, variables, links,
and unsupported syntax retain their guards. Nested traversal reads only the
resolved primary path and reports an ambiguous nested path rather than reading
extra copies by guessing.

The user's 4,807-line TOR master now parses with zero lexer errors and 195 START
calls. A local 171-file inventory replica built from the supplied report and
placeholder file contents reproduced 1 matched / 105 uncalled before the fix,
then 53 matched / 53 uncalled afterward. The old and new runs both retained
incomplete status for unsupported invocations; the false unterminated-literal
reason disappeared. Replica source hashes and console/TXT agreement were verified.
This validates the supplied master text and filename inventory, not the actual
network files or their raw encodings. The real local hotfix still reports
53 checked / 25 called / 28 uncalled with unchanged source hashes.

## Primary references

- [OWASP: CSV Injection](https://community.owasp.org/attacks/CSV_Injection)
  explains formula interpretation and the limitations of ordinary CSV escaping.
- [Microsoft: FileMode.CreateNew](https://learn.microsoft.com/en-us/dotnet/api/system.io.filemode?view=netframework-4.8.1)
  documents refusal to overwrite an existing file.
- [Microsoft: Windows file naming](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file)
  documents reserved names and path conventions.
- [Microsoft: CreateFile](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew)
  and [GetFinalPathNameByHandle](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew)
  document metadata handles and resolved filesystem paths.
- [PowerShell provider source](https://github.com/PowerShell/PowerShell/blob/v6.0.0/src/System.Management.Automation/namespaces/FileSystemProvider.cs#L7393)
  shows the Windows metadata and hardlink queries behind link properties in the
  .NET Framework implementation.
- [Microsoft: Encoding.Default](https://learn.microsoft.com/en-us/dotnet/api/system.text.encoding.default?view=netframework-4.8.1)
  documents the active-code-page behavior of .NET Framework and its dependence
  on machine configuration.
- [Oracle: EXECUTE IMMEDIATE](https://docs.oracle.com/en/database/oracle/oracle-database/19/lnpls/EXECUTE-IMMEDIATE-statement.html)
  documents the PL/SQL statement for dynamic SQL.
- [Oracle: PAUSE](https://docs.oracle.com/en/database/oracle/oracle-database/21/sqpug/PAUSE.html)
  documents SQL*Plus message text rather than a SQL literal.
