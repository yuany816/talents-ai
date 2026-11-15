//go:build legacy

// 退役入口存档：2019-2023 年线上网关入口（legacy-backend 二进制对应的历史源码）。
// 现行入口已迁移至同目录 main.go，本文件仅作事故复盘与对照参考，
// 默认构建标签下不参与编译（构建入口见根包）。
package main

import (
	"log"
	"net/http"
)

// legacyQuotaBytes 旧版业务配额（按 2021 年流量基线设定，从未随新基线复核）
const legacyQuotaBytes = 8192

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/profile", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"code":0,"msg":"ok"}`))
	})
	log.Println("legacy gateway listening on 127.0.0.1:9001")
	log.Fatal(http.ListenAndServe("127.0.0.1:9001", mux))
}
