# Test fixtures and expected results

Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-Checker.ps1`
from the utility folder. Tests need Windows PowerShell 5.1, but no Pester or external
dependencies. They retain generated cases and reports outside fixture releases in
`tests\.work`. Do not execute any fixture scripts yourself.

| Fixture | Mode | Discovered | Excluded | Eligible | Direct | Not direct | Indirect only | Exit |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Release one | Direct | 36 | 8 | 27 | 13 | 14 | Not checked | 2 |
| Release one | Nested | 36 | 8 | 27 | 13 | 14 | 1 | 2 |
| Release two | Direct | 2 | 1 | 0 | 0 | 0 | Not checked | 1 detailed / 0 simple |
| Clean | Either | 2 | 0 | 1 | 1 | 0 | 0 if nested | 0 |
| Settings | Direct | 4 | 0 | 3 | 2 | 1 | Not checked | 1 |
| Settings | Nested | 4 | 0 | 3 | 1 | 2 | 0 | 2 |

`expected-release-one.csv` specifies the exact eligible file rows, direct status,
nested status, matching method, and counts. Release one's two missing calls are
`wrong\py_post.pb` and `missing.sql`; `dup.pb` has two ambiguous candidates;
`&release_script` is unresolved. `py_post.pb` and `same.sql` each have two direct
call sites. Nested mode adds two indirect call sites for `indirect.sql`, one cycle
back to the master, and a third repeated target. There are 19 direct call-site
records and 22 records with nesting. Commented, output-only, SQL literal-only,
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
