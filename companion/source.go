package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
)

// Where verify and restore read the archive from.
//
// An archive exists in up to two places, and the interesting case is when it
// exists in only the remote one: the host died, which is the situation the
// durable tier is for. So reads go to local disk when it has the file and to
// object storage otherwise, and neither caller has to know which happened.
//
// Local is preferred when both are present because it is free, and because the
// local copy is the one the companion fsynced. If the two ever disagree, the
// hash check in VerifyArchive is what notices, not this.
type Source struct {
	Dir    string  // "" when there is no local copy
	Remote *Remote // nil when no bucket was configured
}

func (s Source) describe() string {
	switch {
	case s.Dir != "" && s.Remote != nil:
		return fmt.Sprintf("%s, with %s", s.Dir, s.Remote.URI())
	case s.Remote != nil:
		return s.Remote.URI()
	default:
		return s.Dir
	}
}

// Local reports whether a member is on local disk, which is what lets verify
// distinguish "this segment is remote only" from "this segment is missing".
func (s Source) Local(name string) bool {
	if s.Dir == "" {
		return false
	}
	_, err := os.Stat(filepath.Join(s.Dir, name))
	return err == nil
}

func (s Source) Open(ctx context.Context, name string) (io.ReadCloser, error) {
	if s.Dir != "" {
		f, err := os.Open(filepath.Join(s.Dir, name))
		if err == nil {
			return f, nil
		}
		if s.Remote == nil {
			return nil, err
		}
	}
	if s.Remote == nil {
		return nil, fmt.Errorf("%s: no local directory and no bucket configured", name)
	}
	return s.Remote.Get(ctx, name)
}

// ReadManifestFrom is ReadManifest over a Source, so an archive can be read
// with no local copy at all.
func ReadManifestFrom(ctx context.Context, s Source) (*Manifest, error) {
	rc, err := s.Open(ctx, "manifest.json")
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	b, err := io.ReadAll(rc)
	if err != nil {
		return nil, err
	}
	var m Manifest
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, err
	}
	sort.Slice(m.Segments, func(i, j int) bool { return m.Segments[i].Seq < m.Segments[j].Seq })
	return &m, nil
}
