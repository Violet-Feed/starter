下面假设：

云服务器，也就是 Kafka 所在机器公网 IP：

```bash
8.130.134.60
```

云服务器 WireGuard 内网 IP：

```bash
10.66.0.1
```

学校 Flink 机器 WireGuard 内网 IP：

```bash
10.66.0.2
```

WireGuard UDP 端口：

```bash
51820
```

---

## 1. 先改阿里云安全组

在 Kafka 云服务器的安全组里：

保留 SSH：

```text
TCP 22
来源：你的管理 IP，或者暂时 0.0.0.0/0
```

开放 WireGuard：

```text
UDP 51820
来源：0.0.0.0/0
```

关闭公网 Kafka：

```text
删除或禁用 TCP 9094 来源 0.0.0.0/0
```

后面 Kafka 只通过 WireGuard 内网访问，不再公网开放 `9094`。

---

## 2. 云服务器安装 WireGuard

在 Kafka 云服务器上执行：

```bash
apt-get update
apt-get install -y wireguard
```

生成密钥：

```bash
mkdir -p /etc/wireguard
cd /etc/wireguard

umask 077
wg genkey | tee server_private.key | wg pubkey > server_public.key

cat server_private.key
cat server_public.key
```

记下：

```text
云服务器私钥：server_private.key
云服务器公钥：server_public.key
```

---

## 3. 学校 Flink 机器安装 WireGuard

在学校 Flink 机器上执行：

```bash
sudo apt-get update
sudo apt-get install -y wireguard
```

生成密钥：

```bash
sudo mkdir -p /etc/wireguard
cd /etc/wireguard

sudo sh -c 'umask 077 && wg genkey | tee client_private.key | wg pubkey > client_public.key'

sudo cat client_private.key
sudo cat client_public.key
```

记下：

```text
Flink 机器私钥：client_private.key
Flink 机器公钥：client_public.key
```

---

## 4. 配置云服务器 WireGuard

在云服务器上编辑：

```bash
nano /etc/wireguard/wg0.conf
```

写入：

```ini
[Interface]
Address = 10.66.0.1/24
ListenPort = 51820
PrivateKey = <云服务器私钥>

[Peer]
PublicKey = <Flink机器公钥>
AllowedIPs = 10.66.0.2/32
```

注意替换：

```text
<云服务器私钥>
<Flink机器公钥>
```

启动 WireGuard：

```bash
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
```

查看状态：

```bash
wg show
ip addr show wg0
```

应该能看到：

```text
10.66.0.1/24
```

---

## 5. 配置学校 Flink 机器 WireGuard

在学校 Flink 机器上编辑：

```bash
sudo nano /etc/wireguard/wg0.conf
```

写入：

```ini
[Interface]
Address = 10.66.0.2/24
PrivateKey = <Flink机器私钥>

[Peer]
PublicKey = <云服务器公钥>
Endpoint = 8.130.134.60:51820
AllowedIPs = 10.66.0.1/32
PersistentKeepalive = 25
```

注意替换：

```text
<Flink机器私钥>
<云服务器公钥>
```

启动：

```bash
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0
```

查看：

```bash
sudo wg show
ip addr show wg0
```

测试连通：

```bash
ping 10.66.0.1
```

如果 ping 通，WireGuard 隧道已经正常。

如果 ping 不通，在云服务器上看：

```bash
wg show
tcpdump -ni any udp port 51820
```

学校机器上也看：

```bash
sudo wg show
```

重点看 `latest handshake` 是否有时间。如果没有 handshake，通常是阿里云安全组没放行 UDP `51820`。

---

## 6. 修改 Kafka compose

在 Kafka 所在的 `violet-docker-compose.yaml` 里改 Kafka 服务。

推荐把 Kafka 的 `9094` 只绑定到 WireGuard 地址，不再绑定公网：

```yaml
kafka:
  image: apache/kafka:4.0.0
  hostname: kafka
  container_name: violet-kafka
  user: root
  ports:
    - "10.66.0.1:9094:9094"
  environment:
    KAFKA_NODE_ID: 1
    KAFKA_PROCESS_ROLES: "broker,controller"
    KAFKA_CONTROLLER_QUORUM_VOTERS: "1@kafka:9093"

    KAFKA_LISTENERS: "INTERNAL://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093,EXTERNAL://0.0.0.0:9094"
    KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: "INTERNAL:PLAINTEXT,CONTROLLER:PLAINTEXT,EXTERNAL:PLAINTEXT"
    KAFKA_CONTROLLER_LISTENER_NAMES: "CONTROLLER"
    KAFKA_INTER_BROKER_LISTENER_NAME: "INTERNAL"

    KAFKA_ADVERTISED_LISTENERS: "INTERNAL://kafka:9092,EXTERNAL://10.66.0.1:9094"

    KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
    KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS: 0
    KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 1
    KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1
    CLUSTER_ID: "SQiCluster"
    KAFKA_LOG_DIRS: "/var/lib/kafka/data"
    KAFKA_AUTO_CREATE_TOPICS_ENABLE: "true"
  volumes:
    - ~/violet/mnt/kafka/data:/var/lib/kafka/data
  networks:
    - violet-net
  healthcheck:
    test: ["CMD-SHELL", "/opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092 || exit 1"]
    interval: 30s
    timeout: 10s
    retries: 3
    start_period: 30s
```

