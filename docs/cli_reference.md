# CLI Reference

This document documents the `volvra` command line tool, its commands,
and its options. The tool wraps the SQL functions and adds a
confirmation step before anything changes.

## What the tool is for

Every operation the tool performs is available directly in SQL, so the
tool adds no capability. The tool adds one thing SQL cannot: the tool
shows the plan, names any conflicts, asks once, and only then applies.

The tool also refuses to apply a change when no terminal is present,
unless you pass `--yes` deliberately. A scheduled job or a pipe
therefore cannot silently rewrite production data.

## Supported platforms

pgVolvra ships two binaries per component, one for each architecture, and
each binary is statically linked with no libc dependency. One binary
therefore covers every distribution below. The following table
describes the supported platforms:

| Architecture | Binary | Runs on |
|---|---|---|
| x86-64 | volvra-linux-amd64 | EL9, EL10, Debian 11 through 13, Ubuntu 22.04 through 26.04 |
| ARM64 | volvra-linux-arm64 | The same distributions on ARM |

The binaries are built with `CGO_ENABLED=0`, which is what makes one
binary per architecture sufficient. With cgo enabled, the `net` and
`os/user` packages link libc dynamically, and a binary built on a newer
distribution then refuses to start on an older one, reporting a missing
`GLIBC` version before the program runs. A static binary has no such
dependency.

The compatibility floor is set explicitly rather than left to the Go
toolchain's default: `GOAMD64=v1` is baseline x86-64, requiring no
SSE4, AVX, or POPCNT, and `GOARM64=v8.0` is the ARMv8.0-A baseline that
EL9 targets.

One consequence is worth knowing. A static binary uses Go's own
resolvers rather than the system name service switch, so `/etc/hosts`,
`/etc/resolv.conf`, and `/etc/passwd` are consulted while LDAP and SSSD
are not. Give the tool a username explicitly, through `PGUSER` or the
connection string, on a host where the login accounts come from a
directory service.

`./test/portability.sh` runs both binaries on every distribution in the
table above, against a real database reached by hostname.

## Building the tool

The tool is a single Go binary in `cli/`, with no runtime
dependencies. Build the tool with Go 1.25 or later:

```bash
make -C cli
```

Install the tool onto your path:

```bash
sudo make -C cli install
```

Cross-build the tool for a container:

```bash
make -C cli linux
```

## Connecting

The tool uses the standard PostgreSQL environment variables, so
`PGHOST`, `PGDATABASE`, `PGUSER`, and the rest work as usual. Pass a
connection string instead with `--dsn`:

```bash
volvra --dsn "postgres://user@host/db" status
```

## Exit codes

A scheduled job needs to distinguish a command that failed from a
command that worked and found something wrong. The following table
describes each exit code:

| Code | Meaning |
|---|---|
| 0 | The command succeeded. |
| 1 | The command failed, or a confirmation was declined. |
| 2 | The command worked and what it found is bad. |

Code 2 comes from two commands. `volvra preflight` returns the code
when the install has a critical finding, and `volvra verify` returns
the code when a sealed span does not match the history and no recorded
erasure or retention explains the mismatch.

## Times

Every option that takes a time accepts what PostgreSQL accepts,
resolved on the server, so the clock that interprets a time is the
clock that wrote the history. That includes `today`, `yesterday`, an
ISO timestamp, and a trailing `ago`:

```bash
volvra preview --table orders --since '10 min ago'
volvra preview --table orders --since yesterday --until today
volvra preview --table orders --since '2026-09-08 14:00+00'
```

The `--to` option names a mark instead of a time, and sets the start of
the window to the moment that mark was taken. Passing `--to` and
`--since` together is refused, because both set the same bound.

## Command summary

The following table describes each command:

| Command | Purpose |
|---|---|
| status | Report what is covered and whether capture is running. |
| uncovered | List tables with no undo. |
| cover | Start covering a table or a schema. |
| uncover | Stop covering a table or a schema, keeping history. |
| mark | Name a moment you may want to return to. |
| marks | List marks, and what undoing to each would cost. |
| unmark | Remove a mark. The history is untouched. |
| log | List recent transactions, newest first. |
| history | Show every version of one row. |
| as-of | Show the table as it was at a past time. |
| preview | Show the compensating SQL and change nothing. |
| undo | Show the plan, ask once, then apply. |
| preview-replay | Show what reapplying the selection would do. |
| replay | Reapply the selection forward, after a restore. |
| preflight | Report whether the install is shaped for production. |
| maintain | Extend partitions, apply retention, and seal. |
| seal | Make the history captured so far provable. |
| verify | Re-check every seal against the history. |
| forget | Erase one subject's history, after confirming. |
| help | Print usage. |

