package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"time"

	"github.com/jackc/pglogrepl"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgproto3"
)

// The companion decodes with pgoutput, the only logical decoding plugin built
// into PostgreSQL -- and therefore the only one available on a managed
// provider, where a server-side extension is not an option. That constraint is
// the same one that keeps the trigger tier in plain SQL.

type relation struct {
	name   string // schema-qualified, quoted
	cols   []string
	pkCols []string
}

type Streamer struct {
	repl *pgconn.PgConn // replication connection
	meta *pgconn.PgConn // ordinary connection, for catalog lookups
	slot string
	// skipTo is the last LSN already durable in the archive at startup.
	// Anything at or below it is a replay, not a new change.
	skipTo pglogrepl.LSN
	pub    string
	arch   *Archive
	rels   map[uint32]*relation
	guard  *SlotGuard

	commitTS time.Time
	xid      uint32
	changes  int64
	skipped  int64
}

func NewStreamer(ctx context.Context, dsn, slot, pub string, arch *Archive, guard *SlotGuard) (*Streamer, error) {
	// A replication connection cannot run ordinary queries, so the catalog
	// lookups need a second one.
	//
	// replication=database has to go in as a runtime parameter, not appended to
	// the DSN: with a URL-style DSN, string concatenation makes it part of the
	// database name.
	cfg, err := pgconn.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse dsn: %w", err)
	}
	if cfg.RuntimeParams == nil {
		cfg.RuntimeParams = map[string]string{}
	}
	cfg.RuntimeParams["replication"] = "database"
	repl, err := pgconn.ConnectConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("replication connection: %w", err)
	}
	meta, err := pgconn.Connect(ctx, dsn)
	if err != nil {
		repl.Close(ctx)
		return nil, fmt.Errorf("metadata connection: %w", err)
	}
	return &Streamer{
		repl: repl, meta: meta, slot: slot, pub: pub, arch: arch,
		rels: map[uint32]*relation{}, guard: guard,
	}, nil
}

func (s *Streamer) Close(ctx context.Context) {
	if s.repl != nil {
		s.repl.Close(ctx)
	}
	if s.meta != nil {
		s.meta.Close(ctx)
	}
}

// EnsureSlot creates the slot if it is absent. A slot is the thing that keeps
// WAL from being recycled, so creating one is a commitment: from this moment
// the database retains WAL until the companion consumes it, whether or not the
// companion is running.
func (s *Streamer) EnsureSlot(ctx context.Context) (pglogrepl.LSN, error) {
	res := s.meta.ExecParams(ctx,
		"SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name = $1",
		[][]byte{[]byte(s.slot)}, nil, nil, nil).Read()
	if res.Err != nil {
		return 0, res.Err
	}
	if len(res.Rows) > 0 && len(res.Rows[0]) > 0 && res.Rows[0][0] != nil {
		lsn, err := pglogrepl.ParseLSN(string(res.Rows[0][0]))
		if err != nil {
			return 0, err
		}
		log.Printf("slot %s exists, confirmed at %s", s.slot, lsn)
		return lsn, nil
	}

	r, err := pglogrepl.CreateReplicationSlot(ctx, s.repl, s.slot, "pgoutput",
		pglogrepl.CreateReplicationSlotOptions{Temporary: false})
	if err != nil {
		return 0, fmt.Errorf("create slot %s: %w", s.slot, err)
	}
	lsn, err := pglogrepl.ParseLSN(r.ConsistentPoint)
	if err != nil {
		return 0, err
	}
	log.Printf("created slot %s at %s", s.slot, lsn)
	log.Printf("NOTE: this slot now retains WAL. If the companion stops, run " +
		"volvra.companion_status() -- an abandoned slot fills the disk.")
	return lsn, nil
}

// pkColumns asks the database, because with REPLICA IDENTITY FULL every column
// is flagged as part of the key in the pgoutput relation message -- so the
// stream itself cannot tell us what the primary key is.
func (s *Streamer) pkColumns(ctx context.Context, oid uint32) ([]string, error) {
	res := s.meta.ExecParams(ctx, `
		SELECT a.attname
		FROM pg_index i
		CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
		JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
		WHERE i.indrelid = $1::oid AND i.indisprimary
		ORDER BY k.ord`,
		[][]byte{[]byte(fmt.Sprint(oid))}, nil, nil, nil).Read()
	if res.Err != nil {
		return nil, res.Err
	}
	var out []string
	for _, row := range res.Rows {
		out = append(out, string(row[0]))
	}
	return out, nil
}

