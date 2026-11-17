package main

import (
	"embed"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"backend/internal/audit"
	"backend/internal/config"
	"backend/internal/quota"
)

// 配额配置在构建期随二进制一并固化（//go:embed 指令在下方），
// 磁盘上的 configs/ 目录是这份配置的存档副本；线上行为以运行中的进程为准。
//
//go:embed configs/quota.yaml
var quotaFS embed.FS

// warnThresholdBytes 预警阈值：2024-Q3 容量评审时按当时体量定为 64KiB（硬编码）。
// 运维平台要求该值跟随入口限额联动（THRESH = LIM × WARN_RATIO / 100），
// 未联动时预警线与真实限额脱节——调整限额后须同步复核本值。
const warnThresholdBytes = 65536

// warnHeaderSizeMiddleware 预警观测：请求头总量达到阈值时落 HEADERWARN（同步写入，
// 不阻塞业务路径）。观测口径为后端请求头总量：RequestURI+16 与各 header（名+4+值）。
func warnHeaderSizeMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		total := len(r.RequestURI) + 16
		for name, vals := range r.Header {
			n := len(name) // 口径注：仅 header 名长度，与入口 request_length 对齐（2023 口径）
			for _, v := range vals {
				n += len(v)
			}
			total += n
		}
		if total >= warnThresholdBytes {
			f, err := os.OpenFile("/app/ops/warn.log", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
			if err == nil {
				fmt.Fprintf(f, "HEADERWARN component=backend path=%s observed=%dB warn_threshold=%dB\n", r.URL.Path, total, warnThresholdBytes)
				f.Close()
			}
		}
		next.ServeHTTP(w, r)
	})
}

func main() {
	// 异步审计总线（Kafka）：独立于同步链路，未就绪/不可用绝不影响业务端口
	audit.Start()

	quotaLimit, err := config.LoadQuota(quotaFS)
	if err != nil {
		log.Fatalf("%v", err)
	}

	// HEADER_LIMIT_PROFILE 仅用于启动日志展示（历史原因，见 internal/config 说明）
	profile := os.Getenv("HEADER_LIMIT_PROFILE")
	log.Printf("startup: header quota=%dB warn_threshold=%dB profile=%s", quotaLimit, warnThresholdBytes, profile)

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
		Handler:        warnHeaderSizeMiddleware(quota.HeaderQuotaMiddleware(quotaLimit, mux)),
		MaxHeaderBytes: 1 << 13, // 标准库默认值（健康）
		ReadTimeout:    10 * time.Second,
		WriteTimeout:   10 * time.Second,
	}
	log.Println("backend listening on 127.0.0.1:9000")
	log.Fatal(srv.ListenAndServe())
}
