# Docker Cybersecurity Homelab: Routed Choke Point, Zeek, and Arkime

A reproducible, **single-Ubuntu-VM** cybersecurity teaching lab. All seven containers have their own IP addresses. A gateway container routes test traffic between two isolated Docker subnets. `tcpdump` captures that traffic; **Zeek** creates JSON network logs; **Arkime** indexes the same PCAP into **OpenSearch** and makes individual sessions and packets searchable.

> **Verified result (19 October 2026):** 205 packets captured (0 dropped), Zeek `conn.log` created, Arkime indexed **101 sessions** and stored **201 packets** in a compressed PCAP, and a per-session PCAP successfully downloaded from the Arkime UI. The lab has **not** yet been configured for continuous Zeek/Arkime monitoring or Splunk ingestion. The manual procedure below reconstructs the successful commands; the Compose alternative is structurally checked but has **not** been run end-to-end in this chat.

## Network layout

```text
                       Ubuntu VM (Docker host)
   lab-left (10.10.1.0/24)                  lab-right (10.10.2.0/24)
       src 10.10.1.10 ----> gw <----> dst 10.10.2.10
                              10.10.1.1
                              10.10.2.1
                                 |
                          tcpdump at gw
                                 |
                            pcaps/*.pcap
                               /     \
                    Zeek offline    Arkime Capture offline
                      10.10.3.10         10.10.3.20
                          |                   |
                    zeek-logs/            OpenSearch
                                         10.10.3.40
                                              |
                                          Arkime Viewer
                                          10.10.3.21:8005

  Zeek, Arkime Capture/Viewer, and OpenSearch are on lab-tools (10.10.3.0/24).
  Splunk is not installed at this stage.
```

| Container | IP | Role |
|---|---|---|
| `gw` | `10.10.1.1`, `10.10.2.1` | IPv4 routing choke point |
| `src` | `10.10.1.10` | Traffic generator |
| `dst` | `10.10.2.10` | Scan target |
| `zeek` | `10.10.3.10` | Offline PCAP analysis and JSON logs |
| `arkime-capture` | `10.10.3.20` | Offline PCAP indexing and packet storage |
| `arkime-viewer` | `10.10.3.21` | Browser-based investigation |
| `opensearch` | `10.10.3.40` | Arkime indexing database |

**Requirements:** One Ubuntu 24.04 VM with Docker, approximately 4–6 vCPUs, preferably 12–16 GB RAM, and adequate SSD storage. Subnets must not conflict with networks already in use. In these examples **run commands from `~/homelab` unless otherwise noted**. The browser URLs are intended for Firefox **inside the Ubuntu VM**.

## A. Manual procedure (successful command sequence)

### 1. Install Docker and traffic tools; create lab folders

```bash
sudo apt update
sudo apt install -y docker.io tcpdump tcpreplay openssl
sudo systemctl enable --now docker
mkdir -p ~/homelab/{pcaps,zeek-logs}
cd ~/homelab
```

`-y` answers package prompts; `enable --now` starts Docker now and on boot. `pcaps/` stores network captures, `zeek-logs/` stores analysis results. The Ubuntu package's legacy-image-builder warning is **not a build failure**.

### 2. Create three internal networks with known subnets

```bash
sudo docker network create --internal \
  --subnet 10.10.1.0/24 --gateway 10.10.1.254 lab-left

sudo docker network create --internal \
  --subnet 10.10.2.0/24 --gateway 10.10.2.254 lab-right

sudo docker network create --internal \
  --subnet 10.10.3.0/24 --gateway 10.10.3.254 lab-tools
```

`--internal` prevents normal external routing; `--subnet` sets the address range; `--gateway` reserves the Docker bridge gateway address. **The bridge gateway `.254` is not our choke-point container `gw` (`.1`).** Distinct lab subnets are required.

### 3. Create and build the reusable endpoint image

```bash
cat > Dockerfile.lab <<'DOCKERFILE'
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y \
    --no-install-recommends \
    iproute2 iputils-ping nmap tcpreplay \
    && rm -rf /var/lib/apt/lists/*
CMD ["sleep", "infinity"]
DOCKERFILE

sudo docker build -f Dockerfile.lab -t homelab-node .
```

`-f` selects the Dockerfile; `-t` names the image; `.` supplies the current folder as build context. Packages provide routes, ping, Nmap, and PCAP replay. `sleep infinity` keeps utility containers available for `docker exec`.

### 4. Start gateway, source, and destination with fixed IPs

