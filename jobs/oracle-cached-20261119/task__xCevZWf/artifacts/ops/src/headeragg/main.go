package main

// headeragg-ref —— F6 参考实现（判分差分基准）
// 规格见 /app/tools/specs/spec-headeragg.md
// 运行：headeragg <THRESH> <STATE_FILE> [PORT]，默认监听 127.0.0.1:9200
// 语义钉子：并发精确计数（互斥）、行级持久化+重启精确恢复（Max/Over 保留）、
// 多字节字节序、over≥边界、畸形事件拒绝、/a 与 /a/ 独立、状态损坏视为空、原子写
import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
)

type event struct {
	route string
	b     int64
}

type outRow struct {
	Route  string `json:"route"`
	Events int64  `json:"events"`
	Bytes  int64  `json:"bytes"`
	Max    int64  `json:"max"`
	Over   int64  `json:"over"`
}

type state struct {
	mu       sync.Mutex
	events   []event
	restored map[string]*outRow // 重启恢复的聚合行（Max/Over 精确保留）
	thresh   int64
	sf       string
	rejects  int64
}

// merge：恢复行 + 新事件 → 输出行
func (s *state) statsRows() []outRow {
	agg := map[string]*outRow{}
	for k, r := range s.restored {
		agg[k] = &outRow{Route: r.Route, Events: r.Events, Bytes: r.Bytes, Max: r.Max, Over: r.Over}
	}
	for _, e := range s.events {
		r := agg[e.route]
		if r == nil {
			r = &outRow{Route: e.route}
			agg[e.route] = r
		}
		r.Events++
		r.Bytes += e.b
		if e.b > r.Max {
			r.Max = e.b
		}
		if e.b >= s.thresh {
			r.Over++
		}
	}
	rows := []outRow{}
	for _, r := range agg {
		rows = append(rows, *r)
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].Route < rows[j].Route })
	return rows
}

func (s *state) persist() {
	rows := s.statsRows()
	data, _ := json.Marshal(rows)
	tmp := s.sf + ".tmp"
	if err := os.WriteFile(tmp, data, 0644); err == nil {
		os.Rename(tmp, s.sf)
	}
}

func (s *state) load() {
	data, err := os.ReadFile(s.sf)
	if err != nil {
		return
	}
	var rows []outRow
	if json.Unmarshal(data, &rows) != nil {
		return // 损坏：视为空状态（规格钉子 7）
	}
	for _, r := range rows {
		s.restored[r.Route] = &outRow{Route: r.Route, Events: r.Events, Bytes: r.Bytes, Max: r.Max, Over: r.Over}
	}
}

func (s *state) handle(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/health" && r.Method == http.MethodGet:
		fmt.Fprint(w, "ok")
	case r.URL.Path == "/event" && r.Method == http.MethodPost:
		body := make([]byte, 8192)
		n, _ := r.Body.Read(body)
		fields := strings.Fields(string(body[:n]))
		if len(fields) != 3 || !strings.HasPrefix(fields[0], "ts=") ||
			!strings.HasPrefix(fields[1], "route=") || !strings.HasPrefix(fields[2], "bytes=") {
			s.mu.Lock()
			s.rejects++
			s.mu.Unlock()
			http.Error(w, "rejected", http.StatusBadRequest)
			return
		}
		route := strings.TrimPrefix(fields[1], "route=")
		ts, err1 := strconv.ParseInt(strings.TrimPrefix(fields[0], "ts="), 10, 64)
		b, err2 := strconv.ParseInt(strings.TrimPrefix(fields[2], "bytes="), 10, 64)
		if err1 != nil || err2 != nil || ts < 0 || b < 0 || route == "" {
			s.mu.Lock()
			s.rejects++
			s.mu.Unlock()
			http.Error(w, "rejected", http.StatusBadRequest)
			return
		}
		s.mu.Lock()
		s.events = append(s.events, event{route: route, b: b})
		s.persist()
		s.mu.Unlock()
		fmt.Fprint(w, "accepted")
	case r.URL.Path == "/stats" && r.Method == http.MethodGet:
		s.mu.Lock()
		rows := s.statsRows()
		s.mu.Unlock()
		data, _ := json.Marshal(rows)
		w.Header().Set("Content-Type", "application/json")
		w.Write(data)
	default:
		http.NotFound(w, r)
	}
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: headeragg <THRESH> <STATE_FILE> [PORT]")
		os.Exit(2)
	}
	thresh, _ := strconv.ParseInt(os.Args[1], 10, 64)
	sf := os.Args[2]
	port := "9200"
	if len(os.Args) > 3 {
		port = os.Args[3]
	}
	st := &state{thresh: thresh, sf: sf, restored: map[string]*outRow{}}
	st.load()
	http.HandleFunc("/", st.handle)
	if err := http.ListenAndServe("127.0.0.1:"+port, nil); err != nil {
		os.Exit(1)
	}
}
