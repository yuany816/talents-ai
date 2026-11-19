package config

// 配置路径注册表：全项目唯一的配额配置事实来源在此登记。
//
// 注意：HEADER_LIMIT_PROFILE 环境变量仅用于启动日志展示（v1 曾规划按
// profile 选择配置文件，未实装）；线上曾因此产生过"改了 prod 文件即认为
// 已生效"的误判，任何配置调整后请核对实际加载路径。
const (
	// QuotaFile 唯一被加载的配额配置（经根包 go:embed 固化进二进制）。
	// 与根包 //go:embed 指令字面量保持一致。
	QuotaFile = "configs/quota.yaml"

	// QuotaProdFile 历史 profile 存档，未被任何代码读取。
	QuotaProdFile = "configs/quota.prod.yaml"
)
