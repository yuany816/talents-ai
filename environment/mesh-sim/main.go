package main

// mesh-sim：服务网格 ingress/sidecar 语义模拟（Envoy 风格）。
// 复刻 Envoy 与 nginx 有本质区别的三个请求头语义：
//   1) headers 总量上限（Envoy 同名字段 max_request_headers_kb，此处默认 60KiB）→
//      超限在 HTTP/1.1 返回 431（Envoy 语义，与 ALB 的 400 不同）
//   2) header 个数上限（Envoy 同名字段 max_headers_count，此处默认 100）→ 超限同样 431；
//      这是一个与"字节数"完全独立的维度——总字节数很小的多 header 请求也会被拒
//   3) 每请求注入 span 上下文（真实网格的 trace 传播，不可关闭）→ 下游（nginx/后端）
//      看到的 header 预算比客户端原始请求多 ~8KiB："header 预算在链路中非单调"。
//      容量评估若只按客户端原始体量 sizing，后端会在注入后被击穿。
//
// 配置：/etc/mesh-sim/config.yaml（字段名与 Envoy 一致；修改后须 supervisorctl restart
// mesh-sim 生效）。每次决策写一行到 stdout（supervisor 收集到 /var/log/mesh-sim.log），
// 供排查观测本层实际生效的限额与判定依据。
import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strconv"
	"strings"
)

const (
	upstream        = "http://127.0.0.1:80"
	spanHeader      = "X-Mesh-Span"
	spanInjectBytes = 8179 // 值体量；整行 = 11 + 2 + 8179 + 2 = 8194B ≈ 8KiB
	defaultTotalKB  = 60   // Envoy: max_request_headers_kb 默认 60
	defaultCount    = 100  // Envoy: max_headers_count 默认 100
)

type meshCfg struct {
	TotalKB int
	Count   int
}

func loadConfig(path string) meshCfg {
	c := meshCfg{TotalKB: defaultTotalKB, Count: defaultCount}
	b, err := os.ReadFile(path)
	if err != nil {
		return c
	}
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if v, ok := grab(line, "max_request_headers_kb"); ok && v > 0 {
			c.TotalKB = v
		}
		if v, ok := grab(line, "max_headers_count"); ok && v > 0 {
			c.Count = v
		}
	}
	return c
}

func grab(line, key string) (int, bool) {
	i := strings.Index(line, key)
	if i < 0 {
		return 0, false
	}
	rest := strings.TrimLeft(line[i+len(key):], " :=")
	rest = strings.Fields(rest)[0]
	n, err := strconv.Atoi(strings.TrimSuffix(rest, "k"))
	if err != nil {
		return 0, false
	}
	return n, true
}

func main() {
	cfgPath := os.Getenv("MESH_SIM_CONFIG")
	if cfgPath == "" {
		cfgPath = "/etc/mesh-sim/config.yaml"
	}
	cfg := loadConfig(cfgPath)

	u, err := url.Parse(upstream)
	if err != nil {
		panic(err)
	}
	proxy := httputil.NewSingleHostReverseProxy(u)

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// Envoy 口径：headers 总量 = Σ(name + ": " + value + CRLF)，不含请求行（与 nginx
		// 的 $request_length 口径差异本身就是排查点）
		total := 0
		count := 0
		for name, vals := range r.Header {
			for _, v := range vals {
				total += len(name) + 2 + len(v) + 2
				count++
			}
		}
		decision := "forward"
		limitHit := ""
		switch {
		case total > cfg.TotalKB*1024:
			decision, limitHit = "431", "max_request_headers_kb"
		case count > cfg.Count:
			decision, limitHit = "431", "max_headers_count"
		}
		fmt.Printf("MESHDECISION path=%s total=%dB count=%d limit_total=%dKB limit_count=%d decision=%s(%s)\n",
			r.URL.Path, total, count, cfg.TotalKB, cfg.Count, decision, limitHit)

		if decision == "431" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusRequestHeaderFieldsTooLarge) // Envoy HTTP/1.1 语义：431 而非 400
			_ = json.NewEncoder(w).Encode(map[string]interface{}{
				"code":     431,
				"msg":      "request headers rejected by mesh limit",
				"limit":    map[string]int{"max_request_headers_kb": cfg.TotalKB, "max_headers_count": cfg.Count},
				"observed": map[string]int{"total_bytes": total, "header_count": count},
				"hit":      limitHit,
			})
			return
		}
		// 注入 span 上下文（真实网格行为，不可配置、不可关闭）
		r.Header.Set(spanHeader, strings.Repeat("m", spanInjectBytes))
		proxy.ServeHTTP(w, r)
	})

	fmt.Printf("mesh-sim (Envoy-sem) listening on 127.0.0.1:8082 -> %s (max_request_headers_kb=%d, max_headers_count=%d)\n",
		upstream, cfg.TotalKB, cfg.Count)
	if err := http.ListenAndServe("127.0.0.1:8082", nil); err != nil {
		fmt.Fprintln(os.Stderr, "mesh-sim fatal:", err)
		os.Exit(1)
	}
}
