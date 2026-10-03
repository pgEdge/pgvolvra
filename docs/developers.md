# Developer Resources

This document describes how to build, test, and contribute to pgVolvra.
Contributions are welcome.

## Repository layout

The following table describes the top-level directories:

| Path | Contents |
|---|---|
| sql/volvra.sql | The whole engine, as one installable SQL file. |
| cli/ | The command line tool, a Go binary with no runtime dependencies. |
| companion/ | The durable tier, written in Go. |
| extension/ | Optional CREATE EXTENSION packaging, generated. |
| test/ | Test suites and their runners. |
| tools/ | Release helpers. |
| docs/ | This documentation. |

## Building the command line tool

The tool needs the Go toolchain, version 1.25 or later:

```bash
make -C cli
```

Install the tool, or cross-build the tool for a container:

```bash
sudo make -C cli install
make -C cli linux
```

The test runner cross-builds the tool itself and copies the binary
into each container, so a Go toolchain is required to test the tool. A
machine without Go still runs every other suite, and the runner
reports the command line suite as skipped rather than passed.

## Building the companion

The companion needs the Go toolchain, version 1.25 or later, which
is the floor its dependencies declare:

```bash
cd companion
go vet ./...
go build -o volvra-companion .
```

## Running the test suites

The main suite runs every phase against a throwaway container for each
supported PostgreSQL version:

```bash
./test/run.sh              # 14 15 16 17 18 19
./test/run.sh 17           # one version
```

Each version runs the following phases in order:

1. pgVolvra installs as a non-superuser role on a pristine cluster,
   which proves the managed-provider privilege model.
2. pgVolvra installs twice, which proves the install is idempotent.
3. The acceptance suite exercises the documented workflow.
4. The security suite attacks the privilege model as real
   unprivileged roles.
5. The correctness suite covers conflicts, truncates, schema drift,
   and type fidelity.
6. The scope suite covers transaction, predicate, and actor selection.
7. The scale suite covers partitioning, retention, and observability.
8. The trust suite attacks sealing, erasure, and column exclusion.
9. The privilege matrix asserts both directions for every role and
   function pair.
10. The command line suite exercises every command and every exit
    code.
11. The scenario suite covers table shapes, identifiers, schema
    change, foreign keys, partitions, erasure, and the firing mode of
    the capture triggers.
12. The upgrade suite installs the previous release's schema, seeds
    history and a seal, then installs the current schema over it.

Per-version logs land in `test/logs/`.

## Running the concurrency and recovery suites

Two suites drive more than one session at a time, because the
properties most likely to be wrong are the ones written for concurrent
access and for failure:

```bash
./test/concurrency.sh      # 14 15 16 17 18 19
./test/recovery.sh 17
```

The concurrency suite runs parallel `psql` sessions against one
database. The recovery suite crashes the server with
`pg_ctl -m immediate` mid-undo, mid-seal, mid-purge, and mid-install,
kills the companion with `SIGKILL` mid-segment, and fills a one
megabyte tmpfs to exhaust an archive filesystem.

Both suites exercise the companion when a Linux binary is available,
and skip those scenarios loudly when one is not:

```bash
GOOS=linux go build -C companion -o /tmp/volvra-companion .
export VOLVRA_COMPANION_BIN=/tmp/volvra-companion
```

## Verifying a managed provider

Every other suite runs against a container. `test/provider.sh` runs
against a real managed service, because a container cannot withhold the
privileges the design depends on being able to live without:

```bash
./test/provider.sh --dsn "postgres://master@host:5432/probe"
```

The script needs only `psql`, installs pgVolvra into a throwaway
database, and drops the schema afterwards unless given `--keep`. See
the [Managed Providers](managed_providers.md) document for the
per-service steps.

## Running the multi-node suite

One suite needs more than a single server. `test/multinode.sh` builds a
two-node Spock cluster from the `pgedge/pgedge` image and checks what a
node records of its peers' changes:

```bash
./test/multinode.sh
```

It asserts both settings: with `capture_replicated` off a replicated
change arrives in the table and is not captured, and with it on the
same change is captured with both images, so a node can revert a
change it never made. Set `VOLVRA_PGEDGE_IMAGE` to test another image.

## Running the scale suite

The scale suite pushes the limits pgVolvra advertises past their
thresholds, which no other suite does. The suite runs on demand, takes
several minutes, and prints timings for information without asserting
on them:

```bash
./test/scale.sh                # PostgreSQL 17, one million rows
./test/scale.sh 17 200000      # smaller, for a quick check
```

The suite asserts that a million-row undo is refused by the
blast-radius cap and completes when the cap is raised deliberately,
that `volvra.seal` stops at `seal_max_rows` and makes progress across
repeated calls, that `TRUNCATE` is refused above
`truncate_capture_max_rows`, and that retention drops whole partitions
rather than deleting rows.

## Running the companion suite

The companion suite runs separately, because the suite needs a server
started with `wal_level=logical`, a published port, and a Go build on
the host:

```bash
./test/run-companion.sh    # 14 15 16 17 18 19
./test/companion.sh 17 55432
```

## Verifying the examples

Every file in `examples/` is checked against a real database on all six
supported versions, asserting the end state rather than only that psql
exited:

```bash
./test/examples.sh         # 14 15 16 17 18 19
./test/examples.sh 17
```

