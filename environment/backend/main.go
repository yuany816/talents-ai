package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// loadQuotaConfig 读取配额配置；文件缺失则拒绝启动（避免静默回退到错误限额）
func loadQuotaConfig(path string) int {
	f, err := os.Open(path)
	if err != nil {
		log.Fatalf("无法读取配额配置 %s: %v", path, err)
	}
	defer f.Close()
	limit := 0
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "max_header_bytes") {
			v := strings.Trim(strings.TrimPrefix(line, "max_header_bytes"), " :=")
			if n, err := strconv.Atoi(strings.TrimSpace(v)); err == nil {
				limit = n
			}
		}
	}
	if limit <= 0 {
		log.Fatalf("配额配置 %s 中 max_header_bytes 无效", path)
	}
	return limit
}

// headerQuotaMiddleware 业务层请求头配额：总量超限返回 431（与平台语义一致），
// 并在响应体中给出限额与实测值，便于定位是"谁配小了"。
func headerQuotaMiddleware(limit int, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		total := len(r.RequestURI) + 16
		for name, vals := range r.Header {
			total += len(name) + 4
			for _, v := range vals {
				total += len(v)
			}
		}
		if total > limit {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusRequestHeaderFieldsTooLarge)
			_ = json.NewEncoder(w).Encode(map[string]interface{}{
				"code":     431,
				"msg":      "request header quota exceeded",
				"limit":    limit,
				"observed": total,
			})
			return
		}
		next.ServeHTTP(w, r)
	})
}

func main() {
	quotaLimit := loadQuotaConfig("config.yaml")

	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/profile", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, `{"code":0,"msg":"ok"}`)
	})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	})

	// 备注：历史上曾有 431 反馈被初步归因到入口层；任何限额调整后需全链路复测确认。
	srv := &http.Server{
		Addr:           "127.0.0.1:9000",
		Handler:        headerQuotaMiddleware(quotaLimit, mux),
		MaxHeaderBytes: 1 << 20, // 标准库默认值（健康）
		ReadTimeout:    10 * time.Second,
		WriteTimeout:   10 * time.Second,
	}
	log.Println("backend listening on 127.0.0.1:9000")
	log.Fatal(srv.ListenAndServe())
}