```bash
sudo docker run -d --name gw \
  --network lab-left --ip 10.10.1.1 \
  --sysctl net.ipv4.ip_forward=1 \
  homelab-node

sudo docker network connect \
  --ip 10.10.2.1 lab-right gw

sudo docker run -d --name src \
  --network lab-left --ip 10.10.1.10 \
  --cap-add NET_ADMIN \
  -v "$PWD/pcaps:/pcaps:ro" homelab-node

sudo docker run -d --name dst \
  --network lab-right --ip 10.10.2.10 \
  --cap-add NET_ADMIN homelab-node
```

`-d` runs detached; `--name` names a container; `--network`/`--ip` fix its address; `network connect` adds a **second** gateway interface; `--sysctl` enables IPv4 forwarding; `NET_ADMIN` lets endpoints add routes; `-v ...:ro` mounts captured PCAPs read-only.

**Order matters:** Create `gw` with `docker run` **before** `docker network connect`. Otherwise Docker reports `No such container: gw`.

### 5. Route test traffic through the gateway

```bash
sudo docker exec src ip route add 10.10.2.0/24 via 10.10.1.1
sudo docker exec dst ip route add 10.10.1.0/24 via 10.10.2.1
sudo docker exec src ping -c 3 10.10.2.10
```

`docker exec` runs inside an existing container; `via` names the next-hop gateway; `-c 3` sends three ping requests. The ping should succeed. Forward and return routes are both necessary.

### 6. Capture packets at the gateway (terminal 1)

```bash
cd ~/homelab
sudo docker exec gw ip -br addr
```

Confirm that **`eth0` has `10.10.1.1`** (and another interface has `10.10.2.1`). In the verified manual run, this was `eth0`. If your device names differ, substitute the interface carrying `10.10.1.1` below.

```bash
sudo nsenter -t "$(sudo docker inspect -f '{{.State.Pid}}' gw)" -n \
  tcpdump -i eth0 -s 0 \
  -w "$PWD/pcaps/session01.pcap"
```

`docker inspect` finds the gateway process ID; `nsenter -t ... -n` enters its network namespace; `-i` selects its interface; `-s 0` captures full packets; `-w` saves a PCAP. **Leave this terminal recording.** Running from `~/` instead of `~/homelab` would target the wrong output folder.

### 7. Generate test traffic (terminal 2)

```bash
sudo docker exec src nmap -sT -Pn -p 1-100 10.10.2.10
```

`-sT` requests TCP connect scanning; `-Pn` skips host discovery; `-p 1-100` probes destination ports 1 through 100. Return to **terminal 1** and press **Ctrl+C** to finish capturing.

### 8. Confirm the PCAP contains the scan

```bash
ls -lh ~/homelab/pcaps/session01.pcap
sudo tcpdump -nn -r ~/homelab/pcaps/session01.pcap | head
```

`-nn` skips hostname/port resolution; `-r` reads a saved PCAP; `head` displays the first ten lines. An occasional `Broken pipe` from `tcpdump | head` is expected. **Verified:** 205 captured packets and roughly a 16 KB file, with traffic between `10.10.1.10` and `10.10.2.10`.

### 9. Deploy Zeek and analyze the capture

```bash
cd ~/homelab
sudo docker run -d --name zeek \
  --network lab-tools --ip 10.10.3.10 \
  -v "$PWD/pcaps:/pcaps:ro" \
  -v "$PWD/zeek-logs:/logs" \
  zeek/zeek:lts sleep infinity

sudo docker exec zeek sh -c \
  'mkdir -p /logs/demo01 && cd /logs/demo01 && \
   zeek -C -r /pcaps/session01.pcap LogAscii::use_json=T'

ls -lh ~/homelab/zeek-logs/demo01/
```

`-C` tells Zeek to ignore invalid checksums (useful with captured/replayed test traffic); `-r` reads the PCAP; `LogAscii::use_json=T` writes newline-delimited JSON events. **Verified:** `conn.log` and `packet_filter.log` were created (the observed `conn.log` was 38 KB). **Zeek is not listening live**: this is offline processing.

### 10. Start OpenSearch for Arkime

```bash
sudo sysctl -w vm.max_map_count=262144
sudo docker volume create arkime-db

sudo docker run -d --name opensearch \
  --network lab-tools --ip 10.10.3.40 \
  -e "discovery.type=single-node" \
  -e "DISABLE_SECURITY_PLUGIN=true" \
  -e "DISABLE_INSTALL_DEMO_CONFIG=true" \
  -e "OPENSEARCH_JAVA_OPTS=-Xms1g -Xmx1g" \
  -v arkime-db:/usr/share/opensearch/data \
  --ulimit nofile=65536:65536 \
  opensearchproject/opensearch:2.19.4
```

