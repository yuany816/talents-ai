package main

// edge-sim：云 LB / CDN 边缘语义模拟（ALB 风格）。
// 与 mesh-sim(Envoy 语义) 的本质区别：限制是云厂商硬限制，不可配置、不可调大；
// 超限返回的错误码是 400（不是 431）——跨层错误码语义差异的来源之一。
//
// 硬限制（镜像 AWS ALB 的固定上限，恒定不变）：
//   - 单个 header 行（字段名 + ": " + 值 + CRLF）> 16384B → 400
//   - 请求行 > 16384B → 400
//   - 请求头总量（请求行 + 全部 header 行）> 65536B → 400
// 放行的请求原样转发给 mesh-sim（127.0.0.1:8082）。
//
// 容量设计含义：链路入口容量目标不得超过本层硬限制——上层（mesh/nginx/后端）
// 调得再大，20KiB 单头在本层也过不去；这要求解题者把"不可修层"计入 sizing。
import (
	"fmt"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
)

const (
	maxLineBytes  = 16384 // 单 header 行 / 请求行上限
	maxTotalBytes = 65536 // 请求头总量上限
	upstream      = "http://127.0.0.1:8082"
)

func wireBytes(r *http.Request) (int, int, int) {
	// 近似线缆口径：请求行 = METHOD SP URI SP PROTO CRLF；header 行 = NAME ": " VALUE CRLF
	requestLine := len(r.Method) + 1 + len(r.RequestURI) + 1 + len(r.Proto) + 2
	total := requestLine
	maxLine := 0
	count := 0
	for name, vals := range r.Header {
		for _, v := range vals {
			line := len(name) + 2 + len(v) + 2
			total += line
			count++
			if line > maxLine {
				maxLine = line
			}
		}
	}
	return total, maxLine, count
}

func reject(w http.ResponseWriter, why string, observed int) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusBadRequest) // 恒 400：ALB 语义，超限不返回 431
	fmt.Fprintf(w, "400 Bad Request: %s (observed=%dB; edge-sim hard limit is not configurable)\n", why, observed)
}

func main() {
	u, err := url.Parse(upstream)
	if err != nil {
		panic(err)
	}
	proxy := httputil.NewSingleHostReverseProxy(u)

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		total, maxLine, _ := wireBytes(r)
		switch {
		case maxLine > maxLineBytes:
			reject(w, "single header line exceeds 16384B", maxLine)
			return
		case r.RequestURI != "" && len(r.Method)+1+len(r.RequestURI)+1+len(r.Proto)+2 > maxLineBytes:
			reject(w, "request line exceeds 16384B", total)
			return
		case total > maxTotalBytes:
			reject(w, "total request headers exceed 65536B", total)
			return
		}
		proxy.ServeHTTP(w, r)
	})

	fmt.Println("edge-sim (ALB-sem) listening on 127.0.0.1:8080 -> " + upstream)
	if err := http.ListenAndServe("127.0.0.1:8080", nil); err != nil {
		fmt.Fprintln(os.Stderr, "edge-sim fatal:", err)
		os.Exit(1)
	}
}
