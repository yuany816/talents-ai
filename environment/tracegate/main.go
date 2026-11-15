// tracegate —— NG 接入网关的 trace 插件（独立进程形态，nginx 反代至本进程）。
//
// 职责（链路第 2 层）：
//   1) header 预算检查：请求头总量超过 max_header_bytes 时返回 431（响应体携带
//      component 字段便于逐层定位）；
//   2) trace 注入：X-Trace-Context 不存在则创建（root 段），存在则在其后追加一段
//      恰为 span_bytes 字符的 gate span —— 全链路追踪的上下文随跳数增长；
//   3) 反向代理到下游（mesh 数据面 sidecar）。
//
// 健康探针路径 /componentz 由本进程本地应答（不代理），用于组件级存活检查；
// 其余路径（含 /healthz、/api/v1/profile）一律走中间件链后代理下游。
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

type gateConfig struct {
	Listen         string
	Upstream       string
	MaxHeaderBytes int
	SpanBytes      int
}

// loadConfig 读取 key: value 形式的配置；文件缺失或字段无效则拒绝启动（避免静默回退）
func loadConfig(path string) gateConfig {
	f, err := os.Open(path)
	if err != nil {
		log.Fatalf("无法读取配置 %s: %v", path, err)
	}
	defer f.Close()
	cfg := gateConfig{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		i := strings.Index(line, ":")
		if i < 0 {
			continue
		}
		k := strings.TrimSpace(line[:i])
		v := strings.TrimSpace(line[i+1:])
		switch k {
		case "listen":
			cfg.Listen = v
		case "upstream":
			cfg.Upstream = v
		case "max_header_bytes":
			cfg.MaxHeaderBytes, _ = strconv.Atoi(v)
		case "span_bytes":
			cfg.SpanBytes, _ = strconv.Atoi(v)
		}
	}
	if cfg.Listen == "" || cfg.Upstream == "" || cfg.MaxHeaderBytes <= 0 || cfg.SpanBytes <= 0 {
		log.Fatalf("配置 %s 字段无效: %+v", path, cfg)
	}
	return cfg
}

// headerQuota 计算请求头总量（与后端配额同口径：请求行 + 各 header 名/值/开销）
func headerQuota(r *http.Request) int {
	total := len(r.RequestURI) + 16
	for name, vals := range r.Header {
		total += len(name) + 4
		for _, v := range vals {
			total += len(v)
		}
	}
	return total
}

// hexFiller 生成确定性的定长 hex 填充串（span 段尺寸必须固定，容量评估依赖该前提）
func hexFiller(n int) string {
	if n <= 0 {
		return ""
	}
	s := strings.Repeat("0123456789abcdef", n/16+1)
	return s[:n]
}

func newSpanID() string {
	return fmt.Sprintf("%x", time.Now().UnixNano())
}

// appendSpan 在 X-Trace-Context 后追加一段恰为 size 字符的 span 段（"hop=id-filler"）
func appendSpan(existing, hop string, size int) string {
	id := fmt.Sprintf("%s=%s-%s", hop, hop[:1]+"1", newSpanID())
	seg := id
	if need := size - len(seg) - 1; need > 0 { // 1 字节给 '-' 分隔
		seg = seg + "-" + hexFiller(need)
	}
	if existing == "" {
		return seg
	}
	return existing + ";" + seg
}

// reject431 输出带 component 定位字段的 431 响应
func reject431(w http.ResponseWriter, component string, limit, observed int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusRequestHeaderFieldsTooLarge)
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"code":      431,
		"msg":       component + " header budget exceeded",
		"component": component,
		"limit":     limit,
		"observed":  observed,
	})
}

func main() {
	cfg := loadConfig("tracegate.yaml")

	up, err := url.Parse(cfg.Upstream)
	if err != nil {
		log.Fatalf("upstream 无效: %v", err)
	}
	proxy := httputil.NewSingleHostReverseProxy(up)
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, e error) {
		log.Printf("GATEERR upstream error: %v", e)
		w.WriteHeader(http.StatusBadGateway)
		_, _ = w.Write([]byte(`{"code":502,"component":"tracegate"}`))
	}

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 组件级健康探针：本地应答，不依赖下游
		if r.URL.Path == "/componentz" {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"component":"tracegate","status":"ok"}`))
			return
		}

		// 1) header 预算检查（在 trace 注入之前：被拒请求不携带 span）
		quota := headerQuota(r)
		if quota > cfg.MaxHeaderBytes {
			log.Printf("GATESTAT path=%s total=%dB budget=%dB verdict=REJECT", r.URL.Path, quota, cfg.MaxHeaderBytes)
			reject431(w, "tracegate", cfg.MaxHeaderBytes, quota)
			return
		}

		// 2) trace 注入：X-Trace-Context 不存在则创建 root 段，存在则追加 gate span
		tc := r.Header.Get("X-Trace-Context")
		if tc == "" {
			tc = "root=" + newSpanID()
		}
		grown := appendSpan(tc, "gate", cfg.SpanBytes)
		r.Header.Set("X-Trace-Context", grown)

		log.Printf("GATESTAT path=%s total=%dB budget=%dB trace_in=%dB trace_out=%dB verdict=PASS", r.URL.Path, quota, cfg.MaxHeaderBytes, len(tc), len(grown))

		// 3) 代理下游（mesh 数据面 sidecar）
		proxy.ServeHTTP(w, r)
	})

	srv := &http.Server{
		Addr:         cfg.Listen,
		Handler:      handler,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
	}
	log.Printf("tracegate listening on %s (budget=%dB span=%dB upstream=%s)", cfg.Listen, cfg.MaxHeaderBytes, cfg.SpanBytes, cfg.Upstream)
	log.Fatal(srv.ListenAndServe())
}
