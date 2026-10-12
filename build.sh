#!/usr/bin/env bash
# 构建 amd64 镜像并导出离线 tar 包
# 用法:
#   ./build.sh                                  # 默认不预装 opencode
#   INSTALL_OPENCODE=true ./build.sh            # 把 opencode-bin-cli/opencode 烧进镜像
#   OIC_URL=https://.../instantclient-basic-linux.x64-11.2.0.4.0.zip ./build.sh   # 指定 Oracle 客户端
set -euo pipefail
cd "$(dirname "$0")"

IMAGE_NAME=vscode-webai
TAG=latest
INSTALL_OPENCODE="${INSTALL_OPENCODE:-false}"
OIC_URL="${OIC_URL:-}"

# Dockerfile 里有 `COPY opencode-bin-cli/`, 目录不存在会直接构建失败
mkdir -p opencode-bin-cli

if [ "$INSTALL_OPENCODE" = "true" ] && [ ! -f opencode-bin-cli/opencode ]; then
    echo "==> INSTALL_OPENCODE=true 但 opencode-bin-cli/opencode 不存在, 请先放入二进制"
    exit 1
fi

echo "==> [1/2] 构建镜像 ${IMAGE_NAME}:${TAG} (linux/amd64, install-opencode=${INSTALL_OPENCODE}) ..."
docker build --platform linux/amd64 \
    --build-arg "INSTALL_OPENCODE=${INSTALL_OPENCODE}" \
    --build-arg "OIC_URL=${OIC_URL}" \
    -t "${IMAGE_NAME}:${TAG}" .

echo "==> [2/2] 导出离线包 ${IMAGE_NAME}_amd64.tar ..."
docker save -o "${IMAGE_NAME}_amd64.tar" "${IMAGE_NAME}:${TAG}"

echo "==> 完成: $(ls -lh "${IMAGE_NAME}_amd64.tar" | awk '{print $5, $9}')"
echo "服务器导入: docker load -i ${IMAGE_NAME}_amd64.tar"
echo "Oracle 依赖自检: docker run --rm ${IMAGE_NAME}:${TAG} test-oracle-instantclient --skip-pip"
