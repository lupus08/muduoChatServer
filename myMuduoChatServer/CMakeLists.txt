cmake_minimum_required(VERSION 3.10)
project(chat CXX)

# 代码用到了 C++11 特性（auto / lambda / std::function / unordered_map）
set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 配置编译选项
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -g -Wall")

# 配置最终的可执行文件输出的路径
set(EXECUTABLE_OUTPUT_PATH ${PROJECT_SOURCE_DIR}/bin)

# 配置头文件的搜索路径
include_directories(
    ${PROJECT_SOURCE_DIR}/include
    ${PROJECT_SOURCE_DIR}/include/server
    ${PROJECT_SOURCE_DIR}/include/server/db
    ${PROJECT_SOURCE_DIR}/include/server/model
    ${PROJECT_SOURCE_DIR}/include/server/redis
    ${PROJECT_SOURCE_DIR}/thirdparty
)

# ------------------------------------------------------------
# 依赖查找：不再写死 /usr/lib64/mysql，兼容 Ubuntu / CentOS
# ------------------------------------------------------------

# MySQL 客户端库
find_path(MYSQL_INCLUDE_DIR
    NAMES mysql/mysql.h
    PATHS /usr/include /usr/local/include /usr/include/mysql /usr/local/mysql/include)
find_library(MYSQL_LIBRARY
    NAMES mysqlclient mysqlclient_r
    PATHS /usr/lib64/mysql /usr/lib/x86_64-linux-gnu /usr/lib/mysql
          /usr/local/lib /usr/local/mysql/lib)
if(NOT MYSQL_INCLUDE_DIR OR NOT MYSQL_LIBRARY)
    message(FATAL_ERROR
        "找不到 MySQL 客户端库。\n"
        "  Ubuntu/Debian: sudo apt install libmysqlclient-dev\n"
        "  CentOS/RHEL  : sudo yum install mysql-devel")
endif()

# hiredis
find_path(HIREDIS_INCLUDE_DIR NAMES hiredis/hiredis.h)
find_library(HIREDIS_LIBRARY NAMES hiredis)
if(NOT HIREDIS_INCLUDE_DIR OR NOT HIREDIS_LIBRARY)
    message(FATAL_ERROR
        "找不到 hiredis。\n"
        "  Ubuntu/Debian: sudo apt install libhiredis-dev\n"
        "  CentOS/RHEL  : sudo yum install hiredis-devel")
endif()

# muduo（需先安装，见 README）
find_path(MUDUO_INCLUDE_DIR NAMES muduo/net/TcpServer.h PATHS /usr/local/include /usr/include)
find_library(MUDUO_NET_LIBRARY NAMES muduo_net PATHS /usr/local/lib /usr/lib)
find_library(MUDUO_BASE_LIBRARY NAMES muduo_base PATHS /usr/local/lib /usr/lib)
if(NOT MUDUO_INCLUDE_DIR OR NOT MUDUO_NET_LIBRARY OR NOT MUDUO_BASE_LIBRARY)
    message(FATAL_ERROR
        "找不到 muduo。请先按 README 编译安装：\n"
        "  git clone https://github.com/chenshuo/muduo.git\n"
        "  cd muduo && ./build.sh -j$(nproc) && sudo ./build.sh install && sudo ldconfig")
endif()

find_package(Threads REQUIRED)

include_directories(${MYSQL_INCLUDE_DIR} ${HIREDIS_INCLUDE_DIR} ${MUDUO_INCLUDE_DIR})

# 加载子目录
add_subdirectory(src)