关键是这两处：

```yaml
ports:
  - "10.66.0.1:9094:9094"
```

以及：

```yaml
KAFKA_ADVERTISED_LISTENERS: "INTERNAL://kafka:9092,EXTERNAL://10.66.0.1:9094"
```

注意：必须先启动 WireGuard，让云服务器上存在 `10.66.0.1` 这个网卡地址，再启动 Kafka。否则 Docker 可能会报无法绑定 `10.66.0.1:9094`。

重建 Kafka：

```bash
docker compose -f violet-docker-compose.yaml up -d --force-recreate kafka
```

检查监听：

```bash
ss -lntp | grep 9094 || true
docker port violet-kafka
```

你希望看到类似：

```text
10.66.0.1:9094
```

而不是：

```text
0.0.0.0:9094
```

---

## 7. 在学校 Flink 机器上测试 Kafka

先在宿主机上测试：

```bash
timeout 5 bash -c '</dev/tcp/10.66.0.1/9094' && echo kafka-wg-ok || echo kafka-wg-failed
```

如果宿主机成功，再测试 Flink 容器内部：

```bash
docker exec -it flink-jobmanager bash -lc '
timeout 5 bash -c "</dev/tcp/10.66.0.1/9094" && echo kafka-wg-ok || echo kafka-wg-failed
'
```

如果宿主机通，但 Flink 容器不通，通常是 Docker 容器到 `wg0` 的路由/转发问题。先执行：

```bash
sysctl net.ipv4.ip_forward
```

如果是 `0`，改成：

```bash
sudo sysctl -w net.ipv4.ip_forward=1
```

持久化：

```bash
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-wireguard-forward.conf
sudo sysctl --system
```

然后重新测试 Flink 容器。

---

## 8. 修改 Flink Job 的 Kafka 地址

你的 Flink 任务里 Kafka bootstrap servers 不要再写：

```text
8.130.134.60:9094
```

也不要写：

```text
kafka:9092
```

统一改成：

```text
10.66.0.1:9094
```

如果是 Java 代码里写死的，改类似：

```java
.setBootstrapServers("10.66.0.1:9094")
```

或者配置里：

```properties
kafka.bootstrap.servers=10.66.0.1:9094
```

然后强制 Flink 重新拉代码、重新构建 JAR。你之前的脚本可能会复用旧 JAR，所以建议直接删掉：

```bash
docker exec -it flink-jobmanager bash -lc '
rm -f /opt/flink/usrlib/trend-job.jar
rm -rf /opt/trend-repo
'
```

然后重建 Flink：

```bash
docker compose -f violet-data-docker-compose.yaml up -d --force-recreate jobmanager taskmanager
```

查看是否重新 clone / build：

```bash
docker logs -f flink-jobmanager
```

---

## 9. 验证 Flink 是否还报 `listNodes timeout`

看 Flink 日志：

```bash
docker logs -f flink-taskmanager
```

或者 Flink UI：

```text
http://学校机器IP:8082
```

如果 Kafka 连通正常，之前这个错误应该消失：

```text
Timed out waiting for a node assignment. Call: listNodes
```

如果还有这个错误，继续查三项：

第一，Flink 容器内是否能连：

```bash
docker exec -it flink-jobmanager bash -lc '
timeout 5 bash -c "</dev/tcp/10.66.0.1/9094" && echo ok || echo failed
'
```

第二，Kafka `advertised.listeners` 是否还是旧公网地址：

```bash
docker exec -it violet-kafka sh -lc '
echo "$KAFKA_ADVERTISED_LISTENERS"
'
```

应该是：

```text
INTERNAL://kafka:9092,EXTERNAL://10.66.0.1:9094
```

第三，Flink JAR 里是否还有旧地址。可以搜源码和构建目录：

```bash
docker exec -it flink-jobmanager bash -lc '
grep -RniE "8.130.134.60|kafka:9092|9094|bootstrap" /opt/trend-repo /opt/flink/usrlib 2>/dev/null | head -100
'
```

---

## 10. 验证 Kafka 不再暴露公网

在云服务器上看监听：

```bash
ss -lntp | grep 9094
```

理想情况：

```text
10.66.0.1:9094
```

如果还是：

```text
0.0.0.0:9094
```

说明端口仍然绑定所有网卡，需要检查 compose 的 `ports` 是否还是：

```yaml
- "9094:9094"
```

应该改成：

```yaml
- "10.66.0.1:9094:9094"
```

同时阿里云安全组不要开放公网 `9094`。

以后 Kafka 日志里类似这种扫描错误应该基本消失：

```text
InvalidReceiveException
Unexpected error from /45.33.109.18
```

---

## 11. 最终访问方式总结

云服务器本机 Docker 内部服务访问 Kafka：

```text
kafka:9092
```

学校 Flink 访问云服务器 Kafka：

```text
10.66.0.1:9094
```

公网不要访问 Kafka：

```text
8.130.134.60:9094
```

阿里云安全组只需要开放：

```text
UDP 51820
```

不需要开放：

```text
TCP 9094
```

---

学校公网 IP 变化不会再影响 Flink，因为 Flink 是通过 WireGuard 隧道访问 Kafka 的固定内网地址 `10.66.0.1:9094`。