# D1 Chain Simulator

> **EXERCISE.** The worker code (`central-worker/worker.py`, `models.py`) and the values that
> `infraestructura/compute.tf` passes to the worker's boot template are left for you to write.
> The worker machine is commented out (`compute.tf`, `outputs.tf`, `make up`), so `make up`
> deploys everything else meanwhile.
> Instructions (in Spanish): [`TO-DO.md`](TO-DO.md). Test it with `GUIA-DE-PRUEBA.pdf`.

Two stores, each sealed on its own network, forwarding their sales in batches to a
central site that consolidates them in MySQL and charts them.

---

## 1. What is new since fase 1

| Feature | Current |
|---|---|
| Stores | Two, fully independent |
| Networks | One per site, plus a simulated WAN |
| Sales data | Stays in the store | Forwarded to head office in batches |
| Central site | — | REST API + MySQL + dashboard, on AWS behind a load balancer |
| Containers | 6 | 15 locally (stores) + 5 services on AWS |
| Code layout | Flat layer modules | `core/` + one package per domain |

---

## 2. Quick start

There are two ways to run the system. **Cloud mode** is the default: the central site
runs on AWS and the two stores run on your machine. **Local mode** runs everything on
your machine and needs no AWS account.

### 2.1 Cloud mode: stores on your machine, central site on AWS

Prerequisites: Docker, Terraform (1.5 or newer), the AWS CLI, `curl`, and a running
AWS Academy Learner Lab session whose credentials are in `~/.aws/credentials`
(details in section 8.1).

```bash
# sample credentials for local use only
cp .env.example .env

# whole environment: runs the four pipelines (infrastructure, API, worker, dashboard;
# about 15-20 minutes the first time) and then starts the two stores on this machine,
# delivering to the central site. The order and every step: DEPLOY.md (in Spanish)
make up

# every local service should say "running"
make ps
```

The first step, `infraestructura/deploy.sh`, prints the two addresses of the central site:

```
Infraestructura lista. Las máquinas esperan sus imágenes en ECR.
  Dashboard: http://central-alb-1234567890.us-east-1.elb.amazonaws.com
  API:       http://central-alb-1234567890.us-east-1.elb.amazonaws.com:8000
```

Those are the addresses of the load balancer. They do not change while the site exists.
You can print them again at any time:

```bash
cd infraestructura
terraform output central_web_url     # the dashboard
terraform output central_api_url     # the API (add /docs for its interactive docs)
cat ../.env.cloud                    # the same API address, as the stores read it
```

| What | Address |
|---|---|
| **Store 1, register 1** | http://localhost:8081 |
| **Store 1, register 2** | http://localhost:8082 |
| **Store 2, register 1** | http://localhost:8083 |
| **Store 2, register 2** | http://localhost:8084 |
| **Head office dashboard** | the `central_web_url` above (opens in any browser, from any machine) |
| Central API | the `central_api_url` above, e.g. `<central_api_url>/health` and `<central_api_url>/docs` |
| Central database (MySQL, on AWS) | not public; reached through an SSH tunnel, see section 8.5 |
| Store 1 backend | http://localhost:18000/health · docs at `/docs` |
| Store 2 backend | http://localhost:18001/health · docs at `/docs` |
| Store 1 database | `localhost:55432` — PostgreSQL, user/db `store` |
| Store 2 database | `localhost:55433` — PostgreSQL, user/db `store` |

To shut everything down, including the AWS resources (which cost lab credit while they
exist):

```bash
make destroy
```

### 2.2 Local mode: everything on your machine

```bash
cp .env.example .env
make up-local  # docker compose --profile central up -d --build
make ps
```

The first `make up-local` takes a few minutes: it builds six images and initialises
three databases. Everything in the cloud-mode table applies, except that the central
site is local too:

| What | Address |
|---|---|
| **Head office dashboard** | http://localhost:8080 |
| Central API | http://localhost:18100/health · docs at `/docs` |
| Central database | `localhost:33306` — MySQL, user/db `central` |

The host ports avoid `5432`, `8000` and `3306` on purpose. Those are the three
most commonly occupied ports on a developer machine, and a first `make up-local` that
dies on `port is already allocated` looks like a broken exercise rather than a
local conflict. Change them in `.env` if you like. Tear local mode down with `make down`.

