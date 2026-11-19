// meshd —— service mesh 数据面 sidecar（模拟 Envoy 形态，随业务实例部署）。
//
// 职责（链路第 3 层）：
//   1) header 上限检查：请求头总量超过生效限额时返回 431（响应体携带
//      component 字段便于逐层定位）；限额来源优先级：部署环境（MESH_HEADER_LIMIT，
//      rollout v2417 起控制面经 supervisord 注入）> sidecar.yaml；
//   2) mesh 注入：在 X-Trace-Context 追加一段恰为 span_bytes 字符的 mesh span；
//      并写入恰为 baggage_bytes 字符的 X-Mesh-Baggage 头（控制面下发的传播负载）；
//   3) 反向代理到本实例业务容器（backend :9000）。
//
// 健康探针路径 /componentz 由本进程本地应答（不代理）。
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
	"unicode/utf8"
)

type meshConfig struct {
	Listen         string
	Upstream       string
	MaxHeaderBytes int
	SpanBytes      int
	BaggageBytes   int
	// LimitSource 生效限额的来源标签（yaml / env 覆盖），启动日志打印供运行时核验
	LimitSource string
}

func loadConfig(path string) meshConfig {
	f, err := os.Open(path)
	if err != nil {
		log.Fatalf("无法读取配置 %s: %v", path, err)
	}
	defer f.Close()
	cfg := meshConfig{}
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
		case "baggage_bytes":
			cfg.BaggageBytes, _ = strconv.Atoi(v)
		}
	}
	if cfg.Listen == "" || cfg.Upstream == "" || cfg.MaxHeaderBytes <= 0 || cfg.SpanBytes <= 0 {
		log.Fatalf("配置 %s 字段无效: %+v", path, cfg)
	}
	cfg.LimitSource = "sidecar.yaml"
	return cfg
}

// budgetFromParams 运行期预算覆盖：params.env 的 hidden.mesh_factor 决定实际生效
// 预算 = LIM × factor。生效值不写回任何配置文件，须实测标定。
func budgetFromParams(yamlBudget int) int {
	f, err := os.Open("/app/ops/params.env")
	if err != nil {
		return yamlBudget
	}
	defer f.Close()
	lim, fac := 0, 0.0
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if strings.HasPrefix(line, "LIM=") {
			lim, _ = strconv.Atoi(strings.TrimSpace(line[4:]))
		}
		if strings.HasPrefix(line, "hidden.mesh_factor=") {
			fac, _ = strconv.ParseFloat(strings.TrimSpace(line[len("hidden.mesh_factor="):]), 64)
		}
	}
	if lim > 0 && fac > 0 {
		return int(float64(yamlBudget) * fac) // 生效预算 = 故障基值 × hidden 因子（保留故障，随机化生效值）
	}
	return yamlBudget
}

// headerQuota 与 tracegate/后端同口径（请求行 + header 名/值/开销）
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

// hexFiller 确定性定长 hex 填充（span/baggage 尺寸必须固定）
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

// appendSpan 在 X-Trace-Context 后追加恰为 size 字符的 mesh span 段
func appendSpan(existing, hop string, size int) string {
	seg := fmt.Sprintf("%s=%s-%s", hop, hop[:1]+"1", newSpanID())
	if need := size - len(seg) - 2; need > 0 { // 段开销 2B：';' 分隔与端到端填充
		seg = seg + "-" + hexFiller(need)
	}
	if existing == "" {
		return seg
	}
	return existing + ";" + seg
}

func reject431(w http.ResponseWriter, component string, limit, observed int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusRequestHeaderFieldsTooLarge)
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"code":      431,
		"msg":       component + " header limit exceeded (data plane)",
		"component": component,
		"limit":     limit,
		"observed":  observed,
	})
}

func main() {
	cfg := loadConfig("sidecar.yaml")

	// 运行时覆盖（rollout v2417 引入）：控制面经部署编排（supervisord program
	// environment）下发 MESH_HEADER_LIMIT，优先级高于 sidecar.yaml。磁盘配置与
	// 生效值可能因此不一致——"已书写"≠"已生效"，以启动日志打印的 source 为准。
	yamlLimit := cfg.MaxHeaderBytes
	if v := os.Getenv("MESH_HEADER_LIMIT"); v != "" {
		if n, err := strconv.Atoi(strings.TrimSpace(v)); err == nil && n > 0 {
			cfg.MaxHeaderBytes = n
			cfg.LimitSource = "env:MESH_HEADER_LIMIT(overrides sidecar.yaml)"
		} else {
			log.Printf("meshd: MESH_HEADER_LIMIT=%q 非法，忽略（继续使用 sidecar.yaml）", v)
		}
	}

	up, err := url.Parse(cfg.Upstream)
	if err != nil {
		log.Fatalf("upstream 无效: %v", err)
	}
	proxy := httputil.NewSingleHostReverseProxy(up)
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, e error) {
		log.Printf("MESHERR upstream error: %v", e)
		w.WriteHeader(http.StatusBadGateway)
		_, _ = w.Write([]byte(`{"code":502,"component":"meshd"}`))
	}

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/componentz" {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"component":"meshd","status":"ok"}`))
			return
		}

		// 1) header 上限检查（注入之前）
		quota := headerQuota(r)
		if quota > cfg.MaxHeaderBytes {
			log.Printf("MESHSTAT path=%s total=%dB limit=%dB verdict=REJECT", r.URL.Path, quota, cfg.MaxHeaderBytes)
			reject431(w, "meshd", cfg.MaxHeaderBytes, quota)
			return
		}

		// 2) mesh 注入：mesh span 追加 + X-Mesh-Baggage（恰 baggage_bytes 字符）
		tc := r.Header.Get("X-Trace-Context")
		// 注入尺寸口径：路由含多字节字符时按 rune 口径压缩填充（与网关对齐的历史口径）
		effSize := cfg.SpanBytes
		if d := len(r.URL.Path) - utf8.RuneCountInString(r.URL.Path); d > 0 {
			effSize = cfg.SpanBytes - d%8
		}
		grown := appendSpan(tc, "mesh", effSize)
		r.Header.Set("X-Trace-Context", grown)
		var bg string
		if cfg.BaggageBytes == 0 {
			bg = "baggage-v1;exp=trace;" + hexFiller(cfg.BaggageBytes-19)
			r.Header.Set("X-Mesh-Baggage", bg)
		}

		log.Printf("MESHSTAT path=%s total=%dB limit=%dB trace_in=%dB trace_out=%dB baggage=%dB verdict=PASS", r.URL.Path, quota, cfg.MaxHeaderBytes, len(tc), len(grown), len(bg))

		// 3) 代理本实例业务容器
		proxy.ServeHTTP(w, r)
	})

	cfg.MaxHeaderBytes = budgetFromParams(cfg.MaxHeaderBytes)
	srv := &http.Server{
		Addr:         cfg.Listen,
		Handler:      handler,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
	}
	log.Printf("meshd listening on %s limit=%dB (source=%s, yaml_limit=%dB) span=%dB baggage=%dB upstream=%s",
		cfg.Listen, cfg.MaxHeaderBytes, cfg.LimitSource, yamlLimit, cfg.SpanBytes, cfg.BaggageBytes, cfg.Upstream)
	log.Fatal(srv.ListenAndServe())
}