## Global options

The following table describes the options every command accepts:

| Option | Description |
|---|---|
| --dsn DSN | The libpq connection string. Otherwise the PG environment variables apply. |
| --yes, -y | Skip the confirmation prompt. |
| -h, --help | Print usage. |

Both options may appear before or after the command name.

## Selecting what to undo

The `preview` and `undo` commands take the same selector. At least one
criterion is required. The following table describes each option:

| Option | Description |
|---|---|
| --table TABLE | Limit the selection to one table. |
| --txid N | Select one transaction. |
| --since WHEN | Select changes after this time. |
| --until WHEN | Select changes up to this time. |
| --actor NAME | Select changes an application declared it made. |
| --user NAME | Select changes one database role made. |
| --where SQL | A predicate over old_row, new_row, and pk. |
| --to NAME | Everything recorded since the mark NAME. |

Time values are interpreted by PostgreSQL rather than by the tool, so
relative expressions such as `10 min ago` and `today` work, and the
clock that matters is the server's. See the Times section above.

The following table describes the options that change how an undo
applies:

| Option | Description |
|---|---|
| --max-rows N | Raise the blast-radius cap for this call. |
| --skip-conflicts | Revert what still matches and leave changed rows alone. |

## Command-specific options

Several commands take options of their own. The following table
describes each one:

| Command | Option | Description |
|---|---|---|
| cover, uncover | --schema SCHEMA | Act on every eligible table in a schema rather than one table. |
| log | -n N | Return at most N transactions. The default is 20. |
| log | --since WHEN | Return only transactions after this time. |
| forget | --hard | Delete the history rows outright rather than redacting them. Use when the primary key is itself personal data. |
| forget | --reason TEXT | Record why the erasure was performed, in volvra.erasure_log. |
| mark | --note TEXT | Record why the mark was taken. |
| mark | --replace | Move an existing mark to now, rather than failing. |

The `--hard` option is irreversible and removes the change records as
well as their content. Redaction, which is the default, keeps the
record that a change happened.

## Examples

List the five most recent transactions:

```bash
volvra log -n 5
```

Preview reverting one service's work since this morning:

```bash
volvra preview --actor svc:pricing --since today
```

Revert a mistaken migration by transaction, with a confirmation
prompt:

```bash
volvra undo --txid 848291
volvra replay --table orders --since '2026-09-08 14:00+00'   # after a restore
```

Revert one customer's rows within the last hour:

```bash
volvra undo --table orders --since '1 hour ago' \
    --where "old_row->>'customer' = 'acme'"
```

Start covering every table in a schema:

```bash
volvra cover --schema public
```

Mark a moment before a deployment, then rewind to it:

```bash
volvra mark before-deploy --note 'release 042'
volvra marks
volvra undo --to before-deploy
```

Show the history of one row:

```bash
volvra history orders '{"id":1}'
```

Erase one subject's history, naming the reason:

```bash
volvra forget people '{"id":1}' --reason 'GDPR art.17'
```

Delete the history rows outright, for a subject whose primary key is
itself personal data:

```bash
volvra forget subscribers '{"email":"ada@example.com"}' --hard \
    --reason 'GDPR art.17'
```

List the ten most recent transactions since this morning:

```bash
volvra log -n 10 --since today
```

## Scheduling

The `maintain` command is the only command worth scheduling:

```bash
volvra maintain
```

Run the command hourly or daily. The interval you choose is also the
width of the window in which tampering would go undetected.

## Exit codes

The following table describes the exit codes:

| Code | Meaning |
|---|---|
| 0 | Success. |
| 1 | The command failed, or the user declined the confirmation. |
| 2 | A check found a critical problem, as with preflight and verify. |

## Piping output

Commands run more than one query, so piping a command into a program
that closes the pipe early, such as `grep -q`, can terminate the
command with a broken pipe. Capture the output first when scripting:

```bash
out=$(volvra status)
```

## Next Steps

- The [Undoing Changes](undoing_changes.md) document explains the
  selector in SQL terms.
- The [Function Reference](function_reference.md) document documents
  the underlying functions.
