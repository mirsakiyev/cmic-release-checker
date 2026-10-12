# Test fixtures and expected results

Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-Checker.ps1`
from the utility folder. Tests need Windows PowerShell 5.1, but no Pester or external
dependencies. They retain generated cases and reports outside fixture releases in
`tests\.work`. Do not execute any fixture scripts yourself.

| Fixture | Mode | Discovered | Excluded | Eligible | Direct | Not direct | Indirect only | Exit |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Release one | Direct | 36 | 8 | 27 | 16 | 11 | Not checked | 2 |
| Release one | Nested | 36 | 8 | 27 | 16 | 11 | 1 | 2 |
| Release two | Direct | 2 | 1 | 0 | 0 | 0 | Not checked | 1 detailed / 0 simple |
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

Normal runs must save exactly one `summary.txt`, with the same summary displayed
in CMD. The harness verifies complete and incomplete counts, the full plain list
of uncalled files, multiple releases in the same TXT, unreadable masters, and
the absence of call traces/CSV files by default. Extra or repeated master targets
do not change a complete file-coverage result in simple mode. Detailed-report
checks explicitly pass `-DetailedReport` and retain their original expectations.

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