Run `make` with no arguments for the full list of commands.

---

## 3. Walkthrough: from a clean machine to a chart

Follow this in order the first time.

### 3.1 Ring up a sale

Open **http://localhost:8081**. You are now on store 1, register 1 — the header
says so, and it says it because *that register served the page*, not because the
page chose it.

Type a barcode from the seed catalog and press **Agregar**:

```
7702001010301    Arroz
7702354030014    Leche
```

(`make shell CONTAINER=store-1-postgres` [`docker compose exec store-1-postgres bash`] then `psql -U store -d store -c 'SELECT
ean, name, price FROM products;'` lists all 22.)

Press **Pagar**. The screen confirms the sale. Behind that one click:

1. the browser called the register, which proxied to store 1's web server;
2. the web server proxied `/api` to store 1's backend;
3. the backend **re-read the prices from its own database** and computed its own
   total — whatever the page displayed is not trusted as money;
4. the backend charged store 1's total at the payment gateway, out on the WAN;
5. only after approval did it write the sale, marked as *not yet forwarded*.

### 3.2 Watch the sale leave for head office

```bash
make logs CONTAINER=store-1-sync   # docker compose logs -f store-1-sync
```

Within a minute you will see the batch go out, and the line says **why**:

```
Sending 1 invoices to head office (age trigger, oldest invoice 61s old, 1 invoices queued)
Head office confirmed 1 new and 0 already held; 1 marked forwarded
```

That log line is the acceptance evidence for the batching rule. Press `Ctrl+C`
to stop following.

### 3.3 See it on the dashboard

Open the dashboard: the `central_web_url` printed by `make up` (cloud mode, see section 2.1) or **http://localhost:8080** (local mode). The first chart compares total sales per store in
Colombian pesos; the second ranks the ten best-selling products and can be
filtered to one store.

**Leave it open.** The dashboard refreshes itself every 10 seconds, so your sale
appears on its own once its batch lands — you do not need to reload. The header
shows the time of the last successful update, so you can tell a live page from a
frozen one. The **Actualizar** button is there for when you do not want to wait
out the interval.

Before the first batch arrives the dashboard says *"Aún no hay ventas
registradas"* rather than drawing an empty box. That is not a bug — see the next
section for why it takes up to a minute.

### 3.4 Compare the two stores

Open **http://localhost:8083** — store 2, register 1 — and ring up something
different. Within a minute the dashboard picks it up by itself: the two bars now
differ, and the top-products filter shows a different ranking per store.

### 3.5 Force a declined payment

The payment gateway declines any charge above `DECLINE_THRESHOLD`
(1 000 000 COP by default). Ring up enough units to cross it: the screen reports
the decline, **no sale is recorded**, and nothing is forwarded. The rule is
deterministic on purpose — a random decline would teach you to dismiss a real
failure as bad luck.

### 3.6 Look at the data directly

Store 1's own ledger, including the forwarding queue:

```bash
make shell CONTAINER=store-1-postgres   # docker compose exec store-1-postgres bash
psql -U store -d store

SELECT id, sale_date, total, register_id, forwarded_at FROM sales ORDER BY id;
SELECT * FROM sale_items WHERE sale_id = 1;
```

Head office's consolidated view. In **cloud mode** the database is on AWS and has no
public port: follow section 8.5 to open it, then run the same queries. In **local mode**:

```bash
make shell CONTAINER=central-mysql      # docker compose exec central-mysql bash
mysql -u central -pcentral_password central

SELECT * FROM stores;
SELECT id, store_id, store_invoice_id, register_id, sold_at, received_at, total FROM invoices;
SELECT ean, product_name, quantity, unit_price, subtotal FROM invoice_items;
```

Note `sold_at` and `received_at` are different columns: when the sale happened,
and when head office got it.

### 3.7 Run the tests

The environment must be up first — `make test` tests, it does not deploy. The tests run
inside `central-api`, so they need **local mode** (`make up-local`); they do not work against the AWS site.

```bash
make test   # docker compose exec ...
```

It runs the unit tests inside each service, the integration tests from a register
of each store (including the isolation checks below), the store-to-head-office
consolidation tests, and the resilience scenario. Budget about six minutes: the
consolidation tests genuinely wait out the batching timers.

### 3.8 Tear down

