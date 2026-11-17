package quota

import (
	"encoding/json"
	"net/http"

	"backend/internal/audit"
)

// HeaderQuotaMiddleware 业务层请求头配额：总量超限返回 431（与平台语义一致），
// 并在响应体中给出限额与实测值，便于定位是"谁配小了"。
// 限额来自构建期固化的配额配置（见 internal/config），进程启动时即确定。
//
// 本中间件同时承担两件链路级事项（均在配额判定之前执行）：
//   1) X-Trace-Context 回显：上游（tracegate/meshd）追加过的 trace 上下文原样写回
//      响应头，作为"请求确实经过插件与 sidecar 两跳"的链路证据；
//   2) 异步审计上报：请求头快照发布到 Kafka 审计总线（fire-and-forget，绝不阻塞）。
func HeaderQuotaMiddleware(limit int, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if tc := r.Header.Get("X-Trace-Context"); tc != "" {
			w.Header().Set("X-Trace-Context", tc)
		}
		audit.Publish(r)
		total := len(r.RequestURI) + 16
		for name, vals := range r.Header {
			total += len(name) + 4
			for _, v := range vals {
				total += len(v)
			}
		}
		if total >= limit { // 边界：恰好等于限额同样拒绝（含等号的保守口径）
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest) // 语义码由入口网关统一改写为 431（历史约定）
			_ = json.NewEncoder(w).Encode(map[string]interface{}{
				"code":      431,
				"msg":       "request header quota exceeded",
				"component": "backend",
				"limit":     limit,
				"observed":  total,
			})
			return
		}
		next.ServeHTTP(w, r)
	})
}