Two examples print an ERROR deliberately, so the runner also asserts
that those errors occurred.

The decisive test destroys the in-database history entirely, restores
the archive, and then reverts the damage from archived history alone.

## Benchmarking

The benchmark measures throughput, disk, and write-ahead log volume
with and without coverage:

```bash
./test/bench.sh 17 20 3
```

The arguments are the PostgreSQL version, the seconds per run, and the
number of repetitions. The benchmark rebuilds the fixture and
re-establishes coverage for every repetition, and reports the best
result, because interference only ever costs throughput.

Do not compare figures across separate invocations. Throughput drifts
by about ten percent between runs, so the benchmark measures each
configuration side by side within one run.

## Building the extension packaging

The extension script is generated from `sql/volvra.sql`, so the two
cannot diverge:

```bash
cd extension
./build.sh
./test.sh 17
```

The build removes stale generated scripts, because an old script still
installs.

The build also emits an upgrade script for every released version,
named `volvra--<from>--<to>.sql`. PostgreSQL reads the update paths an
extension offers off those filenames, so a missing script makes
`ALTER EXTENSION UPDATE` refuse and leaves an extension-installed
database stranded on the version it has. An upgrade script is
byte-identical to the install script, because the installer applies
only the migrations a database is missing.

The build derives the list of released versions from the snapshots in
`test/releases/`, which `tools/snapshot-schema.sh` writes as part of
cutting a release. Nothing has to be listed by hand. The build refuses
to run if a snapshot is not below `default_version`, because a script
generated from one would declare a downgrade path.

`extension/test.sh` checks that every snapshot has an update path to
the current version before it starts a container, then exercises
`ALTER EXTENSION UPDATE` against a synthetic older version it creates
itself.

## Releasing

The following steps make a release, in this order:

1. Set `default_version` in `extension/volvra.control` to the new
    version.
2. Run `./tools/snapshot-schema.sh`, which freezes the install script
    as `test/releases/volvra-<version>.sql`. The snapshot serves two
    purposes: the next release's upgrade test runs against it, and it
    is how `extension/build.sh` learns that this version was released
    and needs an update path. The tool refuses to overwrite a
    snapshot, because a released schema never changes.
3. Run `make -C cli release` and `make -C companion release`, which
    build the two static binaries per component and their checksums.
4. Run the full matrix, the examples, and the portability suite.
5. Tag the release.

Step 2 is the one that is easy to skip and impossible to redo.
Reconstructing a released schema afterwards is guesswork exactly when
accuracy matters, and the guess cannot be checked because the release
it describes is gone.

## Waiting for a container

Every suite waits for its container through `volvra_wait_ready` in
`test/lib.sh`, which requires a real query to succeed twice in a row.
`pg_isready` alone is not enough: the PostgreSQL image starts a
temporary server so that initialisation scripts can run, and
`pg_isready` answers yes during that window. A suite that trusted the
answer connected too early and reported fifteen product failures when
the real problem was a server that had not finished starting.

A suite whose container never becomes ready aborts and prints the
container log, rather than running assertions against a database that
is not there.

## Continuous integration

The GitHub Actions workflow runs the main suite, the examples, the
concurrency suite, the recovery suite, the companion suite, and the
extension packaging, with one job per PostgreSQL version and
`fail-fast` disabled so one version cannot hide the others.

The workflow runs on demand only, through the Actions tab or
`workflow_dispatch`. Six PostgreSQL versions across six suites is
thirty-one jobs, each starting its own containers, which is a real
bill for a project whose suites are run locally before every commit.
Restore the `push` and `pull_request` triggers in
`.github/workflows/test.yml` to change that.

## Testing conventions

Every check is a PL/pgSQL `ASSERT` with a message that states what
should have been true. Suites run under `ON_ERROR_STOP`, so the first
failure stops the run and names the assertion.

Negative tests wrap the operation in an exception handler and assert
both that the operation failed and that the operation failed for the
right reason.

## Release helpers

The following command prints the values a release should publish:

```bash
./tools/checksums.sh
```

pgVolvra installs as a file rather than a signed package, so a release
must publish a checksum, and ideally a signature, for the installer to
verify.

## Building the documentation

The documentation builds with MkDocs and the Material theme. Install
the pinned dependencies and serve the site locally:

```bash
pip install -r requirements.txt
mkdocs serve
```

The pins in `requirements.txt` match the primary pgEdge documentation
site, because that is the environment this project's `docs` directory
is built in when the site imports the directory. The pins also hold
MkDocs at 1.x on purpose: the Material team reports that MkDocs 2.0
removes the plugin system and rewrites theming, with no migration
path, and this project uses a theme override for its logo.

Confirm the site builds with no warnings before committing
documentation changes:

```bash
mkdocs build --strict
```

The `mkdocs.yml` and `docs` directory are self-contained and valid on
their own, which the primary site requires. Do not add configuration
that only works in the primary site context, such as redirects,
analytics, or a consent banner.

## Design decisions

The `DECISIONS.md` file in the repository root records the vocabulary
and design decisions that have already been argued, including what
each choice beat and why the alternative lost. Read the file before
renaming anything.

## Contributing

We welcome your project contributions. Open an issue to discuss a
change before starting substantial work.

For more information, visit
[docs.pgedge.com](https://docs.pgedge.com).
