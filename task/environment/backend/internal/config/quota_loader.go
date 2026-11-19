package config

import (
	"embed"
	"fmt"
	"strconv"
	"strings"
)

// LoadQuota 从构建期嵌入的配额配置中解析 max_header_bytes（字节）。
//
// 说明：配额随二进制固化，磁盘上的 configs/*.yaml 是构建时的存档副本——
// 修改磁盘文件不会影响已部署进程，须重新构建并重启后方可生效。
// 配置缺失或数值无效时返回错误（由入口拒绝启动，避免静默回退到错误限额）。
func LoadQuota(fsys embed.FS) (int, error) {
	data, err := fsys.ReadFile(QuotaFile)
	if err != nil {
		return 0, fmt.Errorf("配额配置 %s 缺失（应随构建期嵌入）: %w", QuotaFile, err)
	}
	limit, err := parseQuota(string(data))
	if err != nil {
		return 0, fmt.Errorf("配额配置 %s 无效: %w", QuotaFile, err)
	}
	return limit, nil
}

// parseQuota 解析 KEY: VALUE 形式的 max_header_bytes；仅接受十进制。
func parseQuota(content string) (int, error) {
	limit := 0
	for _, raw := range strings.Split(content, "\n") {
		line := strings.TrimSpace(raw)
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
		return 0, fmt.Errorf("max_header_bytes 无效")
	}
	return limit, nil
}