`sysctl` increases Linux memory-map limits (not permanent across reboots); `docker volume` persists index data; `-e` sets container environment variables; `-Xms`/`-Xmx` fix Java's initial/maximum 1 GB heap; `--ulimit` raises open-file limits. Authentication is **disabled for this isolated teaching lab**; do not expose OpenSearch to untrusted networks.

```bash
sudo docker ps -a --filter name=opensearch
sudo docker logs --tail 30 opensearch
sudo docker exec opensearch curl -sS http://localhost:9200
free -h
```

`--filter` selects the container; `--tail` limits log output; `curl -sS` quietly requests the API but still displays errors; `free -h` displays host memory. **Wait a few minutes if necessary**: initially the API refused connections, then returned JSON with OpenSearch **2.19.4** and a healthy cluster.

### 11. Initialize Arkime's database (once per fresh database)

```bash
sudo docker run --rm \
  --network lab-tools \
  ghcr.io/arkime/arkime/arkime:v6-latest \
  /opt/arkime/db/db.pl --insecure \
  http://opensearch:9200 init
```

`--rm` removes the one-time container afterward; `init` creates Arkime's database indexes. `--insecure` relaxes TLS certificate verification (irrelevant to this HTTP endpoint, but matches the successful command). **Verified output:** `This is a fresh Arkime install` followed by `Creating` and `Finished`. **Never rerun `init` on a populated database**: it can erase existing Arkime records.

### 12. Create shared storage, secret, and Arkime configuration

```bash
cd ~/homelab
sudo docker volume create arkime-raw
mkdir -p arkime
openssl rand -hex 32 > arkime/password-secret
chmod 600 arkime/password-secret

cat > arkime/config.ini <<EOF_INI
[default]
elasticsearch=http://opensearch:9200
passwordSecret=$(cat arkime/password-secret)
authMode=digest
pcapDir=/opt/arkime/raw
viewHost=0.0.0.0
viewPort=8005
cronQueries=true
isLocalViewRegExp=^labcapture$
EOF_INI

chmod 600 arkime/config.ini
```

`openssl rand -hex 32` creates a random signing secret; `$(...)` inserts it in the configuration; `authMode=digest` enables Arkime login; `pcapDir` sets shared PCAP storage; `isLocalViewRegExp` tells Viewer that the `labcapture` node has locally accessible packet files. Protect `config.ini`: **it contains a secret**.

### 13. Start Arkime Viewer with the config mounted

```bash
sudo docker run -d --name arkime-viewer \
  --network lab-tools --ip 10.10.3.21 \
  -p 127.0.0.1:8005:8005 \
  -v "$PWD/arkime/config.ini:/opt/arkime/etc/config.ini:ro" \
  -v arkime-raw:/opt/arkime/raw \
  ghcr.io/arkime/arkime/arkime:v6-latest \
  /opt/arkime/bin/docker.sh viewer \
  --wait-for-db http://opensearch:9200

sudo docker logs --tail 20 arkime-viewer
```

`-p` attempts to bind the UI only to the Ubuntu host's loopback; it is **not necessary for host access by container IP**. `:ro` makes the config read-only; `--wait-for-db` waits for OpenSearch. **Verified:** Viewer started on port `8005`. With these `--internal` networks, **`http://localhost:8005` did not connect**, but direct access at **`http://10.10.3.21:8005` inside Ubuntu** worked.

### 14. Create the Arkime administrator

```bash
sudo docker exec -it arkime-viewer \
  /opt/arkime/bin/arkime_add_user.sh \
  admin "Admin User" - --admin
```

`-it` allows an interactive password prompt; `admin` is the username; `-` asks for a password; `--admin` grants administrator permissions. **Verified output:** `Added`. Open **http://10.10.3.21:8005** in the Ubuntu VM and sign in as **`admin`**. A previous attempt without `config.ini` failed; the mounted file fixes it.

### 15. Allow shared PCAP storage access; deploy Arkime Capture

```bash
sudo docker run --rm \
  -v arkime-raw:/opt/arkime/raw \
  --entrypoint sh \
  ghcr.io/arkime/arkime/arkime:v6-latest \
  -c 'chown nobody:daemon /opt/arkime/raw'

sudo docker run -d --name arkime-capture \
  --network lab-tools --ip 10.10.3.20 \
  -v "$PWD/arkime/config.ini:/opt/arkime/etc/config.ini:ro" \
  -v "$PWD/pcaps:/pcaps:ro" \
  -v arkime-raw:/opt/arkime/raw \
  ghcr.io/arkime/arkime/arkime:v6-latest \
  sleep infinity
```