func (s *Streamer) Run(ctx context.Context, start pglogrepl.LSN, report func(pglogrepl.LSN)) error {
	err := pglogrepl.StartReplication(ctx, s.repl, s.slot, start,
		pglogrepl.StartReplicationOptions{PluginArgs: []string{
			"proto_version '1'",
			fmt.Sprintf("publication_names '%s'", s.pub),
		}})
	if err != nil {
		return fmt.Errorf("start replication: %w", err)
	}
	log.Printf("streaming publication %s from %s", s.pub, start)

	// The LSN passed to START_REPLICATION is a request, not a guarantee:
	// Postgres is free to begin streaming from an earlier point, and after a
	// SIGKILL it does exactly that, because the slot's confirmed position lags
	// what the archive already holds durably. Everything at or below the
	// resume point is therefore already in a manifested segment and must be
	// dropped here, or the archive gains duplicate changes and its LSNs stop
	// being monotonic.
	s.skipTo = 0
	if l := s.arch.ResumeLSN(); l != "" {
		if p, err := pglogrepl.ParseLSN(l); err == nil {
			s.skipTo = p
		}
	}

	// Only ever acknowledge what is durably in the archive. Acknowledging
	// sooner would let Postgres discard WAL the archive does not have.
	acked := start
	nextStatus := time.Now()

	for {
		if ctx.Err() != nil {
			return nil
		}

		if time.Now().After(nextStatus) {
			if err := s.arch.Rotate(); err != nil {
				return fmt.Errorf("rotate: %w", err)
			}

			// Retry anything the bucket has not taken yet. Rotate uploads a
			// segment as it closes, but a bucket that was unreachable then and
			// is reachable now would otherwise never be retried until the next
			// rotation -- which, on a quiet database, may be a long time, with
			// the slot held back the whole while.
			//
			// A failure here is logged, not returned. The local archive is
			// durable; what the failure costs is that ResumeLSN does not move,
			// so the slot keeps the WAL and the lag guard below decides when
			// that has gone on too long. Stopping the companion instead would
			// turn a bucket outage into an outage of the whole durable tier.
			if err := s.arch.PushRemote(ctx); err != nil {
				log.Printf("note: %d segment(s) still to upload: %v",
					s.arch.PendingUploads(), err)
			}

			durable := acked
			if l := s.arch.ResumeLSN(); l != "" {
				if p, err := pglogrepl.ParseLSN(l); err == nil && p > durable {
					durable = p
				}
			}
			if err := pglogrepl.SendStandbyStatusUpdate(ctx, s.repl,
				pglogrepl.StandbyStatusUpdate{WALWritePosition: durable}); err != nil {
				return fmt.Errorf("standby status: %w", err)
			}
			acked = durable
			report(durable)
			if s.guard != nil {
				if err := s.guard.Check(ctx, durable); err != nil {
					return err
				}
			}
			nextStatus = time.Now().Add(5 * time.Second)
		}

		rctx, cancel := context.WithDeadline(ctx, nextStatus)
		raw, err := s.repl.ReceiveMessage(rctx)
		cancel()
		if err != nil {
			if pgconn.Timeout(err) {
				continue
			}
			return fmt.Errorf("receive: %w", err)
		}

		cd, ok := raw.(*pgproto3.CopyData)
		if !ok {
			continue
		}

		switch cd.Data[0] {
		case pglogrepl.PrimaryKeepaliveMessageByteID:
			k, err := pglogrepl.ParsePrimaryKeepaliveMessage(cd.Data[1:])
			if err != nil {
				return err
			}
			if k.ReplyRequested {
				nextStatus = time.Now()
			}
		case pglogrepl.XLogDataByteID:
			xld, err := pglogrepl.ParseXLogData(cd.Data[1:])
			if err != nil {
				return err
			}
			// Relation and Begin/Commit bookkeeping still has to be applied,
			// so the filtering happens per change, in handle.
			if err := s.handle(ctx, xld); err != nil {
				return err
			}
		}
	}
}

