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

- All **601 assertions passed** under Windows PowerShell 5.1. Existing parser,
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

The PowerShell source is **925 lines instead of 842**. Removed duplication was
offset by the added security protections. No lexer, resolution, validation,
read-only safeguard, or established feature was removed to force a smaller
source file. Master detection, all 14 exclusions, one default TXT for multiple
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