`--entrypoint sh` starts a shell for the one-time ownership change; `chown` prepares writable shared storage for Arkime's configured user/group. Capture has a fixed IP and access to both the input PCAPs and shared Arkime packet storage. `sleep infinity` holds it ready for manual imports.

### 16. Import the PCAP into Arkime

```bash
sudo docker exec arkime-capture \
  /opt/arkime/bin/capture \
  -c /opt/arkime/etc/config.ini \
  -n labcapture \
  -r /pcaps/session01.pcap --copy
```

`-c` loads configuration; `-n` assigns the Arkime capture-node name; `-r` reads the saved file; `--copy` stores packets in Arkime's own `pcapDir`. **Verified:** 201 processed packets, 101 indexed sessions, zero packet drops. A transient `document_missing_exception` appeared during indexing but did **not** indicate a final failure, as verified in the next step.

### 17. Verify sessions, file metadata, packet storage, and UI

```bash
sudo docker exec opensearch curl -sS \
  'http://localhost:9200/arkime_sessions3-*/_count'

sudo docker exec opensearch curl -sS \
  'http://localhost:9200/arkime_files_v30/_search?pretty&size=5'

sudo docker exec arkime-capture ls -lah /opt/arkime/raw
```

`_count` returns indexed session count; `_search?...size=5` lists up to five packet-file records; `ls -lah` verifies actual files. **Verified:** **101 sessions**, indexed file record **`labcapture-101`**, and file **`labcapture-261019-00000101.pcap.zst`** under `/opt/arkime/raw/`. File IDs and names will change on new runs. The earlier query for `labcapture-0` returned `found: false` because that was **not** the final file ID.

In Firefox **inside Ubuntu**, visit **http://10.10.3.21:8005**, sign in as **`admin`**, go to **Sessions**, select **All (careful)**, and search. Expand a session; click **Download PCAP**. **Verified:** the downloaded two-packet TCP session was a valid-looking `.pcap` file of **184 bytes**, confirming Arkime can retrieve stored packets.

## B. Docker Compose alternative (fresh deployment)

> **Do not run Compose in parallel with the manual lab** on the same Docker host: the same subnets/IPs overlap and the original containers would conflict. Use a **fresh Ubuntu VM** for students, or first carefully migrate/retire the manual installation. Compose creates **new, project-scoped Docker networks and volumes** rather than automatically adopting the existing manual ones.

The companion [`compose.yaml`](compose.yaml) declares the **same seven services**, three isolated bridges, fixed container IPs, two persistent volumes, shared binds, the OpenSearch health check, and **automatic static-route configuration** for `src`/`dst`.

### B1. Prepare files on the clean VM

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-v2 tcpdump tcpreplay openssl
sudo systemctl enable --now docker
sudo sysctl -w vm.max_map_count=262144
mkdir -p ~/homelab/{pcaps,zeek-logs,arkime}
cd ~/homelab
```

Copy this repository's **`Dockerfile.lab`** and **`compose.yaml`** into `~/homelab/`. If you only have this README, create `Dockerfile.lab` using **Step 3**, then save the Compose code as `compose.yaml`. Generate **`arkime/password-secret`** and **`arkime/config.ini`** using **Step 12**. Those files must exist **before** starting the Arkime services.

Check the Compose configuration:

```bash
sudo docker compose config --quiet
```

`config --quiet` validates/interpolates Compose configuration without launching services. The Compose file's `build` section builds `homelab-node` automatically.

### B2. Start OpenSearch and the non-Viewer services

```bash
sudo docker compose up -d --build gw src dst zeek opensearch arkime-capture
sudo docker compose exec opensearch curl -sS http://localhost:9200
```

`up -d` starts services in the background; `--build` builds the custom endpoint image. Wait for OpenSearch to become healthy before proceeding. With Compose, **source/destination routes are added automatically at container startup**.

### B3. Initialize Arkime **once** on an empty database

```bash
sudo docker compose run --rm --no-deps arkime-viewer \
  /opt/arkime/db/db.pl --insecure http://opensearch:9200 init
```

`run --rm` starts a disposable Arkime container; `--no-deps` does not recreate dependencies. Do this **only for the first initialization** of a new database, before starting Viewer.

### B4. Prepare packet volume, start Viewer, and create an account

```bash
sudo docker compose run --rm --no-deps --entrypoint sh arkime-capture \
  -c 'chown nobody:daemon /opt/arkime/raw'