```bash
make destroy   # cloud mode: deletes the AWS site and its images, then every local container, volume and image
make down      # local mode (or local cleanup only)
```

**Destructive.** `make destroy` first deletes everything on AWS (`infraestructura/destroy.sh`)
and then runs `make down`, which removes all local containers, networks, volumes and
images, store databases included. Every recorded sale is lost and the seed data is
recreated on the next `make up` or `make up-local`.

---

## 4. How the sales reach head office

Every approved sale is written to its store's own `sales` table with
`forwarded_at` NULL. A per-store forwarder (`store-N-sync`) polls that queue and
ships batches to the central API.

**A batch goes out on whichever of these fires first:**

- **the count trigger** — `BATCH_SIZE` (default 10) invoices are queued; or
- **the age trigger** — the **oldest** queued invoice reaches
  `BATCH_MAX_AGE_SECONDS` (default 60).

The age is measured from the *oldest queued invoice*, never from the last batch.
That distinction is the whole rule. Anchored to the last send, a sale made 59
seconds after a batch would wait nearly two minutes; anchored to the oldest
invoice, nothing ever waits longer than the maximum wait plus one poll.

**So the honest worst case is 65 seconds**, not 60:
`BATCH_MAX_AGE_SECONDS` + `SYNC_POLL_SECONDS` (default 5). The poll interval is
the price of the age trigger's precision.

### Watching it without waiting a minute

Set a shorter wait in `.env` and restart the forwarders:

```bash
# .env
BATCH_MAX_AGE_SECONDS=10

docker compose up -d store-1-sync store-2-sync
make logs CONTAINER=store-1-sync   # docker compose logs -f store-1-sync
```

### What happens when head office is down

```bash
docker compose stop central-api          # head office goes away
```

Now ring up a few sales at http://localhost:8081. **They all succeed** — the
store does not depend on head office to sell. Watch the backlog build:

```bash
make shell CONTAINER=store-1-postgres   # docker compose exec store-1-postgres bash
psql -U store -d store -c 'SELECT id, total FROM sales WHERE forwarded_at IS NULL;'
```

The forwarder logs a warning each cycle and keeps everything queued. Bring head
office back:

```bash
docker compose start central-api
```

The backlog drains within a poll or two, and the same query returns no rows.

Nothing is double-counted on the way. Head office identifies an invoice by
`(store_id, store_invoice_id)` with a `UNIQUE` constraint, so a forwarder that
retries a batch whose response was lost gets back "already have these" rather
than creating a second copy. That is the failure that actually happens, and
without the constraint it would silently double a store's reported revenue while
the dashboard reported it with a straight face.

---

## 5. The networks

Four bridge networks. A container reaches only what shares a network with it.

| Service | Networks | Why |
|---|---|---|
| `store-N-register-1`, `store-N-register-2` | `store-N-net` | A register talks to its own store and nothing else |
| `store-N-frontend` | `store-N-net` | Serves the site; proxies `/api` to its own backend |
| `store-N-postgres` | `store-N-net` | Never reachable from outside its store |
| `store-N-backend` | `store-N-net` + `wan-net` | The store's **only payment egress** |
| `store-N-sync` | `store-N-net` + `wan-net` | The store's **only data egress** |
| `central-mysql`, `central-web` | `central-net` | Behind the API |
| `central-api` | `central-net` + `wan-net` | The **only way into** head office |
| `payment-gateway` | `wan-net` | Belongs to no site: a third party |

`architecture.drawio` draws this. See section 7.

### Reachability matrix

Use this to tell an intended isolation apart from a broken environment.

| From | To | Expected | Why |
|---|---|---|---|
| `store-1-register-1` | `store-1-backend` | ✅ works | Same store network |
| `store-1-register-1` | `store-1-frontend` | ✅ works | Same store network |
| `store-1-register-1` | `payment-gateway` | ❌ fails | Gateway is on `wan-net`; the register is not |
| `store-1-register-1` | `central-api` | ❌ fails | Head office is reached by the forwarder, never a register |
| `store-1-register-1` | `central-mysql` | ❌ name does not resolve | Different network entirely |
| `store-1-register-1` | `store-2-backend` | ❌ fails | Separate sites, separate networks |
| `store-1-backend` | `payment-gateway` | ✅ works | Both on `wan-net` — this is the payment path |
| `store-1-sync` | `central-api` | ✅ works | Both on `wan-net` — this is the consolidation path |
| `store-1-sync` | `central-mysql` | ❌ name does not resolve | The API is the only way in |
| `payment-gateway` | `store-1-postgres` | ❌ name does not resolve | The gateway is nobody's neighbour |