func (s *Streamer) handle(ctx context.Context, xld pglogrepl.XLogData) error {
	msg, err := pglogrepl.Parse(xld.WALData)
	if err != nil {
		return fmt.Errorf("parse pgoutput: %w", err)
	}
	lsn := xld.WALStart.String()

	switch m := msg.(type) {
	case *pglogrepl.RelationMessage:
		cols := make([]string, len(m.Columns))
		for i, c := range m.Columns {
			cols[i] = c.Name
		}
		pk, err := s.pkColumns(ctx, m.RelationID)
		if err != nil {
			return err
		}
		s.rels[m.RelationID] = &relation{
			name:   fmt.Sprintf("%s.%s", quoteIdent(m.Namespace), quoteIdent(m.RelationName)),
			cols:   cols,
			pkCols: pk,
		}

	case *pglogrepl.BeginMessage:
		s.xid = m.Xid
		s.commitTS = m.CommitTime

	case *pglogrepl.InsertMessage:
		rel, ok := s.rels[m.RelationID]
		if !ok {
			return fmt.Errorf("insert for unknown relation %d", m.RelationID)
		}
		newRow := tupleToMap(rel, m.Tuple, nil)
		return s.emit(lsn, rel, "I", newRow, nil, newRow)

	case *pglogrepl.UpdateMessage:
		rel, ok := s.rels[m.RelationID]
		if !ok {
			return fmt.Errorf("update for unknown relation %d", m.RelationID)
		}
		// REPLICA IDENTITY FULL is what makes OldTuple present. Without it the
		// archive would hold no before image and could not drive an undo.
		var oldRow map[string]*string
		if m.OldTuple != nil {
			oldRow = tupleToMap(rel, m.OldTuple, nil)
		}
		newRow := tupleToMap(rel, m.NewTuple, oldRow)
		return s.emit(lsn, rel, "U", newRow, oldRow, newRow)

	case *pglogrepl.DeleteMessage:
		rel, ok := s.rels[m.RelationID]
		if !ok {
			return fmt.Errorf("delete for unknown relation %d", m.RelationID)
		}
		oldRow := tupleToMap(rel, m.OldTuple, nil)
		return s.emit(lsn, rel, "D", oldRow, oldRow, nil)

	case *pglogrepl.TruncateMessage:
		// Row-level decoding cannot reconstruct a truncate, so it is recorded
		// as a gap rather than pretended away.
		for _, oid := range m.RelationIDs {
			rel, ok := s.rels[oid]
			if !ok {
				continue
			}
			if err := s.arch.Append(Change{
				LSN: lsn, XID: s.xid, CommitTS: s.commitTS,
				Table: rel.name, Op: "T",
				Gap: true, FromLSN: lsn, ToLSN: lsn,
				Reason: "TRUNCATE: rows are not recoverable from the WAL stream",
			}); err != nil {
				return err
			}
		}
	}
	return nil
}

func (s *Streamer) emit(lsn string, rel *relation, op string,
	pkSrc, oldRow, newRow map[string]*string) error {

	pk := map[string]*string{}
	for _, c := range rel.pkCols {
		if v, ok := pkSrc[c]; ok {
			pk[c] = v
		}
	}
	if len(pk) == 0 {
		if s.replayed(lsn) {
			return nil
		}
		// Without a key the change cannot be addressed later, so it is a gap,
		// not a change.
		return s.arch.Append(Change{
			LSN: lsn, XID: s.xid, CommitTS: s.commitTS, Table: rel.name,
			Gap: true, FromLSN: lsn, ToLSN: lsn,
			Reason: "no primary key: the change cannot be addressed for an undo",
		})
	}

	if s.replayed(lsn) {
		return nil
	}

	c := Change{
		LSN: lsn, XID: s.xid, CommitTS: s.commitTS,
		Table: rel.name, Op: op, PK: mustJSON(pk),
	}
	if oldRow != nil {
		c.Old = mustJSON(oldRow)
	}
	if newRow != nil {
		c.New = mustJSON(newRow)
	}
	s.changes++
	return s.arch.Append(c)
}

// tupleToMap turns a pgoutput tuple into column name -> value. pgoutput sends
// values as text; restore converts them back through the table's row type, so
// the archive stays human-readable without losing fidelity.
//
// A column marked 'u' is an unchanged TOAST value that pgoutput omits. With
// REPLICA IDENTITY FULL the old tuple has it, so it is carried across rather
// than written as null -- which would silently corrupt the archived row.
func tupleToMap(rel *relation, t *pglogrepl.TupleData, fallback map[string]*string) map[string]*string {
	out := make(map[string]*string, len(rel.cols))
	if t == nil {
		return out
	}
	for i, col := range t.Columns {
		if i >= len(rel.cols) {
			break
		}
		name := rel.cols[i]
		switch col.DataType {
		case 'n':
			out[name] = nil
		case 'u':
			if fallback != nil {
				if v, ok := fallback[name]; ok {
					out[name] = v
				}
			}
		default:
			v := string(col.Data)
			out[name] = &v
		}
	}
	return out
}

func mustJSON(v any) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}

func quoteIdent(s string) string {
	out := make([]byte, 0, len(s)+2)
	out = append(out, '"')
	for i := 0; i < len(s); i++ {
		if s[i] == '"' {
			out = append(out, '"')
		}
		out = append(out, s[i])
	}
	return string(append(out, '"'))
}

// replayed reports whether a change was already archived before the last
// restart. It is only ever true immediately after resuming, because skipTo is
// fixed at startup and the stream advances past it.
func (s *Streamer) replayed(lsn string) bool {
	if s.skipTo == 0 {
		return false
	}
	p, err := pglogrepl.ParseLSN(lsn)
	if err != nil {
		return false
	}
	if p > s.skipTo {
		return false
	}
	s.skipped++
	if s.skipped == 1 {
		log.Printf("skipping changes at or below %s: already durable in the archive",
			s.skipTo)
	}
	return true
}