sudo docker compose up -d arkime-viewer

sudo docker compose exec arkime-viewer \
  /opt/arkime/bin/arkime_add_user.sh \
  admin "Admin User" - --admin
```

The first command fixes storage ownership; the second starts Viewer; the last prompts you to set the admin password.

### B5. Generate, capture, and import traffic

Check gateway interface addresses:

```bash
sudo docker compose exec gw ip -br addr
```

In **terminal 1**, from `~/homelab`, use the gateway process ID (the Compose service, not a fixed container name). Choose the interface with **`10.10.1.1`**; substitute for `eth0` if necessary:

```bash
sudo nsenter -t "$(sudo docker inspect -f '{{.State.Pid}}' "$(sudo docker compose ps -q gw)")" -n \
  tcpdump -i eth0 -s 0 -w "$PWD/pcaps/session01.pcap"
```

In **terminal 2**:

```bash
sudo docker compose exec src ping -c 3 10.10.2.10
sudo docker compose exec src nmap -sT -Pn -p 1-100 10.10.2.10
```

Stop `tcpdump` with **Ctrl+C** before processing the PCAP:

```bash
sudo docker compose exec zeek sh -c \
  'mkdir -p /logs/demo01 && cd /logs/demo01 && \
   zeek -C -r /pcaps/session01.pcap LogAscii::use_json=T'

sudo docker compose exec arkime-capture \
  /opt/arkime/bin/capture \
  -c /opt/arkime/etc/config.ini \
  -n labcapture -r /pcaps/session01.pcap --copy

sudo docker compose exec opensearch curl -sS \
  'http://localhost:9200/arkime_sessions3-*/_count'
```

Check the Zeek logs in `zeek-logs/demo01/`, then open **http://10.10.3.21:8005** in the Ubuntu VM and search Arkime Sessions with an **All** time range.

Stop the Compose lab without deleting its persistent data:

```bash
sudo docker compose down
```

`down` removes Compose containers and networks but **retains named volumes by default**. Do **not** use `down -v` unless you intentionally want to erase indexed Arkime/OpenSearch data.

## C. Key limitations and safe use

- **Not live sensor mirroring:** Zeek and Arkime process a PCAP **after** gateway capture. Simply sharing Docker's `lab-tools` bridge does not let them passively see all inter-container unicast traffic. Continuous analysis requires deliberate capture/streaming or traffic mirroring.
- **Not yet PCAP replay:** The first experiment created live Nmap traffic and captured it. Replaying that same traffic would add little. Importing an external PCAP **unchanged** is not guaranteed to traverse the gateway: Ethernet destination MAC addresses, IP addresses, routing, and expected replies can all differ.
- **Not a malware sandbox:** `--internal` and VM network isolation reduce reachability but do **not** provide absolute containment. Do not execute live malware or attach these subnets to a normal LAN without additional controlled egress and isolation safeguards.
- **No Splunk yet:** The successful workflow ends with Zeek JSON logs and an operational Arkime UI. Splunk forwarding/alerting is a later phase.
- **Lab-only security settings:** OpenSearch security is disabled and Arkime uses HTTP. Keep access limited to your isolated teaching VM/network. Unique passwords and stronger controls are needed beyond the lab.
- **Resource note:** OpenSearch's 1 GB Java heap consumes more than 1 GB total system RAM; the verified VM had approximately 15 GiB RAM. PCAP volume consumption grows with imports.

## D. Publish to GitHub without publishing secrets or packet captures

Place `README.md`, `compose.yaml`, and `Dockerfile.lab` in the repository. Create `.gitignore`:

```bash
cat > .gitignore <<'IGNORE'
arkime/config.ini
arkime/password-secret
pcaps/
zeek-logs/
IGNORE
```

Regenerate `arkime/config.ini` and `arkime/password-secret` using Step 12 on each new deployment. **Do not commit the signing secret**, even for a class demonstration.

## Official references

- [Docker Compose networking](https://docs.docker.com/compose/how-tos/networking/)
- [Docker Compose service specification](https://docs.docker.com/reference/compose-file/services/)
- [Zeek Quick Start and JSON logs](https://docs.zeek.org/en/current/tutorial/logs.html)
- [Arkime Docker installation](https://arkime.com/docker)
- [Arkime installation and user creation](https://arkime.com/install)
- [Arkime configuration reference](https://arkime.com/settings)