Check any row yourself:

```bash
make shell CONTAINER=store-1-register-1   # docker compose exec store-1-register-1 bash
curl -m 5 http://store-1-backend:8000/health     # 200
curl -m 5 http://payment-gateway:5000/health     # fails, and should
getent hosts central-mysql                       # nothing, and should be nothing
```

### Why the registers still have internet access

The store networks are *not* marked `internal: true`, even though sealing them
would also cut internet egress and make the isolation stricter.

**Docker will not publish a host port for a container attached only to internal
networks.** It accepts the `ports:` entry, starts the container, reports it
healthy — and silently creates no mapping. We hit exactly that: the registers
served the site perfectly on port 80 inside their own containers and were simply
unreachable from the browser, with nothing logged. Since going through a register
is the only way into a store's web site, reachable registers won.

What that costs is one guarantee: a register can still reach the internet, as it
could in fase 1. Everything else the segmentation was for is intact and tested —
the gateway, head office, the central database and the other store are all
unreachable from a register.

### `wan-net` is a shared internet, not a private link

Store 1's forwarder *can* reach store 2's backend across it. That is realistic —
they are both on the internet — and not worth preventing with topology. In a real
deployment TLS and authentication, not network layout, would be what keeps them
apart.

---

## 6. How the code is organised

Every Python service follows the layout of
[`practice3/redis_with_api`](../../0_linux_docker_introduction/practice3/redis_with_api/),
which you have already read in this course: a shared `core/` package for
infrastructure, plus **one package per business concern** rather than one package
per layer.

```
backend/app/
  main.py            assembly only: create the app, include every router
  core/
    config.py        the ONLY module that reads the environment
    base.py          the declarative base (kept apart from the engine)
    database.py      the engine, the session provider
    logging.py       configured once, stamped with the store id
    router.py        /health
  products/          models · schemas · repository · service · router · tests/
  sales/             models · schemas · repository · service · router · tests/
  payments/          schemas · gateway_client · service · router · tests/
```

`central-api/` is the same shape with `stores/`, `ingestion/` and `reports/`;
`payment-gateway/` with `charges/`; `sync/` with `forwarding/` (and no `router.py`,
because a worker has no HTTP surface).

Within a package the dependency direction is fixed: **router → service →
repository**. A router never builds a query; a service never imports an HTTP type,
which is what lets it be unit tested by calling a function. Packages meet each
other at the *service* level, never by reaching into another package's repository.

Want to change how a sale is recorded? Everything about sales is in `sales/`.

---

## 7. Diagrams

> The diagrams show the all-local mode. With the central site on AWS (section 8), the five `central-*` boxes
> move to AWS and the forwarders reach `central-api` over the internet instead of `wan-net` alone.

### Editable: `architecture.drawio.xml`

The full architecture, committed as **uncompressed XML** so it diffs as text
rather than as a base64 blob. To open it:

1. go to **https://app.diagrams.net**
2. choose **Open Existing Diagram**
3. select `architecture.drawio.xml` from this directory

It loads editable, with no import step. It shows every container in the networks
it belongs to, the services drawn across a boundary because they straddle two,
every flow, and the published host ports. If you change a service's network or
port, update this file in the same commit.

### Inline: a sale, from the register to the dashboard

El diagrama de secuencia ha sido movido a `architecture.drawio.xml` (pestaña "Secuencia").

---

## 8. Running the central site on AWS (Learner Lab)

By default everything runs on your machine. This section moves the **central site**
(`central-mysql`, `central-rabbitmq`, `central-api`, `central-worker`, `central-web`) to
EC2 machines on AWS Academy, while the two stores keep running locally and deliver their
sales to the cloud.

