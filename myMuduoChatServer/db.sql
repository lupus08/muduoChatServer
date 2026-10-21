-- ============================================================
-- 集群聊天服务器 数据库初始化脚本
-- 用法：mysql -u root -p < db.sql
-- 字符集统一 utf8mb4（与 db.cpp 中 set names utf8mb4 对应）
-- ============================================================

CREATE DATABASE IF NOT EXISTS chat
    DEFAULT CHARACTER SET utf8mb4
    DEFAULT COLLATE utf8mb4_general_ci;

USE chat;

-- ------------------------------------------------------------
-- 用户表
-- 注意：列顺序必须是 id, name, password, state
--       usermodel.cpp 里用 select * 并按 row[0..3] 取值
-- ------------------------------------------------------------
DROP TABLE IF EXISTS user;
CREATE TABLE user
(
    id       INT          NOT NULL AUTO_INCREMENT COMMENT '用户id',
    name     VARCHAR(50)  NOT NULL                COMMENT '用户名',
    password VARCHAR(50)  NOT NULL                COMMENT '密码（课程原版为明文，改进建议见 README）',
    state    ENUM('online','offline') NOT NULL DEFAULT 'offline' COMMENT '在线状态',
    PRIMARY KEY (id),
    UNIQUE KEY uk_name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户表';

-- ------------------------------------------------------------
-- 好友表
-- friendmoel.cpp: insert into friend values(userid, friendid)
-- 列顺序必须是 userid, friendid
-- ------------------------------------------------------------
DROP TABLE IF EXISTS friend;
CREATE TABLE friend
(
    userid   INT NOT NULL COMMENT '用户id',
    friendid INT NOT NULL COMMENT '好友id',
    PRIMARY KEY (userid, friendid),
    KEY idx_friendid (friendid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='好友关系表';

-- ------------------------------------------------------------
-- 群组表
-- groupmodel.cpp: insert into allgroup(groupname, groupdesc) values(...)
-- id 自增
-- ------------------------------------------------------------
DROP TABLE IF EXISTS allgroup;
CREATE TABLE allgroup
(
    id        INT          NOT NULL AUTO_INCREMENT COMMENT '群组id',
    groupname VARCHAR(50)  NOT NULL                COMMENT '群组名称',
    groupdesc VARCHAR(200) NOT NULL DEFAULT ''     COMMENT '群组描述',
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='群组表';

-- ------------------------------------------------------------
-- 群组成员表
-- groupmodel.cpp: insert into groupuser values(groupid, userid, role)
-- 列顺序必须是 groupid, userid, grouprole
-- ------------------------------------------------------------
DROP TABLE IF EXISTS groupuser;
CREATE TABLE groupuser
(
    groupid   INT NOT NULL                         COMMENT '群组id',
    userid    INT NOT NULL                         COMMENT '用户id',
    grouprole ENUM('creator','normal') NOT NULL DEFAULT 'normal' COMMENT '群内角色',
    PRIMARY KEY (groupid, userid),
    KEY idx_groupuser_userid (userid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='群组成员表';

-- ------------------------------------------------------------
-- 离线消息表
-- offlinemessagemodel.cpp: insert into offlinemessage values(userid, msg)
-- 列顺序必须是 userid, message
-- ------------------------------------------------------------
DROP TABLE IF EXISTS offlinemessage;
CREATE TABLE offlinemessage
(
    userid  INT          NOT NULL COMMENT '接收者id',
    message VARCHAR(500) NOT NULL COMMENT 'JSON 格式的消息体',
    KEY idx_offline_userid (userid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='离线消息表';

-- ------------------------------------------------------------
-- 验证
-- ------------------------------------------------------------
SHOW TABLES;
