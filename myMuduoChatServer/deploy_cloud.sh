#!/usr/bin/env bash
# ============================================================
# 集群聊天服务器 —— 云服务器一键部署脚本
#
# 适用：Ubuntu 20.04 / 22.04（阿里云、腾讯云、华为云均可）
# 用法：
#   git clone <你的仓库> /opt/chatserver && cd /opt/chatserver
#   sudo bash deploy_cloud.sh
#
# 做完的事：
#   1. 小内存机器自动加 swap（编译 muduo 需要）
#   2. 装 cmake / g++ / MySQL / Redis / nginx
#   3. 源码编译安装 muduo
#   4. 针对小内存优化 MySQL 配置
#   5. 建库建表
#   6. 编译项目
#   7. 注册 systemd 服务：两个 ChatServer 实例（6001 / 6002）
#   8. 配置 nginx 四层负载均衡（对外 6000）
# ============================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_PASS="123456"          # 与 src/server/db/db.cpp 中的配置保持一致
PORT_A=6001               # 实例 A
PORT_B=6002               # 实例 B
PUBLIC_PORT=6000          # nginx 对外端口

log() { echo -e "\n\033[1;36m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m[警告] $*\033[0m"; }

[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行：sudo bash deploy_cloud.sh"; exit 1; }
[ -f "${REPO_DIR}/db.sql" ] || { echo "找不到 db.sql，请在仓库根目录运行"; exit 1; }

log "仓库目录: ${REPO_DIR}"

# ------------------------------------------------------------
log "[1/8] 检查内存并补充 swap"
MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
echo "    物理内存: ${MEM_MB} MB"
if [ "${MEM_MB}" -lt 2000 ]; then
    if swapon --show | grep -q .; then
        echo "    已有 swap，跳过"
    else
        echo "    内存偏小，创建 2G swap（编译 muduo 需要）"
        fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo "    swap 已启用"
    fi
else
    echo "    内存充足，无需 swap"
fi

# ------------------------------------------------------------
log "[2/8] 安装系统依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    cmake g++ git make pkg-config ca-certificates \
    libboost-dev libmysqlclient-dev libhiredis-dev \
    mysql-server redis-server nginx libnginx-mod-stream

# ------------------------------------------------------------
log "[3/8] 编译安装 muduo"
if ldconfig -p 2>/dev/null | grep -q muduo_net; then
    echo "    muduo 已安装，跳过"
else
    cd /tmp
    rm -rf muduo
    git clone --depth 1 https://github.com/chenshuo/muduo.git
    cd muduo
    ./build.sh -j"$(nproc)"
    ./build.sh install
    ldconfig
    echo "    muduo 安装完成"
fi

# ------------------------------------------------------------
log "[4/8] 优化 MySQL 配置（小内存机器）"
cat > /etc/mysql/mysql.conf.d/99-chat.cnf <<'EOF'
[mysqld]
innodb_buffer_pool_size = 128M
max_connections = 100
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci
EOF

systemctl enable --now mysql
systemctl enable --now redis-server

# 等待 MySQL 就绪
for i in $(seq 1 30); do
    mysqladmin ping >/dev/null 2>&1 && break
    sleep 1
done
systemctl restart mysql
for i in $(seq 1 30); do
    mysqladmin ping >/dev/null 2>&1 && break
    sleep 1
done
echo "    MySQL / Redis 已启动"
redis-cli ping >/dev/null 2>&1 && echo "    Redis: $(redis-cli ping)" || warn "Redis 未响应"

# ------------------------------------------------------------
log "[5/8] 初始化数据库"
# root 默认走 socket 认证，这里改成密码认证，供程序通过 TCP 连接
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${DB_PASS}';" 2>/dev/null \
  || mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_PASS}';" 2>/dev/null \
  || warn "修改 root 密码失败，可能需要手动处理"

mysql -uroot -p"${DB_PASS}" < "${REPO_DIR}/db.sql"
echo "    建库建表完成"
mysql -uroot -p"${DB_PASS}" -e "USE chat; SHOW TABLES;" 2>/dev/null

# ------------------------------------------------------------
log "[6/8] 编译项目"
mkdir -p "${REPO_DIR}/build"
cd "${REPO_DIR}"
chmod +x autobuild.sh
./autobuild.sh
echo "    编译完成"
ls -lh bin/

# ------------------------------------------------------------
log "[7/8] 注册 systemd 服务（两个实例）"
cat > /etc/systemd/system/chatserver@.service <<EOF
[Unit]
Description=ChatServer instance on port %i
After=network.target mysql.service redis-server.service
Wants=mysql.service redis-server.service

[Service]
Type=simple
WorkingDirectory=${REPO_DIR}
ExecStart=${REPO_DIR}/bin/ChatServer 127.0.0.1 %i
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
for p in ${PORT_A} ${PORT_B}; do
    systemctl enable "chatserver@${p}"
    systemctl restart "chatserver@${p}"
done
sleep 2
systemctl --no-pager --lines=0 status "chatserver@${PORT_A}" | head -5 || true
systemctl --no-pager --lines=0 status "chatserver@${PORT_B}" | head -5 || true

# ------------------------------------------------------------
log "[8/8] 配置 nginx 四层负载均衡"
# Ubuntu 的 stream 模块是动态加载的，先确认模块文件存在
if [ ! -f /etc/nginx/modules-enabled/50-mod-stream.conf ]; then
    echo 'load_module modules/ngx_stream_module.so;' > /etc/nginx/modules-enabled/50-mod-stream.conf
fi

mkdir -p /etc/nginx/stream.d
cat > /etc/nginx/stream.d/chat.conf <<EOF
# 聊天服务器四层负载均衡（TCP 透传，不解析应用层协议）
upstream chatserver_pool {
    server 127.0.0.1:${PORT_A} max_fails=2 fail_timeout=10s;
    server 127.0.0.1:${PORT_B} max_fails=2 fail_timeout=10s;
}

server {
    listen ${PUBLIC_PORT};
    proxy_pass chatserver_pool;
    proxy_connect_timeout 3s;
    proxy_timeout 10m;
}
EOF

# 在 nginx.conf 顶层引入 stream 配置（只需加一次）
if ! grep -q 'stream.d/\*.conf' /etc/nginx/nginx.conf; then
    printf '\n# 集群聊天服务器\ninclude /etc/nginx/stream.d/*.conf;\n' >> /etc/nginx/nginx.conf
fi

nginx -t
systemctl enable nginx
systemctl restart nginx
echo "    nginx 已启动并加载 stream 配置"

# ------------------------------------------------------------
PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 ip.sb || echo "<你的公网IP>")
echo ""
echo "============================================================"
echo " 部署完成"
echo "============================================================"
echo " 对外服务端口: ${PUBLIC_PORT}"
echo " 后端实例    : ${PORT_A}, ${PORT_B}（由 systemd 管理，自动重启）"
echo ""
echo " 客户端连接："
echo "   ./bin/ChatClient ${PUBLIC_IP} ${PUBLIC_PORT} 你的昵称"
echo ""
echo " 常用命令："
echo "   查看服务状态 : systemctl status chatserver@${PORT_A}"
echo "   查看日志     : journalctl -u chatserver@${PORT_A} -f"
echo "   重启全部     : systemctl restart 'chatserver@*'"
echo "   数据库       : mysql -uroot -p${DB_PASS} chat"
echo ""
echo " ！！！还要做一件事 ！！！"
echo "   去云厂商控制台的【安全组 / 防火墙】放行 TCP ${PUBLIC_PORT}"
echo "   否则公网连不上（这一步脚本无法代劳）"
echo "============================================================"