Deployment is split into **four independent pipelines**, one per folder, as if each folder
were its own repository with its own CI: `infraestructura/deploy.sh` (Terraform: network,
balancer, machines, ECR repositories; no code), and `central-api/deploy.sh`,
`central-worker/deploy.sh`, `central-web/deploy.sh` (build an image, test it, push it to
ECR, move the `current` tag and roll it out). **[`DEPLOY.md`](DEPLOY.md) (Spanish) is the
runbook**: the order and why, every command, the stages of a pipeline and common
situations. [`infraestructura/HOW-IT-WORKS.md`](infraestructura/HOW-IT-WORKS.md) (Spanish)
explains how the code reaches a container. Every line of Terraform, of the templates and
of the pipelines carries a comment, in Spanish.

### 8.1 Prerequisites

- A running **AWS Academy Learner Lab** session (green dot). In *AWS Details* copy the
  credentials into `~/.aws/credentials`. They expire when the session ends, so repeat
  this every time you start the lab.
- `terraform` (1.5 or newer), `aws` (CLI v2) and `curl` installed locally.
- Docker, as for the rest of this project (the pipelines build the images on your machine).

### 8.2 Commands

```bash
make up        # whole environment: the four pipelines in order, then the two stores locally
make destroy   # whole environment: delete the AWS site and its images, then every local container, volume and image
```

| Command | What it does |
|---|---|
| `make infra` | Only the infrastructure pipeline |
| `make deploy-api` / `deploy-worker` / `deploy-web` | Only that service's pipeline |
| `make up-stores` | Only the stores, using the address in `.env.cloud` |
| `make destroy-aws` | Only the AWS deletion (`infraestructura/destroy.sh`) |
| `make down` | Only the local cleanup |
| `make up-local` | The original all-local mode, with no AWS at all |

`make destroy` runs `infraestructura/destroy.sh` first and then `make down`, which removes
**all** local containers, images, networks and volumes (both store databases included). If
the AWS step fails, for example because the lab credentials expired, it stops and deletes
nothing locally. If no Terraform state exists it skips the AWS step.

### 8.3 What is created

Browsers and the stores reach the central site through **one Application Load Balancer**:
port 80 goes to the dashboard, port 8000 to the API. Behind it, the API and the dashboard
each run in an **Auto Scaling group** (minimum 1, desired 1, **maximum 2**). A CPU target of
60 % adds the second machine under load and removes it afterwards. MySQL, RabbitMQ and the
worker are one machine each. Three **ECR repositories** (`central-api`, `central-worker`,
`central-web`) hold the images; the tag `current` marks the version the machines run.

| Machine | Reachable from | Port |
|---|---|---|
| load balancer | anywhere | 80, 8000 |
| `central-web` (1-2 machines) | the load balancer only | 80 |
| `central-api` (1-2 machines) | the load balancer only | 8000 |
| `central-worker` | nobody | — |
| `central-rabbitmq` | `central-api`, `central-worker` | 5672 |
| `central-mysql` | `central-api`, `central-worker` | 3306 |

SSH (22) is open to `ssh_cidr` (default: anywhere; narrow it in `terraform.tfvars`). The
address of the load balancer is stable, so `.env.cloud` stays valid. Each machine installs
Docker, pulls `<service>:current` from ECR and starts its container; read
`/var/log/central-bootstrap.log` on a machine to follow it, and
`/var/log/central-update.log` for later updates.

Useful commands:

```bash
# MySQL, RabbitMQ and the worker (their IP changes when the lab stops and starts them,
# so ask AWS; `terraform output ssh_addresses` can show an old one)
aws ec2 describe-instances --filters Name=tag:Name,Values=central-mysql Name=instance-state-name,Values=running --query 'Reservations[].Instances[].PublicIpAddress' --output text

# API and dashboard machines come and go with the Auto Scaling groups
aws ec2 describe-instances --filters Name=tag:Name,Values=central-api Name=instance-state-name,Values=running --query 'Reservations[].Instances[].PublicIpAddress' --output text

# SSH into a machine
ssh -i ~/.ssh/labsuser.pem ec2-user@<address>

# RabbitMQ management UI through an SSH tunnel, then open http://localhost:15672
ssh -i ~/.ssh/labsuser.pem -L 15672:localhost:15672 ec2-user@<rabbitmq address>

# Image versions of a service, and which one is current
aws ecr describe-images --repository-name central-api --query 'imageDetails[].[imageTags,imagePushedAt]' --output text

# Watch the groups and the balancer's view of them
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names central-api central-web --query 'AutoScalingGroups[].[AutoScalingGroupName,DesiredCapacity,length(Instances)]'
```

