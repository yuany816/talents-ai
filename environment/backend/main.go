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

func main() {
	// 异步审计总线（Kafka）：独立于同步链路，未就绪/不可用绝不影响业务端口
	audit.Start()

	quotaLimit, err := config.LoadQuota(quotaFS)
	if err != nil {
		log.Fatalf("%v", err)
	}

	// HEADER_LIMIT_PROFILE 仅用于启动日志展示（历史原因，见 internal/config 说明）
	profile := os.Getenv("HEADER_LIMIT_PROFILE")
	log.Printf("startup: header quota=%dB profile=%s", quotaLimit, profile)

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
		Handler:        quota.HeaderQuotaMiddleware(quotaLimit, mux),
		MaxHeaderBytes: 1 << 13, // 标准库默认值（健康）
		ReadTimeout:    10 * time.Second,
		WriteTimeout:   10 * time.Second,
	}
	log.Println("backend listening on 127.0.0.1:9000")
	log.Fatal(srv.ListenAndServe())
}
