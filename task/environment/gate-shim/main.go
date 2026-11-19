package main

// gate-shim：/via-gate 的 auth_request 预检后端（基础设施，非解题目标）。
// 每次请求执行一次 bash /app/ops/quality_gate.sh --check：
//   exit 0 → 200（放行）；非 0 → 403（拦截）；脚本缺失/无法执行 → 403（fail-closed）；
//   执行超时 → 500（nginx error_page 归一为 503，同样 fail-closed）。
import (
	"fmt"
	"net/http"
	"os/exec"
	"time"
)

func main() {
	http.HandleFunc("/gate", func(w http.ResponseWriter, r *http.Request) {
		cmd := exec.Command("bash", "/app/ops/quality_gate.sh", "--check")
		if err := cmd.Start(); err != nil {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		done := make(chan error, 1)
		go func() { done <- cmd.Wait() }()
		select {
		case <-time.After(8 * time.Second):
			_ = cmd.Process.Kill()
			w.WriteHeader(http.StatusInternalServerError)
		case err := <-done:
			if err == nil {
				w.WriteHeader(http.StatusOK)
			} else {
				w.WriteHeader(http.StatusForbidden)
			}
		}
	})
	fmt.Println("gate-shim listening on 127.0.0.1:9007")
	_ = http.ListenAndServe("127.0.0.1:9007", nil)
}
