# Release Script Checker security review

Reviewed October 15, 2026, on Windows PowerShell 5.1.19041.7802.
Scope: `Check-Release.ps1`, the CMD launcher, report generation, permitted
hotfix changes, the regression harness/fixtures, and the distributable ZIP.
This replaces the October 12 review, whose GUID report names and read-only
release behavior no longer described the current utility.

This was a local source review and regression assessment. No critical or
high-severity issue was identified in the reviewed code. This is not a security
certification, a database deployment test, or an audit of hotfix SQL/Perl code.
Actual customer hotfixes and a live SMB server were not exercised in this review.

## Findings addressed in this review

| Finding | Impact and evidence | Updated behavior |
| --- | --- | --- |
| Installer examples mistaken for active code | Medium integrity risk. Four isolated reproductions put the only apparent `my $hotfix` assignment inside POD, a data section, a multiline string, or a heredoc. The previous updater modified each example and reported `Updated`. | Ordinary comments, POD, multiline quoted strings/backticks, and data/end sections do not count as active assignments. Complex contexts such as heredocs, regexes, quote operators and format bodies before a potential assignment cause an explicit failure without rewriting bytes. Exactly one supported active literal assignment is required. Escaped quote delimiters are supported. |
| Live installer truncated during update | Low integrity risk identified in source review. The former write/SetLength sequence could expose a partially written installer if writing failed or execution stopped. No physical disk failure was simulated. | Prepare a complete, flushed sibling using exclusive CreateNew, recheck the source SHA-256/length while denying competing writers, then use Windows file replacement with an original backup. Never fall back to truncating the original. Before-replacement failures remove staging files; replacement failures retain recovery files and report both paths. Fault injection verifies preservation when the original has already moved to its backup name. |
| Input capitalization used as hotfix name | Functional correctness issue. A lowercased path to a mixed-case folder generated a lowercased hotfix name. Windows Get-Item.Name also echoed that input casing. | Resolve the stored folder spelling through a metadata handle and use it for installer values, hook/DOCX filenames, and report names. The regression checks all three mutations through a differently cased input path. |

Follow-up compatibility correction: the initial context guard also rejected the
valid `use Fcntl qw(:DEFAULT :flock);` import in the supplied installer header.
It now recognizes complete one-line `use Module qw(...)` statements containing
only literal symbol/tag names. The whole statement must match; malformed or
multiline lists and trailing executable code do not gain an exception. Imports
are never loaded or evaluated. Other rejected constructs now identify the source
line and column. The supplied header is covered by encoding/BOM tests and a real
CMD update/rerun that verifies only the hotfix value changes.

The installer context guard deliberately supports a limited static subset of
Perl. It is not a Perl compiler, does not determine runtime reachability, and
cannot prove the behavior of arbitrary Perl. Complex or unusual installers
should be reviewed manually when the guard reports that it cannot safely edit
them. Ordinary code after the last potential assignment does not block editing.

## Controls verified

- **Release content stays data.** No SQL, Perl, shell commands, substitution
  variables, or expressions from a release are executed. Unsupported/dynamic
  calls remain unresolved instead of being evaluated. Add-Type compiles only
  fixed application-owned C# for Windows path metadata.
- **Bounded reads and conservative analysis.** Script bytes are size-checked
  before allocation (64 MB by default, configurable up to 1024 MB), read while
  denying writers, decoded strictly with explicit BOM handling, and checked for
  NUL/binary content. Auto mode has the documented per-file Windows-1252
  fallback. Nested traversal stops at cycles and depth 128. Unknown settings or
  incomplete parsing produce exit 2 instead of an unqualified clean result.
- **Filesystem boundaries.** Reports and the utility must stay outside every
  release, with physical Windows path checks covering short-name aliases.
  Paths reject device namespaces/reserved names, alternate data streams,
  drive-relative forms and controls. Junction/symbolic-link paths are rejected
  for mutations and reports; linked release entries are not followed for
  coverage. OneDrive placeholders retain their existing supported behavior.
- **Write protection.** New reports use exclusive CreateNew, refuse overwrite
  and existing hardlinks, and recheck locations before writing. Named report
  folder collisions get numbered suffixes. Installer edits refuse hardlinks,
  do not touch already matching files, and report read-only/sharing failures.
  Script/DOCX renames preserve contents and modification times, refuse name
  collisions/ambiguous candidates, and stay in their direct target directories.
- **Report safety.** Terminal escape/direction controls are displayed as
  `\uXXXX`. CSV data is quoted and formula-like values receive `text:` prefixes.
  Structured fields cannot inject extra summary result lines. Detailed reports
  can contain source text/arguments and inherit the report directory's access
  controls; they are not automatically redacted.
