# Violet Starter

Violet — 一键部署仓库。

## 架构概览

```
Client (UniApp) ──HTTP/TCP──> Gateway ──gRPC──> Action / IM / AIGC
                                  │                         │
                                  └──Push──> Client         │
                                                        Chatbot (消费 IM 消息)

大数据链路：
  Kafka ──> Flink(Trending) ──> KVrocks(热度榜)
  Kafka ──> Airflow 定时调度 ──> Spark(Swing i2i) ──> NebulaGraph(相似图)
```

| 服务 | 语言 | 端口 | 职责 |
|------|------|------|------|
| Gateway | Java 8 + Spring Boot | 3000(HTTP) 3001(TCP) 3002(gRPC) | 统一入口、鉴权、跨服务聚合、Netty 推送 |
| Action | Java 8 + Spring Boot | 3003(gRPC) | 用户/关系/互动/行为事件 |
| AIGC | Java 8 + Spring Boot | 3005(gRPC) | 素材生成、创作管理、搜索推荐 |
| IM | Go 1.22 | 3004(gRPC) | 会话/消息/通知、MQ扇出推送 |
| Chatbot | Python 3.11 + uv | 无端口(消费MQ) | 多智能体群聊编排、记忆、拟人化 |
| Trending | Java 21 + Flink | - | 实时热度计算，写入KVrocks |
| Swing | PySpark | - | Swing i2i 离线相似图，写入NebulaGraph |

## 基础设施

| 组件 | 端口 | 用途 |
|------|------|------|
| MySQL | 3306 | 事实数据 |
| Redis | 6379 | 缓存/会话/在线状态 |
| KVrocks | 6666 | 热度榜/评论/消息索引链 |
| RocketMQ | 9876 / 10911 | IM 消息扇出 |
| Kafka | 9092(内部) / 9094(外部) | 行为事件总线/索引构建 |
| Milvus | 19530 | 向量检索(用户搜寻/创作推荐) |
| NebulaGraph | 9669 | 社交图/相似图 |
| Airflow | 8084 | 定时调度Spark任务 |
| Spark | 7077 / 8090(WebUI) | Swing i2i 离线计算 |
| Flink | 8082 | Trending 实时热度 |
| Hive | 9083(Metastore) / 10000(HiveServer2) | 离线数仓 |
| JuiceFS | - | 共享存储(OSS) |

## 快速部署

```bash
# 克隆
mkdir ~/violet && cd ~/violet
git clone https://github.com/Violet-Feed/starter.git
cd starter

# 1. 启动基础设施
bash violet-deploy.sh deploy

# 2. 启动数据服务 (Spark/Flink/Hive/Airflow)
bash violet-data-deploy.sh deploy

# 3. 初始化数据库与中间件
bash violet-init.sh

# 4. 部署后端服务
# 补充配置文件中key
bash violet-setup.sh all
```

## 管理命令

### 基础设施

```bash
bash violet-deploy.sh start              # 启动
bash violet-deploy.sh stop [service]      # 停止
bash violet-deploy.sh restart [service]   # 重启
bash violet-deploy.sh redeploy [service]  # 重建容器
bash violet-deploy.sh logs [service]      # 查看日志
```

### 后端服务

```bash
bash violet-setup.sh start               # 启动全部后端
bash violet-setup.sh stop [service]       # 停止
bash violet-setup.sh restart [service]     # 重启
bash violet-setup.sh rebuild [service]    # 重新构建并启动
bash violet-setup.sh logs [service]        # 查看日志
```

service 名：gateway / action / aigc / im / chatbot

### 数据服务

```bash
bash violet-data-deploy.sh start              # 启动
bash violet-data-deploy.sh stop [service]       # 停止
bash violet-data-deploy.sh restart [service]   # 重启
bash violet-data-deploy.sh redeploy [service]  # 重建容器
bash violet-data-deploy.sh logs [service]       # 查看日志
```

service 名：postgres / juicefs / hive-metastore / hiveserver2 / spark / jobmanager / taskmanager / airflow

Flink Trending 任务随 jobmanager 启动自动构建并提交。Spark 任务由 Airflow 调度。

## 目录结构

```
starter/
├── violet-docker-compose.yaml      # 基础设施 + 后端服务编排
├── violet-data-docker-compose.yaml  # 数据服务编排 (Spark/Flink/Hive/Airflow)
├── violet-deploy.sh                 # 基础设施部署管理
├── violet-data-deploy.sh             # 数据服务部署管理
├── violet-setup.sh                  # 后端服务部署管理
├── violet-init.sh                   # 数据库与中间件初始化
├── docker/                          # 各服务 Dockerfile 与配置覆盖
│   ├── gateway/
│   ├── action/
│   ├── aigc/
│   ├── im/
│   └── chatbot/
├── .config/                         # 数据服务配置
│   ├── airflow/
│   ├── flink/
│   ├── hive/
│   ├── juicefs/
│   ├── postgres/
│   └── spark/
├── mysql/                            # MySQL 初始化 SQL
├── milvus/                           # Milvus 配置
├── nebula/                           # NebulaGraph 初始化
├── rocketmq/                          # RocketMQ 配置
└── kvrocks/                           # KVrocks 配置
```

## 服务依赖关系

```
Client ──HTTP──> Gateway ──gRPC──> Action  ──> MySQL, Redis, KVrocks, Nebula, Milvus, Kafka
                      │────gRPC──> AIGC    ──> MySQL, KVrocks, Nebula, Milvus, Kafka
                      │────gRPC──> IM      ──> MySQL, Redis, KVrocks, RocketMQ
                      │────gRPC──> Chatbot ──> MySQL, Redis, RocketMQ
                      └──> Client
```