After editing central code, run only that service's pipeline. The API and dashboard
pipelines terminate their group's machines and the group launches new ones that pull the new
image, so the service is down for a few minutes (accepted in this introductory course: the
stores keep their sales and retry; the lab does not allow AWS *instance refresh*); the worker pipeline tells its machine, through SSM, to pull the new image. A failed
check rolls back to the previous image automatically. MySQL and RabbitMQ are never
replaced, so their data survives.

### 8.4 Opening the dashboard and the API

```bash
cd infraestructura
terraform output central_web_url     # open this in a browser: the dashboard
terraform output central_api_url     # add /health or /docs to try the API
```

If you no longer have the `terraform output` (for example in a new shell), the same API
address is in `.env.cloud` at the project root, and the load balancer's DNS name is also
shown in the AWS console under *EC2 → Load Balancers → central-alb*.

A machine that has just been created needs a few minutes to build its image. If the
dashboard answers `502 Bad Gateway` right after a deploy, wait a minute and reload.

### 8.5 Reading the central MySQL database on AWS

The database machine accepts MySQL connections only from the API and the worker, so you
cannot connect to it directly from your computer. You reach it through an **SSH tunnel**:
SSH is open, and the MySQL container publishes port 3306 on the machine itself.

1. Get the key. In the Learner Lab, open *AWS Details* and press *Download PEM*; save it
   as `~/.ssh/labsuser.pem` and run `chmod 400 ~/.ssh/labsuser.pem`.
2. Find the database machine's current public address. Ask AWS rather than Terraform:
   MySQL, RabbitMQ and the worker have no fixed IP, so it changes whenever the lab stops and
   starts the machines, and `terraform output` would still show the old one.

   ```bash
   aws ec2 describe-instances --filters Name=tag:Name,Values=central-mysql Name=instance-state-name,Values=running --query 'Reservations[].Instances[].PublicIpAddress' --output text
   ```

3. Open the tunnel (leave this terminal open). Local port 3307 avoids clashing with a
   MySQL you may already run locally:

   ```bash
   ssh -i ~/.ssh/labsuser.pem -L 3307:127.0.0.1:3306 ec2-user@<mysql address>
   ```

4. In **another terminal** connect through it. The credentials are the same defaults as in
   local mode (`mysql_user` and `mysql_password` in `infraestructura/variables.tf`):

   ```bash
   mysql -h 127.0.0.1 -P 3307 -u central -pcentral_password central
   ```

   or use a graphical client (DBeaver, MySQL Workbench) with host `127.0.0.1`, port `3307`,
   user `central`, password `central_password`, database `central`.

Then run the queries from section 3.6:

```sql
SELECT * FROM stores;
SELECT id, store_id, store_invoice_id, register_id, sold_at, received_at, total FROM invoices;
SELECT ean, product_name, quantity, unit_price, subtotal FROM invoice_items;
```

Without a local `mysql` client, run it on the machine itself:

```bash
ssh -t -i ~/.ssh/labsuser.pem ec2-user@<mysql address> "sudo docker exec -it central-mysql mysql -ucentral -pcentral_password central"
```

The same tunnel
idea reaches RabbitMQ's management page: `-L 15672:127.0.0.1:15672` to the RabbitMQ
machine, then http://localhost:15672.

### 8.6 Limits

- **A new API or dashboard machine takes 2-3 minutes** to install Docker and pull its image, so scale-out is not instant. A code deploy of the API or dashboard leaves it down for a few minutes while the replacement boots.
- **Machines are placed only in zones that offer the instance type** (not `us-east-1e` for `t3.micro`).
- **1 GB of RAM per machine.** MySQL 8.4 and RabbitMQ are tight; each machine gets a 1 GB
  swap file and MySQL a small buffer pool. If one struggles, set
  `instance_type = "t3.small"` in `terraform.tfvars`.
- **Plain HTTP.** Sales cross the internet without TLS.
- **Class-grade secrets.** The passwords are the same defaults as local mode and are
  visible in the machines' user data. Change them first in any real system.
- **Local Terraform state.** Keep `infraestructura/terraform.tfstate` until you have
  destroyed. The ECR repositories are created by the AWS CLI, not Terraform, and
  `destroy.sh` deletes them by name. If you lose it, find leftovers with
  `aws ec2 describe-instances --filters Name=tag:Project,Values=d1-chain`.
