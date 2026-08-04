# Route Deck

本地 Clash 配置管理器。React 编辑 Proxy、手动 Selector 与 Rule；Rust API 把配置持久化到 PostgreSQL，并输出 Clash 可直接订阅的 YAML。

## 目录

```text
.
├── apps/
│   ├── web/       React + Tailwind CSS + Zustand + daisyUI
│   └── api/       Axum + SQLx + PostgreSQL
├── clash.yaml     首次启动种子
├── turbo.json
└── pnpm-workspace.yaml
```

## 启动

依赖：Node.js 24、pnpm 10.12.4、Rust、Docker Desktop。

```bash
pnpm install
pnpm dev
```

`pnpm dev` 由 Turbo 并行启动前后端；API 会先等待 PostgreSQL 健康：

- Web：<http://127.0.0.1:5173>
- API：<http://127.0.0.1:3001>
- PostgreSQL：`localhost:54329`

若端口已占用，Vite 会打印实际 Web 地址。单独管理数据库：

```bash
pnpm db:up
pnpm db:down
```

`db:down` 不删除数据。

## 初始配置

API 首次启动时执行 migration，再把根目录 [`clash.yaml`](./clash.yaml) 写入 slug `zhuanzhuan`。种子记录只应用一次；之后删除配置或修改 slug，重启不会把它恢复。

默认订阅：

```text
http://127.0.0.1:3001/subscriptions/zhuanzhuan
```

Selector 输出固定为 Clash `type: select`。当前选中哪个代理属于 Clash 客户端运行状态，不存进配置。

## 验证

```bash
pnpm check
pnpm test
pnpm build

curl -fsS http://127.0.0.1:3001/health
curl -fsS http://127.0.0.1:3001/api/configs
curl -fsS http://127.0.0.1:3001/subscriptions/zhuanzhuan
```

API：

| Method | Path | 用途 |
| --- | --- | --- |
| `GET` | `/health` | 存活检查 |
| `GET` / `POST` | `/api/configs` | 列表、新建配置 |
| `GET` / `PUT` / `DELETE` | `/api/configs/{id}` | 查询、更新、删除配置 |
| `GET` | `/subscriptions/{slug}` | 返回裸 YAML 订阅 |

写入时后端会拒绝非法端口、未知或缺字段 Rule、Proxy 缺失必要端点、重复名称、空 Selector、非 `select` 组、悬空 Proxy/Selector/Rule 引用及 Selector 循环。

## 本地数据与环境变量

PostgreSQL 不是单文件数据库。Compose 把完整数据目录 bind mount 到项目根目录 `.data/postgres`；该目录已忽略，不会进入版本控制。

后端默认值见 [`apps/api/.env.example`](./apps/api/.env.example)：

- `DATABASE_URL`
- `BIND_ADDR`
- `CORS_ORIGIN`：允许访问 API 的 Web origin，默认 `http://127.0.0.1:5173`。
- `RUST_LOG`

前端可复制 [`apps/web/.env.example`](./apps/web/.env.example) 为 `.env.local`：

- `VITE_API_URL`：API origin；开发时留空，使用 Vite proxy。
- `VITE_SUBSCRIPTION_ORIGIN`：展示给 Clash 的公开 API origin。

API 没有用户认证，面向单机使用。保持 `BIND_ADDR` 与 PostgreSQL 端口绑定在 `127.0.0.1`；不要直接暴露到局域网或公网。

移动或重置数据前先停止数据库并保留可恢复副本：

```bash
pnpm db:down
mv .data/postgres ".data/postgres.backup-$(date +%Y%m%d-%H%M%S)"
pnpm db:up
curl -fsS http://127.0.0.1:3001/health
```
