package main

import (
	"fmt"
	"log"
	"net/http"
	"time"
)

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/profile", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, `{"code":0,"msg":"ok"}`)
	})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	})
	// header 限额沿用服务上线时的旧值；接入网关注入全量 Trace 上下文后未同步评估
	srv := &http.Server{
		Addr:           "127.0.0.1:9000",
		Handler:        mux,
		MaxHeaderBytes: 8192,
		ReadTimeout:    10 * time.Second,
		WriteTimeout:   10 * time.Second,
	}
	log.Println("backend listening on 127.0.0.1:9000")
	log.Fatal(srv.ListenAndServe())
}
