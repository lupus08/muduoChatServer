# 定义了一个SRC_LIST变量，包含了该目录下所有的源文件
aux_source_directory(. SRC_LIST)
aux_source_directory(./db DB_LIST)
aux_source_directory(./model MODEL_LIST)
aux_source_directory(./redis REDIS_LIST)

# 指定生成可执行文件
add_executable(ChatServer ${SRC_LIST} ${DB_LIST} ${MODEL_LIST} ${REDIS_LIST})

# 指定可执行文件链接时需要依赖的库文件
# 具体路径由根 CMakeLists.txt 里的 find_library 解析，避免写死 /usr/lib64/mysql
target_link_libraries(ChatServer
    ${MUDUO_NET_LIBRARY}
    ${MUDUO_BASE_LIBRARY}
    ${MYSQL_LIBRARY}
    ${HIREDIS_LIBRARY}
    Threads::Threads
)
