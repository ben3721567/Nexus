#!/bin/bash
set -e

BASE_CONTAINER_NAME="nexus-node"
IMAGE_NAME="nexus-node:latest"
LOG_DIR="/root/nexus_logs"

# 检查 Docker 是否安装（适配 CentOS 7.9）
function check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "未检测到 Docker，开始安装..."
        yum install -y yum-utils device-mapper-persistent-data lvm2
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        yum install -y docker-ce docker-ce-cli containerd.io
        systemctl enable docker
        systemctl start docker
    fi
}

# 检查 Node.js/npm/pm2 是否安装（适配 CentOS）
function check_pm2() {
    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        echo "未检测到 Node.js/npm，开始安装..."
        curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
        yum install -y nodejs
    fi
    if ! command -v pm2 >/dev/null 2>&1; then
        echo "未检测到 pm2，开始安装..."
        npm install -g pm2
    fi
}

# 构建 docker 镜像
function build_image() {
    WORKDIR=$(mktemp -d)
    cd "$WORKDIR"

    cat > Dockerfile <<EOF
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
ENV PROVER_ID_FILE=/root/.nexus/node-id

RUN apt-get update && apt-get install -y \
    curl \
    screen \
    bash \
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSL https://cli.nexus.xyz/ | NONINTERACTIVE=1 sh \
    && ln -sf /root/.nexus/bin/nexus-network /usr/local/bin/nexus-network

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > entrypoint.sh <<EOF
#!/bin/bash
set -e

PROVER_ID_FILE="/root/.nexus/node-id"

if [ -z "\$NODE_ID" ]; then
    echo "错误：未设置 NODE_ID 环境变量"
    exit 1
fi

echo "\$NODE_ID" > "\$PROVER_ID_FILE"
echo "使用的 node-id: \$NODE_ID"

if ! command -v nexus-network >/dev/null 2>&1; then
    echo "错误：nexus-network 未安装或不可用"
    exit 1
fi

screen -S nexus -X quit >/dev/null 2>&1 || true

echo "启动 nexus-network 节点..."
screen -dmS nexus bash -c "nexus-network start --node-id \$NODE_ID &>> /root/nexus.log"

sleep 3

if screen -list | grep -q "nexus"; then
    echo "节点已在后台启动。"
    echo "日志文件：/root/nexus.log"
else
    echo "节点启动失败，请检查日志。"
    cat /root/nexus.log
    exit 1
fi

tail -f /root/nexus.log
EOF

    docker build -t "$IMAGE_NAME" .
    cd -
    rm -rf "$WORKDIR"
}

# 启动容器
function run_container() {
    local node_id=$1
    local container_name="${BASE_CONTAINER_NAME}-${node_id}"
    local log_file="${LOG_DIR}/nexus-${node_id}.log"

    docker rm -f "$container_name" 2>/dev/null || true
    mkdir -p "$LOG_DIR"
    touch "$log_file"
    chmod 644 "$log_file"

    docker run -d --name "$container_name" -v "$log_file":/root/nexus.log -e NODE_ID="$node_id" "$IMAGE_NAME"
    echo "容器 $container_name 启动完成。"
}

# 列出所有节点
function list_nodes() {
    echo "当前节点："
    docker ps -a --filter "name=${BASE_CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.RunningFor}}"
    read -p "按任意键返回菜单..."
}

# 查看日志
function view_logs() {
    read -rp "输入 node-id: " node_id
    local container_name="${BASE_CONTAINER_NAME}-${node_id}"
    docker logs -f "$container_name"
}

# 卸载节点
function uninstall_node() {
    read -rp "输入要删除的 node-id: " node_id
    local container_name="${BASE_CONTAINER_NAME}-${node_id}"
    docker rm -f "$container_name"
    rm -f "${LOG_DIR}/nexus-${node_id}.log"
    echo "已删除节点 $node_id"
    read -p "按任意键返回菜单..."
}

# 设置定时清理日志任务
function setup_log_cleanup_cron() {
    local cron_job="0 3 */2 * * find $LOG_DIR -type f -name 'nexus-*.log' -mtime +2 -delete"
    (crontab -l 2>/dev/null | grep -v -F "$cron_job"; echo "$cron_job") | crontab -
    echo "已设置每2天清理一次日志任务。"
}

# 主菜单
check_docker
check_pm2
setup_log_cleanup_cron

while true; do
    clear
    echo "====== Nexus 节点管理（CentOS 7.9）======"
    echo "1. 安装并启动新节点"
    echo "2. 显示所有节点"
    echo "3. 查看节点日志"
    echo "4. 删除节点"
    echo "5. 退出"
    echo "======================================="
    read -rp "请输入选项(1-5): " choice

    case $choice in
        1)
            read -rp "请输入 node-id: " NODE_ID
            [ -z "$NODE_ID" ] && echo "node-id 不能为空" && read -p "按任意键继续..." && continue
            build_image
            run_container "$NODE_ID"
            read -p "按任意键返回菜单..."
            ;;
        2)
            list_nodes
            ;;
        3)
            view_logs
            ;;
        4)
            uninstall_node
            ;;
        5)
            echo "退出脚本。"
            exit 0
            ;;
        *)
            echo "无效选项。"
            read -p "按任意键继续..."
            ;;
    esac
done
