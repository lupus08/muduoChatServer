# chatserver —— 基于 muduo 的集群聊天服务器

一个可工作在 **nginx TCP 负载均衡**环境下的集群聊天服务器与客户端，网络层基于
[muduo](https://github.com/chenshuo/muduo)，支持单聊、群聊、好友、离线消息，
多机之间通过 **Redis 发布订阅**中转消息。

> 本仓库在原始课程代码基础上做了工程化整改：修正构建脚本中的硬编码路径、
> 补充建表脚本与容器化开发环境、修正字符集设置。详见 [变更说明](#变更说明)。

---

## 架构

```
        ┌──────────┐
客户端 ─→│  nginx   │  四层（stream）TCP 负载均衡
        └────┬─────┘
             │
     ┌───────┴────────┐
     ▼                ▼
┌──────────┐    ┌──────────┐
│ChatServer│    │ChatServer│   多实例，各自持有本机连接表
└────┬─────┘    └────┬─────┘
     │  publish/subscribe
     └───────┬────────┘
             ▼
        ┌────────┐
        │ Redis  │  跨服消息中转（按 userid 建 channel）
        └────────┘
             │
             ▼
        ┌────────┐
        │ MySQL  │  用户 / 好友 / 群组 / 离线消息
        └────────┘
```

**三层解耦**

| 层 | 文件 | 职责 |
|---|---|---|
| 网络层 | `src/server/chatserver.cpp` | 只做连接管理与拆包，不碰业务 |
| 业务层 | `src/server/chatservice.cpp` | 按 `msgid` 分发到 handler（单例） |
| 数据层 | `src/server/model/*` | 每张表一个 Model，封装 SQL |

**消息分发**：`ChatService` 维护 `unordered_map<int, MsgHandler>`，
`msgid` → 处理函数。未知 `msgid` 返回只打日志的空操作，不会崩。

**跨服聊天**：登录时 `subscribe(channel = userid)`；本机连不上对方时查在线状态，
若对方在别的服务器在线则 `publish` 到该频道，由对方所在服务器的订阅线程收到并转发。

---

## 目录结构

```
include/
  public.hpp                  服务端/客户端共用的 msgid 枚举
  server/chatserver.hpp       网络层封装
  server/chatservice.hpp      业务层
  server/db/db.h              MySQL 连接
  server/model/               user / friend / group / groupuser / offlinemessage
  server/redis/redis.hpp      Redis 发布订阅
src/
  server/                     服务端
  client/                     命令行客户端
thirdparty/json.hpp           nlohmann/json
db.sql                        建表脚本
.devcontainer/                GitHub Codespaces 开发环境
autobuild.sh                  一键编译
```

---

## 快速开始

### 方式一：GitHub Codespaces（无需本地 Linux 环境，推荐）

1. 打开仓库页面 → 绿色 **Code** 按钮 → **Codespaces** → **Create codespace on master**
2. 等待容器创建，`postCreateCommand` 会自动：装依赖 → 编译 muduo → 启动 MySQL/Redis → 建库建表 → 编译项目
3. 用两个终端分别启动：

```bash
# 终端 1
./bin/ChatServer 127.0.0.1 6000

# 终端 2
./bin/ChatClient 127.0.0.1 6000 zhangsan
```

> 免费账户每月 120 核小时（2 核机器可跑 60 小时）+ 15 GB 存储。
> 容器空闲会自动停止，停止后需重启 MySQL/Redis（`postStartCommand` 已处理）。
> **注意：Codespaces 不是常驻服务器，不能当 7×24 的 VPS 用。**

### 方式二：本地 Ubuntu / 云服务器

```bash
# 1. 依赖
sudo apt update
sudo apt install -y cmake g++ libboost-dev libmysqlclient-dev libhiredis-dev \
                    mysql-server redis-server

# 2. muduo（Ubuntu 源里没有，需源码编译）
git clone https://github.com/chenshuo/muduo.git
cd muduo && ./build.sh -j$(nproc) && sudo ./build.sh install
sudo ldconfig
cd ..

# 3. 启动服务
sudo service mysql start
sudo service redis-server start

# 4. 建库（首次需要给 root 设置密码，与 db.cpp 中的配置一致）
sudo mysql -e "ALTER USER 'root'@'localhost' \
    IDENTIFIED WITH mysql_native_password BY '123456';"
mysql -uroot -p123456 < db.sql

# 5. 编译
./autobuild.sh
```

启动：

```bash
./bin/ChatServer 127.0.0.1 6000
./bin/ChatClient 127.0.0.1 6000 zhangsan
```

### 方式三：nginx 负载均衡 + 双实例（集群验证）

`/etc/nginx/nginx.conf` 中添加 `stream` 块（注意是**四层**，不是 `http` 块）：

```nginx
stream {
    upstream chatservers {
        server 127.0.0.1:6001;
        server 127.0.0.1:6002;
    }
    server {
        listen 6000;
        proxy_pass chatservers;
        proxy_connect_timeout 3s;
        proxy_timeout 10s;
    }
}
```

```bash
# 同一个 build 产物，用不同端口起两个实例
./bin/ChatServer 127.0.0.1 6001 &
./bin/ChatServer 127.0.0.1 6002 &

sudo nginx -s reload

# 两个客户端都连 6000，会被分发到不同实例
./bin/ChatClient 127.0.0.1 6000 zhangsan
./bin/ChatClient 127.0.0.1 6000 lisi
```

此时 A、B 落在不同进程上，仍能互相发消息 —— 这条链路走的就是 Redis 中转。

---

## 数据库

`db.sql` 会创建 5 张表：

| 表 | 说明 | 关键约束 |
|---|---|---|
| `user` | 用户 | 列顺序 `id,name,password,state`；`state` 为 online/offline |
| `friend` | 好友关系 | `(userid, friendid)` 联合主键 |
| `allgroup` | 群组 | `id` 自增 |
| `groupuser` | 群成员 | `(groupid, userid)` 联合主键，角色 creator/normal |
| `offlinemessage` | 离线消息 | 按 `userid` 建索引 |

> 表结构里的**列顺序不能改**：Model 层用的是
> `insert into xxx values(...)` 这种不写列名的写法，以及 `select *` 后按
> `row[0..n]` 取值。改动列顺序会导致数据错位。

数据库连接配置在 `src/server/db/db.cpp` 顶部：

```cpp
static string server   = "127.0.0.1";
static string user     = "root";
static string password = "123456";
static string dbname   = "chat";
```

---

## 协议

客户端与服务端之间收发 **JSON**，用 `msgid` 区分类型（见 `include/public.hpp`）：

| msgid | 含义 |
|---|---|
| 1 / 2 | 登录 / 登录响应 |
| 3 | 注销 |
| 4 / 5 | 注册 / 注册响应 |
| 6 | 单聊 |
| 7 | 添加好友 |
| 8 | 创建群组 |
| 9 | 加入群组 |
| 10 | 群聊 |

示例（登录）：

```json
{"msgid": 1, "id": 1001, "password": "123456"}
```

---

## 已知问题与改进方向

以下是当前实现的**真实短板**，也是这个项目最值得动手的地方：

| 问题 | 位置 | 建议 |
|---|---|---|
| **没有消息边界**，把一次 read 当作一条消息，粘包/半包会解析失败 | `chatserver.cpp:50` | 加长度前缀或 `\r\n` 分隔，循环取完整帧 |
| `json::parse` 未捕获异常，畸形包会让进程 `terminate` | `chatserver.cpp:56` | `try/catch` + 单帧长度上限 |
| **SQL 注入**（`sprintf` 拼 SQL） | `model/*.cpp` | 改用 `mysql_stmt_prepare` 预处理语句 |
| **每次数据库操作都新建连接**，无连接池 | `model/*.cpp` | 实现连接池 + RAII 归还 |
| `reset()` 把**全集群**的在线用户置为 offline | `usermodel.cpp:80` | 只重置本机连接表内的用户，或把在线态迁到 Redis |
| 在线状态存 MySQL，每条跨服消息都要查一次库 | `chatservice.cpp:266` | 在线集合放 Redis（`SISMEMBER`） |
| Redis 订阅上下文跨线程读写无锁（hiredis context 非线程安全） | `redis.cpp` | 给写操作加锁，或统一由订阅线程执行命令 |
| 群聊时持锁做 DB 查询与 Redis 发布，锁被长时间占用 | `chatservice.cpp:318` | 锁内只拷贝连接指针，锁外发送 |
| 服务端完全信任客户端传来的 `js["id"]`，身份可伪造 | `chatservice.cpp` 各 handler | 登录后绑定「连接 → userid」，后续以连接为准 |
| 密码明文存储 | `db.sql` | 加盐哈希（如 SHA-256 + salt） |
| 离线消息无时间戳，顺序无法保证 | `db.sql` | 增加 `created_at` 并按其排序 |
| 无心跳/空闲超时 | — | 应用层心跳或 muduo `IdleConn` |
| 文件名拼写错误 | `src/server/model/friendmoel.cpp` | 建议改为 `friendmodel.cpp` |

---

## 变更说明

本次相对原始版本做了以下整改（不涉及业务逻辑）：

1. **`CMakeLists.txt`**：去掉写死的 `link_directories(/usr/lib64/mysql)`，
   改用 `find_library` / `find_path` 自动定位 MySQL、hiredis、muduo，
   找不到时给出明确的安装提示；补充 `CMAKE_CXX_STANDARD 11`。
2. **新增 `db.sql`**：原仓库缺失建表脚本，无法部署。
3. **`db.cpp`**：`set names gbk` → `set names utf8mb4`，
   与 UTF-8 源码和 utf8mb4 表结构一致，修复中文乱码。
4. **新增 `.devcontainer/`**：GitHub Codespaces 一键环境（自动装依赖、
   编译 muduo、初始化数据库、编译项目）。
5. **新增 `.gitignore`**：排除 `build/`、`bin/` 等构建产物。
6. **本 README**：补充架构说明、部署步骤、协议定义与已知问题清单。

> 仓库中仍然跟踪着 `bin/ChatServer`、`bin/ChatClient`、`test/testjson/testjson`
> 三个 Linux ELF 可执行文件（约 11 MB）。建议移出版本库：
>
> ```bash
> git rm --cached bin/ChatServer bin/ChatClient test/testjson/testjson
> ```

---

## 参考

- muduo：https://github.com/chenshuo/muduo
- nginx TCP/UDP 负载均衡（stream 模块）：https://nginx.org/en/docs/stream/ngx_stream_core_module.html
- hiredis：https://github.com/redis/hiredis
