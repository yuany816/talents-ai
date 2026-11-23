package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"ops/internal/jsonwire"
	"os"
	"sort"
	"strings"
)

type bucket struct {
	merged       map[string]int64
	invalidCount int64
}

func integer(raw json.RawMessage) (string, bool) {
	s := string(raw)
	if len(s) == 0 {
		return "", false
	}
	// JSON integers only: exponent, decimal, strings and booleans are invalid.
	for i, c := range s {
		if c == '-' && i == 0 {
			continue
		}
		if c < '0' || c > '9' {
			return "", false
		}
	}
	n, ok := new(big.Int).SetString(s, 10)
	if !ok || n.Sign() < 0 {
		return "", false
	}
	return n.String(), true
}
func observed(ts, route string, h map[string][]string) int64 {
	keys := make([]string, 0, len(h))
	for k := range h {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteString(`{"ts":`)
	b.WriteString(ts)
	b.WriteString(`,"route":`)
	b.WriteString(jsonwire.Quote(route))
	b.WriteString(`,"headers":{`)
	for i, k := range keys {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(jsonwire.Quote(k))
		b.WriteString(`:[`)
		for j, v := range h[k] {
			if j > 0 {
				b.WriteByte(',')
			}
			b.WriteString(jsonwire.Quote(v))
		}
		b.WriteByte(']')
	}
	b.WriteString(`}}`)
	return int64(b.Len())
}
func main() {
	if len(os.Args) != 2 {
		os.Exit(2)
	}
	thresh, ok := new(big.Int).SetString(os.Args[1], 10)
	if !ok {
		os.Exit(2)
	}
	buckets := map[string]*bucket{}
	skipped := 0
	invalid := false
	rd := bufio.NewReader(os.Stdin)
	for {
		line, err := rd.ReadString('\n')
		if len(line) > 0 {
			line = strings.TrimSpace(line)
			var obj map[string]json.RawMessage
			if line == "" || strings.HasPrefix(line, "#") || json.Unmarshal([]byte(line), &obj) != nil || obj == nil {
				skipped++
			} else {
				ts, valid := integer(obj["ts"])
				if !valid {
					invalid = true
					if buckets["<invalid>"] == nil {
						buckets["<invalid>"] = &bucket{merged: map[string]int64{}}
					}
					buckets["<invalid>"].invalidCount++
				} else {
					var route string
					var headers map[string][]string
					if json.Unmarshal(obj["route"], &route) != nil || string(obj["route"]) == "null" || json.Unmarshal(obj["headers"], &headers) != nil || headers == nil {
						skipped++
					} else {
						if buckets[route] == nil {
							buckets[route] = &bucket{merged: map[string]int64{}}
						}
						buckets[route].merged[ts] += observed(ts, route, headers)
					}
				}
			}
		}
		if err != nil {
			if err != io.EOF {
				os.Exit(1)
			}
			break
		}
	}
	routes := make([]string, 0, len(buckets))
	for r := range buckets {
		if r != "<invalid>" {
			routes = append(routes, r)
		}
	}
	sort.Strings(routes)
	if buckets["<invalid>"] != nil {
		routes = append(routes, "<invalid>")
	}
	out := bufio.NewWriter(os.Stdout)
	for _, r := range routes {
		b := buckets[r]
		events := int64(len(b.merged)) + b.invalidCount
		var total, mx, over int64
		for _, v := range b.merged {
			total += v
			if v > mx {
				mx = v
			}
			if big.NewInt(v).Cmp(thresh) >= 0 {
				over++
			}
		}
		if thresh.Sign() <= 0 {
			over += b.invalidCount
		}
		verdict := "OK"
		if over > 0 {
			verdict = "OVER"
		}
		fmt.Fprintf(out, "%s events=%d bytes=%d over=%d max_observed=%d verdict=%s\n", r, events, total, over, mx, verdict)
	}
	flag := 0
	if invalid {
		flag = 1
	}
	fmt.Fprintf(out, "skipped=%d invalid=%d\n", skipped, flag)
	out.Flush()
}
