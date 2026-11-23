package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"ops/internal/jsonwire"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
)

type stat struct {
	Route  string `json:"route"`
	Events int64  `json:"events"`
	Bytes  int64  `json:"bytes"`
	Max    int64  `json:"max"`
	Over   int64  `json:"over"`
}
type state struct {
	mu     sync.Mutex
	rows   map[string]stat
	path   string
	thresh int64
}

func (s *state) encode() []byte {
	keys := make([]string, 0, len(s.rows))
	for k := range s.rows {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b bytes.Buffer
	b.WriteByte('[')
	for i, k := range keys {
		if i > 0 {
			b.WriteByte(',')
		}
		v := s.rows[k]
		fmt.Fprintf(&b, `{"route":%s,"events":%d,"bytes":%d,"max":%d,"over":%d}`, jsonwire.Quote(k), v.Events, v.Bytes, v.Max, v.Over)
	}
	b.WriteByte(']')
	return b.Bytes()
}
func (s *state) persist() error {
	dir := filepath.Dir(s.path)
	f, err := os.CreateTemp(dir, ".headeragg-*")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name)
	if _, err = f.Write(s.encode()); err != nil {
		f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	if err = os.Rename(name, s.path); err != nil {
		return err
	}
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}
func number(field, prefix string) (int64, bool) {
	if !strings.HasPrefix(field, prefix) {
		return 0, false
	}
	raw := strings.TrimPrefix(field, prefix)
	v, err := strconv.ParseInt(raw, 10, 64)
	return v, err == nil && v >= 0
}
func (s *state) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.Method == "GET" && r.URL.Path == "/health":
		io.WriteString(w, "ok")
	case r.Method == "GET" && r.URL.Path == "/stats":
		s.mu.Lock()
		data := s.encode()
		s.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.Write(data)
	case r.Method == "POST" && r.URL.Path == "/event":
		data, err := io.ReadAll(io.LimitReader(r.Body, 8<<20))
		fields := strings.Fields(string(data))
		reject := func() { w.WriteHeader(400); io.WriteString(w, "rejected") }
		if err != nil || len(fields) != 3 {
			reject()
			return
		}
		_, tsOK := number(fields[0], "ts=")
		n, nOK := number(fields[2], "bytes=")
		if !tsOK || !nOK || !strings.HasPrefix(fields[1], "route=") || len(fields[1]) == 6 {
			reject()
			return
		}
		route := strings.TrimPrefix(fields[1], "route=")
		s.mu.Lock()
		defer s.mu.Unlock()
		old, existed := s.rows[route]
		v := old
		v.Route = route
		v.Events++
		v.Bytes += n
		if n > v.Max {
			v.Max = n
		}
		if n >= s.thresh {
			v.Over++
		}
		s.rows[route] = v
		if err = s.persist(); err != nil {
			if existed {
				s.rows[route] = old
			} else {
				delete(s.rows, route)
			}
			http.Error(w, "persistence failed", 500)
			return
		}
		io.WriteString(w, "accepted")
	default:
		http.NotFound(w, r)
	}
}
func main() {
	if len(os.Args) < 3 || len(os.Args) > 4 {
		os.Exit(2)
	}
	threshold, err := strconv.ParseInt(os.Args[1], 10, 64)
	if err != nil {
		os.Exit(2)
	}
	port := "9200"
	if len(os.Args) == 4 {
		portNumber, err := strconv.Atoi(os.Args[3])
		if err != nil || portNumber < 1 || portNumber > 65535 {
			os.Exit(2)
		}
		port = os.Args[3]
	}
	s := &state{rows: map[string]stat{}, path: os.Args[2], thresh: threshold}
	if data, err := os.ReadFile(s.path); err == nil {
		var rows []stat
		if json.Unmarshal(data, &rows) == nil {
			valid := true
			for _, r := range rows {
				if r.Route == "" || r.Events < 0 || r.Bytes < 0 || r.Max < 0 || r.Over < 0 || r.Over > r.Events {
					valid = false
				}
			}
			if valid {
				for _, r := range rows {
					s.rows[r.Route] = r
				}
			}
		}
	}
	log.Fatal(http.ListenAndServe("127.0.0.1:"+port, s))
}