- **External targets.** Calls outside a release are recorded without reading or
  fetching their targets. Explicitly supplied UNC release/report locations
  still use Windows network filesystem access with the current user's rights.
  The CMD launcher starts the installed Windows PowerShell with NoProfile and a
  process-local execution-policy argument; it does not change machine policy.

## Functional verification

The complete regression harness passed **1,099 assertions** on Windows
PowerShell 5.1. This includes real child CMD/PowerShell processes, not only
function-level checks. It exercises:

- Both coverage directions, all 93 supplied allowed-missing entries (92 unique
  normalized filenames), exact/case-insensitive matching, duplicated basenames,
  explicit paths, direct/nested modes, unsupported calls and line diagnostics.
- Separate DATE_TIME_HOTFIX folders and summary_HOTFIX.txt files, collision
  preservation, Toronto AM/PM dates, Executed by, boxed headings, console/TXT
  agreement, detailed CSVs and combined totals. Default output omits ignored
  filenames and the removed manual-review listing.
- Installer changes across UTF-8/Windows-1252 and Unicode BOMs, unchanged
  surrounding bytes/line endings, no-op timestamps, escaped quotes, embedded
  examples, ambiguous content, word/next-line quote delimiters, read-only/linked
  files, blocked replacement and simulated partial-replacement recovery.
- All five hook renames, final inventory names, case-only renames, ambiguity,
  destination conflicts, byte/timestamp preservation and junction rejection.
- DOCX renaming while preserving installation instructions, Office lock files
  and nested documents; exact zero-byte detection with only the four requested
  exclusions; incomplete scans; normal/detailed exit codes and combined totals.
- Malformed encodings, locked/oversized files, Unicode comparison collisions,
  malicious report data, path aliases/devices/streams, overwrite/hardlink
  protection, interactive master selection/confirmation, pauses and error exits.

Fixture paths and SHA-256 hashes are checked before and after the suite.
The security cases and installer-import correction add 109 assertions to the
990-assertion baseline, including 32 for the import compatibility correction.
AST inspection found no syntax errors, dynamic invocation operators, dynamic
command names, or commands for expression execution, downloads, remote sessions,
process launching or persistent policy changes in the PowerShell checker.
A limited scan of the checker, launcher and README found no common private-key,
GitHub token, AWS access-key or OpenAI secret-key patterns; this is not exhaustive
secret detection. The fixed native API and all file mutation sites were also
reviewed manually.

The distributable ZIP is rebuilt from the source/docs/tests/fixtures. Every entry
is compared with its source by SHA-256 before publishing the archive. Generated
reports, test scratch data, and actual releases are excluded.

## Remaining limits

- Path checks and operations are separate. A hostile process with permission to
  replace files or parent directories can still race them. The installer denies
  concurrent content writers during its final check, but permits delete sharing
  required for replacement; this does not lock the whole directory tree. Run on
  folders and report locations you control and avoid concurrent modifications.
- Inventory, parsing and renaming are not one filesystem transaction. Results
  describe the accessible snapshot. Successful permitted mutations are retained
  if another check later fails. Exit 2 requires reviewing the reported reason.
- File replacement depends on the filesystem and Windows/provider behavior.
  Unsupported replacement fails explicitly. Tests cover ordinary local success
  and sharing/read-only failures, not power loss, disk exhaustion, every network
  server, or all filesystem drivers. Replacement errors and interrupted
  processes can leave inert `.release-checker-*.tmp`/`.bak` siblings. Errors
  identify recovery paths; no automatic recovery from interrupted execution or
  disk-durability guarantee is claimed.
- Per-script/depth limits do not set a total CPU/memory/inventory budget. Large
  trees, CSV inputs, long lines and detailed reports can consume resources.
  SMB operations can wait for Windows network timeouts. ACLs, ownership, and
  arbitrary reparse providers are not an operating-system sandbox.
- Static filename coverage does not prove which duplicate SQL*Plus executes,
  runtime SQLPATH/substitution behavior, deployment success, SQL correctness,
  database authorization, or the safety of the deployed scripts themselves.

## Primary references

- [Microsoft File.Replace](https://learn.microsoft.com/dotnet/api/system.io.file.replace)
  and [ReplaceFileW](https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-replacefilew)
  describe replacement, metadata and filesystem failure conditions.
- [Perl syntax](https://perldoc.perl.org/perlsyn) and
  [Perl quoting operators](https://perldoc.perl.org/perlop#Quote-and-Quote-like-Operators)
  describe comments, embedded documentation, strings and heredocs.
