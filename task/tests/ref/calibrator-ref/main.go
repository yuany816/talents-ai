package main

// calibrator-ref —— F7 参考实现（判分对照基准）
// 规格见 /app/tools/specs/spec-calibrator.md（判分环境以 tests/bin/calibrator-ref 执行）
// 语义钉子（规格已披露）：
//   - observed = 规范化再序列化的 UTF-8 字节长；HTML 字符（< > &）不转义；
//   - headers 键按字节序升序重排、紧凑序列化；
//   - 同 route+ts 合并：observed 取总和、events 计 1；
//   - ts/route 缺失或 ts=null → skipped；其余非十进制整数/负数/溢出 → <invalid> 桶；
//   - 输出按 route 字节序升序、桶内按 ts 升序；<invalid> 固定最后。
import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
)

type rawEvent struct {
	TS      *json.Number          `json:"ts"`
	Route   *string               `json:"route"`
	Headers *map[string][]*string `json:"headers"`
}

type group struct {
	ts    int64
	bytes int64
}

func canonical(ts int64, route string, headers map[string][]*string) []byte {
	buf := &bytes.Buffer{}
	enc := json.NewEncoder(buf)
	enc.SetEscapeHTML(false)
	if headers == nil {
		headers = map[string][]*string{}
	}
	payload := map[string]interface{}{"ts": ts, "route": route, "headers": headers}
	_ = enc.Encode(payload)
	b := buf.Bytes()
	return bytes.TrimRight(b, "\n")
}

func main() {
	thresh, _ := strconv.ParseInt(os.Args[1], 10, 64)
	skip := 0
	invCount := int64(0)
	buckets := map[string]map[int64]*group{}
	hasInv := false
	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 1024*1024), 16*1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			skip++ // 空行/注释/垃圾行一律计入 skipped
			continue
		}
		var ev rawEvent
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			skip++
			continue
		}
		if ev.TS == nil || ev.Route == nil {
			skip++
			continue
		}
		ts, perr := strconv.ParseInt(string(*ev.TS), 10, 64)
		if perr != nil || ts < 0 {
			invCount++
			hasInv = true
			continue
		}
		route := *ev.Route
		var hdrs map[string][]*string
		if ev.Headers != nil {
			hdrs = *ev.Headers
		}
		obs := int64(len(canonical(ts, route, hdrs)))
		if buckets[route] == nil {
			buckets[route] = map[int64]*group{}
		}
		g := buckets[route][ts]
		if g == nil {
			g = &group{ts: ts}
			buckets[route][ts] = g
		}
		g.bytes += obs
	}
	routes := []string{}
	for r := range buckets {
		routes = append(routes, r)
	}
	sort.Slice(routes, func(i, j int) bool { return routes[i] < routes[j] })
	out := ""
	for _, r := range routes {
		if hasInv && r == "<invalid>" {
			continue
		}
		tss := []int64{}
		for t := range buckets[r] {
			tss = append(tss, t)
		}
		sort.Slice(tss, func(i, j int) bool { return tss[i] < tss[j] })
		n := int64(0)
		b := int64(0)
		mx := int64(0)
		over := int64(0)
		for _, t := range tss {
			g := buckets[r][t]
			n++
			b += g.bytes
			if g.bytes > mx {
				mx = g.bytes
			}
			if g.bytes >= thresh {
				over++
			}
		}
		verdict := "OK"
		if over > 0 {
			verdict = "OVER"
		}
		out += fmt.Sprintf("%s events=%d bytes=%d over=%d max_observed=%d verdict=%s\n", r, n, b, over, mx, verdict)
	}
	if hasInv {
		out += fmt.Sprintf("<invalid> events=%d bytes=0 over=0 max_observed=0 verdict=OK\n", invCount)
	}
	invFlag := 0
	if hasInv {
		invFlag = 1
	}
	out += fmt.Sprintf("skipped=%d invalid=%d\n", skip, invFlag)
	fmt.Print(out)
}
