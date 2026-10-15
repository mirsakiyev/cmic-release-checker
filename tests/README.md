# Test fixtures and expected results

Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-Checker.ps1`
from the utility folder. Tests need Windows PowerShell 5.1, but no Pester or external
dependencies. They retain generated cases and reports outside fixture releases in
`tests\.work`. Do not execute any fixture scripts yourself.

| Fixture | Mode | Discovered | Excluded | Eligible | Direct | Not direct | Indirect only | Exit |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Release one | Direct | 36 | 8 | 27 | 16 | 11 | Not checked | 2 |
| Release one | Nested | 36 | 8 | 27 | 16 | 11 | 1 | 2 |
| Release two | Direct | 2 | 1 | 0 | 0 | 0 | Not checked | 1 |
| Clean | Either | 2 | 0 | 1 | 1 | 0 | 0 if nested | 0 |
| Settings | Direct | 4 | 0 | 3 | 2 | 1 | Not checked | 1 |
| Settings | Nested | 4 | 0 | 3 | 1 | 2 | 0 | 2 |

`expected-release-one.csv` specifies the exact eligible file rows, direct status,
nested status, matching method, and counts. Release one's two missing calls are
`wrong\py_post.pb` and `missing.sql`; `dup.pb` covers both exact-name copies;
`&release_script` is unresolved. `py_post.pb` and `same.sql` each have two direct
call sites. Nested mode adds two indirect call sites for `indirect.sql`, one cycle
back to the master, and a fourth repeated target. There are 22 direct file-match
records and 25 records with nesting. Multiple copies are separate matches to
the same source line; they do not imply execution of every copy. Commented,
output-only, SQL literal-only,
substring lookalikes, and unrelated scripts never contribute coverage.

Release two must not match `py_post.pb` from Release one. In Settings, nested
`SET SUFFIX` makes the extensionless master call unresolved and prevents guessing
between `.sql` and `.pb`. Direct-only mode does not inspect the child and uses its
documented default suffix assumption.

The harness also generates isolated cases for distinct `@`/`@@` path bases,
absolute/external paths, UNC targets, URLs, continuation and quoting errors,
unsupported content, malformed encodings, read locks, and junctions. It exercises
real child PowerShell/CMD processes for reports, combined totals, safe destinations,
master validation, master menus/manual entry, and interactive pause behavior.
It also selects master number 20 in a real child PowerShell process, checks that
the process stays alive after results or errors, and sends a separate Enter to
close it. Standard `SET DEFINE ON`/`OFF` must not erase literal file matches.
Folder-name master detection is checked with spaces and mixed case: Y must use
the detected file, N must allow a manually entered master, and blank/invalid
confirmation answers must re-prompt. A missing candidate keeps the numbered menu.

Normal runs must save exactly one `summary_HOTFIX.txt` per hotfix, with the same
summary displayed in CMD. Each hotfix gets its own `DATE_TIME_HOTFIX` folder.
The startup and main summary headings use the requested 83-column asterisk
boxes. Saved summaries and console output must retain the same section order,
counts, filenames, and username. The normal summary omits the two general
incomplete-check notes, while exit codes and detailed diagnostics are retained.
The harness verifies complete and incomplete counts, the full plain list
of uncalled files, separate multi-hotfix reports, unreadable masters, and
the absence of call traces/CSV files by default. Missing required master targets
produce exit 1 in normal mode, independently of folder-to-master coverage.
Repeated present targets alone still pass normal mode. Detailed-report
checks explicitly pass `-DetailedReport` and retain their original expectations.

The master call file check follows the existing coverage section in both report
modes. Cases cover all 93 supplied exception entries, case-insensitive whole
filenames, default `.sql` suffixes, `START`/`@`/`@@`, quoted arguments, explicit
paths inside and outside the hotfix, and targets with excluded extensions.
Multiple inventory copies count as one call per source line. Comments, SQL
literals, and output text never create missing calls. Supplied exception files
retain normal coverage; lookalikes, variables, and unknown suffixes cannot gain
an exception. Nested calls retain their existing diagnostics. Real CMD runs
verify exit codes, identical console/TXT sections, and `IgnoredMissing` evidence
in detailed reference CSVs. Read failures must never report successful presence.
Normal CMD/TXT summaries must omit ignored-call filenames, the manual-review
list, and empty-target placeholders while retaining the ignored-call count and
required missing files with line numbers. Only `START`/`@`/`@@` calls contribute
to master file-call counts; unsupported command diagnostics stay in detailed
reports. Unresolved actual script calls retain an incomplete result and a short
note pointing to the detailed source lines and reasons.

Report naming cases cover the exact supplied hotfix name, Toronto daylight and
standard time, 12-hour AM/PM formatting, and numbered collisions that preserve
earlier reports. Installer cases preserve all bytes outside the active
`my $hotfix` value, including other variables, commented assignments, trailing
comments, UTF-8/Windows-1252, all supported Unicode BOMs, and LF/CRLF endings.
An already matching installer must retain its hash and modification time, even
when read-only. Missing or duplicate assignments must remain unchanged and
produce an incomplete result. Existing SQL fixture hashes must still match.
Additional security cases reject assignment examples in POD, data sections,
multiline strings and backticks; complex heredoc, regex, quote-operator and
format contexts must fail without modifying bytes. Unambiguous assignments
around documentation, strings, data markers, and CR-only line endings still
update correctly. Escaped quote/interpolation characters must round-trip and
already matching values remain unchanged. A competing read handle must block
replacement, preserve the original bytes, remove the staging file, and allow a
successful retry after closing. Differently cased input paths must retain the
stored release-folder spelling in installer values and renamed files.
Quote operators with word or next-line delimiters are also rejected. A separate
fault-injection case simulates replacement failing after the original is moved:
both the byte-identical original backup and the complete prepared replacement
must survive, with recovery paths in the summary and exit 2. This models a
documented Windows error condition; it does not simulate physical disk failure.

Installer import regressions use the supplied module/header declarations,
including `use Fcntl qw(:DEFAULT :flock);`, in the encoding/BOM cases and a real
CMD run. Only the `my $hotfix` value may change; patch settings, imports and the
remaining installer body stay byte-identical. CMD/TXT output must agree, no
staging/backup files remain on success, and reruns must preserve the hash and
timestamp. Namespaced modules, empty literal lists, whitespace and trailing
comments are supported. Multiline/malformed import lists and an import followed
by additional code are not blindly skipped; rejected syntax includes its source
line and column. Installer content is only read as text and is never executed.

Hotfix filename cases cover all five `.perl`/`.undeploy` suffixes, case-only
renames on Windows, unchanged bytes and modification times, and already matching
names. The inventory must see final names before resolving master calls. Backups,
`.pl` files, unrelated prefixes/suffixes, and nested files keep their names.
Duplicate suffixes and existing destination directories must not overwrite
anything; unrelated unambiguous suffixes can still be renamed. A `sql` junction
must not rename an external file. Real CMD runs verify all five resulting names,
matching console/TXT rename notes, the execution-user header, and quiet reruns.

Zero-byte checks include recursive paths, the selected master, ZIP/DOCX/bundle
and other extensions excluded from call coverage, and mixed-case `.pl`/`.perl`/
`.undeploy`/`.txt` exclusions. Nonempty files smaller than 1KB must not count.
Findings must return exit 1 even when master coverage passes. A complete clean
scan must say `0KB files were not found`; a skipped directory must not make that
claim. Original file hashes must remain unchanged by this check.

Documentation cases include the usual pair of DOCX files: the installation
instructions must retain their name, bytes and modification time while the
other document is renamed. Tests also cover case-only renames, older release
numbers, already matching names, Office lock files, nested documents, multiple
candidates, destination directories, and junctions. Empty renamed DOCX files
must appear in zero-byte output under their final name. Real CMD and detailed
runs verify zero-byte exit codes, saved/console summaries, and combined totals.

Security cases cover Unicode filename collisions, master/source identity, CSV
formula prefixes and quote/separator payloads, terminal escape and direction
controls, invalid-input result-line spoofing, report overwrite/hardlink prevention,
short-name report destinations, reserved devices before/after path normalization
and alternate streams, explicit size limits, and all five
supported Unicode BOMs. Fixture paths and hashes must remain unchanged.

Mapped-drive regressions verify that ordinary file/directory entries never
evaluate lazy LinkType/Target getters, while junction and cloud-placeholder
behavior is preserved. Long ordinary SQL lines retain subsequent calls, PROMPT
text remains ignored, and a real CMD run shows each checking stage without
changing its saved summary. These cases model metadata access; they do not
connect to a live SMB server.

Encoding regressions include a no-BOM Windows-1252 master with byte A0 near the
reported failure position and an accented target filename. Explicit strict
UTF-8 fails with a useful rerun command; automatic or explicit Windows1252
finds calls before and after
the offending byte. BOM overrides, source hashes, binary rejection, and actual
CMD argument forwarding are also checked.

Real interactive PowerShell, automated, and double-click CMD runs use per-file
Windows-1252 fallback without an encoding question. This preserves calls around
byte A0, source hashes, the final pause, and identical console/TXT summaries.
A no-BOM UTF-8 child retains its accented target and indirect call after its
ANSI master uses fallback. Explicit strict UTF-8 and malformed BOM-declared
Unicode still fail without changing encoding. The harness reads
the child process's console encoding so redirected accented output is decoded
correctly.

Parser regressions use the supplied TOR master pattern: multiline `EXECUTE
IMMEDIATE` SQL followed by package, UIG data, and JSR calls. Calls inside dynamic
SQL, UPDATE literals, alternate literals, and comments must never count; active
calls after these constructs must remain visible. Genuine unclosed literals or
comments report their opening line and source. SQL*Plus control/prompt text with
apostrophes cannot consume later calls. Exact duplicate basenames cover all
release copies for bare master START/@ calls; explicit paths, @@ paths, substring
lookalikes, and nested path selection retain their separate expectations.