- **Stopping the lab keeps your data; `destroy.sh` deletes it.**
- In stores-only mode the central containers do not exist locally, so `make test` (which
  runs tests inside `central-api`) needs `make up-local`.

## 9. Known limitations

These are deliberate, and worth discussing rather than fixing.

- **No authentication between store and head office.** A forwarder posts to the
  central API over plain HTTP with no credentials. Any container on `wan-net`
  could do the same. A real deployment would use TLS and a per-store credential;
  here, topology is doing a job that topology should not be doing alone.
- **The registers keep internet access.** See section 5 for why, and for what
  that does and does not cost.
- **Both stores build from the same directories.** Editing `backend/app/` changes
  *both* stores — that is intended (one chain, one piece of software), but it
  surprises people who thought they were experimenting on store 1 alone.
- **The declared memory limits are ceilings, not reservations.** `docker-compose.yml`
  declares 8 GB for each store database. Adding those up gives a number no laptop
  has; it does not mean the exercise needs it. A container takes what it uses, and
  idle containers use almost nothing. The exercise starts fine on 8 or 16 GB.
- **A sale takes up to 65 seconds to appear on the dashboard.** By design, not by
  accident — it is the forwarding delay, not the dashboard being slow. The
  dashboard itself polls every 10 seconds, which is well inside that window. See
  section 4.

- **The dashboard polls; it is not pushed to.** Head office has no way to notify
  an open browser that a batch arrived, so the page asks every 10 seconds. At
  classroom volume that is two small aggregate queries and costs nothing; a real
  chain with hundreds of stores would want server-sent events or websockets
  instead.
- **The database ports are published with sample credentials.** Fine for a local
  practice environment, and nowhere else.
- **A charge could exist with no recorded sale.** If a backend died between the
  gateway approving and the sale committing, the customer is charged and the store
  has no record. Solving that (idempotency keys, an outbox on the payment side
  too) is out of scope. Worth discussing: how would you detect it? How would you
  reconcile it?
- **No inventory, no stock control, no product images, no refunds, no discounts.**
  Excluded since fase 1.
- **Clock skew between stores is not handled.** Head office stores both the
  store's `sold_at` and its own `received_at`, so a discrepancy is at least
  visible rather than invisible.

---

## 10. Command reference

| Command (`make`) | Equivalent (`docker compose`) | What it does |
|---|---|---|
| `make` | — | Show every command with its addresses |
| `make up` (o `make start`) | the four `deploy.sh` pipelines in order + `make up-stores` | Bring up the whole environment: central site on AWS, stores locally delivering to it |
| `make infra` | `infraestructura/deploy.sh` | Infrastructure pipeline only |
| `make deploy-api` / `deploy-worker` / `deploy-web` | `central-api/deploy.sh` etc. | One service's pipeline only |
| `make up-local` | `docker compose --profile central up -d --build` | Build and start everything locally, central site included |
| `make up-stores` | `docker compose --env-file .env --env-file .env.cloud up -d --build` | Start only the stores, delivering to the central site on AWS (run `make infra` first) |
| `make down` | `docker compose --profile central down --rmi all -v --remove-orphans` | **Destructive.** Remove local containers, images, networks and volumes |
| `make destroy` | `infraestructura/destroy.sh` + `make down` | **Destructive.** Delete the AWS site and its ECR images, then everything local |
| `make ps` | `docker compose ps` | State of every service |
| `make logs` | `docker compose logs -f` | Follow every service's logs |
| `make logs CONTAINER=store-1-sync` | `docker compose logs -f store-1-sync` | Follow one service — use this for the batching |
| `make shell CONTAINER=<name>` (o `make exec`) | `docker compose exec <name> bash` | Interactive shell inside a container |
| `make test` | *(Ejecuta pruebas unitarias e integración en contenedores)* | Unit + integration + consolidation + resilience |
| `make test-unit` | `docker compose exec -T <service> python -m pytest app -q` | Only the unit tests, inside each service container |
| `make test-integration` | `docker compose exec -T <register> python integration_tests.py` | Only the integration tests |

`start`, `destroy` and `exec` are aliases for `up`, `down` and `shell`.
