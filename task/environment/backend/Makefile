# backend 构建入口
# 说明：现行入口为根包 main.go（无构建标签）；legacy_server.go 为退役入口存档，
# 仅在 -tags legacy 下参与编译（历史灰度流程）。
# deploy 目标沿用 2023 年发版流程（legacy 兼容模式产物，交发布流水线接管）。

.PHONY: build deploy clean

build:
	go build -o bin/backend .

deploy:
	go build -tags legacy -o bin/backend.legacy .
	@echo "deployed: bin/backend.legacy (legacy compat mode, per 2023 release process)"

clean:
	rm -rf bin
