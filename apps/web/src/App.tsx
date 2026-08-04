import { useEffect, useMemo, useRef, useState } from "react";
import type { KeyboardEvent, RefObject } from "react";
import { getSubscriptionUrl } from "./api";
import { moveItem, renameRouteTarget } from "./config";
import { useConfigStore } from "./store";
import type {
  ClashDocument,
  ClashProxy,
  ConfigDraft,
  SelectorGroup,
} from "./types";

const PROXY_TYPES = ["http", "socks5"];
const BUILTIN_TARGETS = ["DIRECT", "REJECT", "REJECT-DROP", "PASS"];

function nextName(prefix: string, names: string[]): string {
  let index = names.length + 1;
  while (names.includes(`${prefix}-${index}`)) index += 1;
  return `${prefix}-${index}`;
}

function unique(values: string[]): string[] {
  return [...new Set(values.filter(Boolean))];
}

interface SectionHeadingProps {
  step: string;
  title: string;
  description: string;
  count: number;
  onAdd: () => void;
  addLabel: string;
}

function SectionHeading({
  step,
  title,
  description,
  count,
  onAdd,
  addLabel,
}: SectionHeadingProps) {
  return (
    <div className="flex flex-col gap-4 border-b border-base-300 pb-5 sm:flex-row sm:items-end sm:justify-between">
      <div>
        <div className="data-type mb-2 text-xs tracking-[0.2em] text-accent uppercase">
          {step} · {count.toString().padStart(2, "0")}
        </div>
        <h2 className="display-type text-3xl font-semibold tracking-tight">
          {title}
        </h2>
        <p className="mt-1 max-w-2xl text-sm text-base-content/70">
          {description}
        </p>
      </div>
      <button type="button" className="btn btn-sm" onClick={onAdd}>
        {addLabel}
      </button>
    </div>
  );
}

interface SidebarProps {
  configs: ReturnType<typeof useConfigStore.getState>["configs"];
  activeId: number | null;
  dirty: boolean;
  busy: boolean;
  modalOpen: boolean;
  closeButtonRef: RefObject<HTMLButtonElement | null>;
  onSelect: (id: number) => void;
  onNew: () => void;
  onClose: () => void;
}

function Sidebar({
  configs,
  activeId,
  dirty,
  busy,
  modalOpen,
  closeButtonRef,
  onSelect,
  onNew,
  onClose,
}: SidebarProps) {
  const trapFocus = (event: KeyboardEvent<HTMLElement>) => {
    if (!modalOpen) return;
    if (event.key === "Escape") {
      event.preventDefault();
      onClose();
      return;
    }
    if (event.key !== "Tab") return;

    const focusable = Array.from(
      event.currentTarget.querySelectorAll<HTMLElement>(
        'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
      ),
    ).filter((element) => element.getClientRects().length > 0);
    const first = focusable[0];
    const last = focusable.at(-1);
    if (!first || !last) return;

    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  };

  return (
    <aside
      id="config-sidebar"
      role={modalOpen ? "dialog" : undefined}
      aria-modal={modalOpen || undefined}
      aria-label={modalOpen ? "配置文件列表" : undefined}
      onKeyDown={trapFocus}
      className="min-h-full w-80 border-r border-base-100 bg-base-300 p-5 text-base-content"
    >
      <div className="mb-8 flex items-center justify-between gap-3">
        <div>
          <div className="display-type text-xl font-semibold tracking-wide">
            Route Deck
          </div>
          <div className="data-type text-[0.65rem] tracking-[0.16em] text-base-content/70 uppercase">
            Clash patch panel
          </div>
        </div>
        <div className="flex items-center gap-2">
          <span className="badge badge-outline badge-sm">Frappe</span>
          <button
            ref={closeButtonRef}
            type="button"
            className="btn btn-ghost btn-square btn-sm lg:hidden"
            aria-label="关闭配置列表"
            onClick={onClose}
          >
            ×
          </button>
        </div>
      </div>

      <div className="mb-3 flex items-center justify-between">
        <h2 className="text-xs font-semibold tracking-[0.14em] text-base-content/70 uppercase">
          配置文件
        </h2>
        <button
          type="button"
          className="btn btn-ghost btn-xs"
          disabled={busy}
          onClick={onNew}
        >
          新建
        </button>
      </div>

      <nav aria-label="配置文件列表" className="space-y-2">
        {configs.map((config) => {
          const active = config.id === activeId;
          return (
            <button
              key={config.id}
              type="button"
              className={`w-full rounded-box border p-3 text-left transition-colors ${
                active
                  ? "border-accent/40 bg-base-200"
                  : "border-transparent hover:border-base-100 hover:bg-base-200/55"
              }`}
              aria-current={active ? "page" : undefined}
              disabled={busy}
              onClick={() => onSelect(config.id)}
            >
              <span className="flex items-center gap-2">
                <span
                  className={`size-2 rounded-full ${
                    active ? "bg-accent" : "bg-neutral"
                  }`}
                />
                <span className="min-w-0 flex-1 truncate text-sm font-medium">
                  {config.name}
                </span>
                {active && dirty ? (
                  <span className="text-warning" aria-label="有未保存修改">
                    ●
                  </span>
                ) : null}
              </span>
              <span className="data-type mt-1 block truncate pl-4 text-[0.68rem] text-base-content/70">
                /{config.slug}
              </span>
            </button>
          );
        })}
      </nav>

      <div className="mt-8 border-t border-base-100 pt-4 text-xs leading-5 text-base-content/70">
        Selector 只定义可选出口。当前选中项由 Clash 客户端管理。
      </div>
    </aside>
  );
}

interface RuntimePanelProps {
  document: ClashDocument;
  onChange: (document: ClashDocument) => void;
}

function RuntimePanel({ document, onChange }: RuntimePanelProps) {
  const patch = (next: Partial<ClashDocument>) =>
    onChange({ ...document, ...next });

  return (
    <section className="card card-border bg-base-200">
      <div className="card-body gap-5 p-5">
        <div className="flex items-center justify-between gap-4">
          <div>
            <h2 className="font-semibold">运行参数</h2>
            <p className="text-xs text-base-content/70">
              保留初始配置端口、模式与日志级别。
            </p>
          </div>
          <span className="badge badge-ghost badge-sm">runtime</span>
        </div>
        <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <label className="grid gap-2 text-xs text-base-content/70">
            Mixed port
            <input
              className="input input-sm w-full text-base-content"
              type="number"
              min="1"
              max="65535"
              value={document["mixed-port"] ?? 7890}
              onChange={(event) =>
                patch({ "mixed-port": Number(event.target.value) })
              }
            />
          </label>
          <label className="grid gap-2 text-xs text-base-content/70">
            Mode
            <select
              className="select select-sm w-full text-base-content"
              value={document.mode ?? "rule"}
              onChange={(event) => patch({ mode: event.target.value })}
            >
              <option value="rule">rule</option>
              <option value="global">global</option>
              <option value="direct">direct</option>
            </select>
          </label>
          <label className="grid gap-2 text-xs text-base-content/70">
            Log level
            <select
              className="select select-sm w-full text-base-content"
              value={document["log-level"] ?? "info"}
              onChange={(event) => patch({ "log-level": event.target.value })}
            >
              <option value="silent">silent</option>
              <option value="error">error</option>
              <option value="warning">warning</option>
              <option value="info">info</option>
              <option value="debug">debug</option>
            </select>
          </label>
          <label className="flex min-h-12 items-center gap-3 self-end rounded-field border border-base-300 px-3 text-sm">
            <input
              type="checkbox"
              className="size-4 accent-accent"
              checked={document["allow-lan"] ?? false}
              onChange={(event) => patch({ "allow-lan": event.target.checked })}
            />
            允许局域网连接
          </label>
        </div>
      </div>
    </section>
  );
}

interface ProxyPanelProps {
  document: ClashDocument;
  onChange: (document: ClashDocument) => void;
}

function ProxyPanel({ document, onChange }: ProxyPanelProps) {
  const updateProxy = (index: number, patch: Partial<ClashProxy>) => {
    const proxies = document.proxies.map((proxy, proxyIndex) =>
      proxyIndex === index ? { ...proxy, ...patch } : proxy,
    );
    onChange({ ...document, proxies });
  };

  const renameProxy = (index: number, name: string) => {
    const previous = document.proxies[index].name;
    const renamed = renameRouteTarget(document, previous, name);
    const proxies = renamed.proxies.map((proxy, proxyIndex) =>
      proxyIndex === index ? { ...proxy, name } : proxy,
    );
    onChange({ ...renamed, proxies });
  };

  const removeProxy = (index: number) => {
    const removedName = document.proxies[index].name;
    onChange({
      ...document,
      proxies: document.proxies.filter((_, proxyIndex) => proxyIndex !== index),
      "proxy-groups": document["proxy-groups"].map((group) => ({
        ...group,
        proxies: group.proxies.filter((member) => member !== removedName),
      })),
    });
  };

  const addProxy = () => {
    const name = nextName(
      "proxy",
      document.proxies.map((proxy) => proxy.name),
    );
    onChange({
      ...document,
      proxies: [
        ...document.proxies,
        { name, type: "http", server: "", port: 8080 },
      ],
    });
  };

  return (
    <section className="card card-border bg-base-200">
      <div className="card-body gap-6 p-5 sm:p-7">
        <SectionHeading
          step="01"
          title="Proxy 出口"
          description="定义 Clash 能连接的代理端点。重命名会同步 Selector 与规则引用。"
          count={document.proxies.length}
          onAdd={addProxy}
          addLabel="添加 Proxy"
        />

        {document.proxies.length === 0 ? (
          <div className="rounded-box border border-dashed border-base-300 p-8 text-center text-sm text-base-content/70">
            还没有代理出口。添加一个，再接入 Selector。
          </div>
        ) : (
          <div className="space-y-4">
            {document.proxies.map((proxy, index) => (
              <article
                key={index}
                className="rounded-box border border-base-300 bg-base-100/45 p-4"
              >
                <div className="mb-4 flex items-center justify-between gap-3">
                  <div className="flex items-center gap-3">
                    <span className="data-type text-xs text-base-content/70">
                      P{(index + 1).toString().padStart(2, "0")}
                    </span>
                    <span className="badge badge-outline badge-sm">
                      {proxy.type}
                    </span>
                  </div>
                  <button
                    type="button"
                    className="btn btn-ghost btn-xs text-error"
                    aria-label={`删除代理 ${proxy.name}`}
                    onClick={() => removeProxy(index)}
                  >
                    删除
                  </button>
                </div>
                <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-6">
                  <label className="grid gap-2 text-xs text-base-content/70 xl:col-span-2">
                    名称
                    <input
                      className="input input-sm w-full text-base-content"
                      value={proxy.name}
                      onChange={(event) => renameProxy(index, event.target.value)}
                    />
                  </label>
                  <label className="grid gap-2 text-xs text-base-content/70">
                    类型
                    <select
                      className="select select-sm w-full text-base-content"
                      value={proxy.type}
                      onChange={(event) =>
                        updateProxy(index, { type: event.target.value })
                      }
                    >
                      {!PROXY_TYPES.includes(proxy.type) ? (
                        <option value={proxy.type}>{proxy.type}</option>
                      ) : null}
                      {PROXY_TYPES.map((type) => (
                        <option key={type} value={type}>
                          {type}
                        </option>
                      ))}
                    </select>
                  </label>
                  <label className="grid gap-2 text-xs text-base-content/70 xl:col-span-2">
                    Server
                    <input
                      className="input input-sm w-full text-base-content"
                      value={proxy.server ?? ""}
                      placeholder="127.0.0.1"
                      onChange={(event) =>
                        updateProxy(index, { server: event.target.value })
                      }
                    />
                  </label>
                  <label className="grid gap-2 text-xs text-base-content/70">
                    Port
                    <input
                      className="input input-sm w-full text-base-content"
                      type="number"
                      min="1"
                      max="65535"
                      value={proxy.port ?? ""}
                      onChange={(event) =>
                        updateProxy(index, {
                          port: event.target.value
                            ? Number(event.target.value)
                            : undefined,
                        })
                      }
                    />
                  </label>
                  <label className="grid gap-2 text-xs text-base-content/70 xl:col-span-3">
                    Username（可选）
                    <input
                      className="input input-sm w-full text-base-content"
                      value={proxy.username ?? ""}
                      autoComplete="off"
                      onChange={(event) =>
                        updateProxy(index, { username: event.target.value })
                      }
                    />
                  </label>
                  <label className="grid gap-2 text-xs text-base-content/70 xl:col-span-3">
                    Password（可选）
                    <input
                      className="input input-sm w-full text-base-content"
                      type="password"
                      value={proxy.password ?? ""}
                      autoComplete="new-password"
                      onChange={(event) =>
                        updateProxy(index, { password: event.target.value })
                      }
                    />
                  </label>
                </div>
              </article>
            ))}
          </div>
        )}
      </div>
    </section>
  );
}

interface SelectorPanelProps {
  document: ClashDocument;
  onChange: (document: ClashDocument) => void;
}

function SelectorPanel({ document, onChange }: SelectorPanelProps) {
  const groups = document["proxy-groups"];

  const updateGroup = (index: number, patch: Partial<SelectorGroup>) => {
    onChange({
      ...document,
      "proxy-groups": groups.map((group, groupIndex) =>
        groupIndex === index ? { ...group, ...patch } : group,
      ),
    });
  };

  const renameGroup = (index: number, name: string) => {
    const previous = groups[index].name;
    const renamed = renameRouteTarget(document, previous, name);
    onChange({
      ...renamed,
      "proxy-groups": renamed["proxy-groups"].map((group, groupIndex) =>
        groupIndex === index ? { ...group, name } : group,
      ),
    });
  };

  const addGroup = () => {
    const name = nextName(
      "selector",
      groups.map((group) => group.name),
    );
    const firstProxy = document.proxies[0]?.name;
    onChange({
      ...document,
      "proxy-groups": [
        ...groups,
        {
          name,
          type: "select",
          proxies: firstProxy ? [firstProxy, "DIRECT"] : ["DIRECT"],
        },
      ],
    });
  };

  const removeGroup = (index: number) => {
    onChange({
      ...document,
      "proxy-groups": groups.filter((_, groupIndex) => groupIndex !== index),
    });
  };

  return (
    <section className="card card-border route-board overflow-hidden bg-base-200">
      <div className="card-body gap-6 p-5 sm:p-7">
        <SectionHeading
          step="02"
          title="Selector 跳线"
          description="成员顺序就是 Clash 手动选择列表顺序。Selector 类型固定为 select。"
          count={groups.length}
          onAdd={addGroup}
          addLabel="添加 Selector"
        />

        {groups.length === 0 ? (
          <div className="rounded-box border border-dashed border-base-300 bg-base-200/80 p-8 text-center text-sm text-base-content/70">
            至少添加一个 Selector，规则才能把流量接入手动选择。
          </div>
        ) : (
          <div className="grid gap-4 xl:grid-cols-2">
            {groups.map((group, groupIndex) => {
              const candidates = unique([
                ...document.proxies.map((proxy) => proxy.name),
                ...BUILTIN_TARGETS,
              ]).filter((target) => !group.proxies.includes(target));

              return (
                <article
                  key={groupIndex}
                  className="rounded-box border border-base-300 bg-base-200/90 p-4 shadow-sm"
                >
                  <div className="mb-5 flex items-start gap-3">
                    <div className="min-w-0 flex-1">
                      <label className="grid gap-2 text-xs text-base-content/70">
                        Selector 名称
                        <input
                          className="input input-sm w-full text-base-content"
                          value={group.name}
                          onChange={(event) =>
                            renameGroup(groupIndex, event.target.value)
                          }
                        />
                      </label>
                    </div>
                    <span className="badge badge-secondary badge-soft mt-6">
                      select
                    </span>
                    <button
                      type="button"
                      className="btn btn-ghost btn-xs mt-5 text-error"
                      aria-label={`删除 Selector ${group.name}`}
                      onClick={() => removeGroup(groupIndex)}
                    >
                      删除
                    </button>
                  </div>

                  <div className="route-lane space-y-2">
                    {group.proxies.map((member, memberIndex) => (
                      <div
                        key={`${member}-${memberIndex}`}
                        className="route-node flex min-h-10 items-center gap-2 rounded-field border border-base-300 bg-base-100 px-3"
                      >
                        <span className="data-type w-5 text-[0.65rem] text-base-content/70">
                          {(memberIndex + 1).toString().padStart(2, "0")}
                        </span>
                        <span className="data-type min-w-0 flex-1 truncate text-xs">
                          {member}
                        </span>
                        <button
                          type="button"
                          className="btn btn-ghost btn-xs px-1"
                          aria-label={`上移 ${member}`}
                          disabled={memberIndex === 0}
                          onClick={() =>
                            updateGroup(groupIndex, {
                              proxies: moveItem(
                                group.proxies,
                                memberIndex,
                                -1,
                              ),
                            })
                          }
                        >
                          ↑
                        </button>
                        <button
                          type="button"
                          className="btn btn-ghost btn-xs px-1"
                          aria-label={`下移 ${member}`}
                          disabled={memberIndex === group.proxies.length - 1}
                          onClick={() =>
                            updateGroup(groupIndex, {
                              proxies: moveItem(group.proxies, memberIndex, 1),
                            })
                          }
                        >
                          ↓
                        </button>
                        <button
                          type="button"
                          className="btn btn-ghost btn-xs px-1 text-error"
                          aria-label={`从 ${group.name} 移除 ${member}`}
                          onClick={() =>
                            updateGroup(groupIndex, {
                              proxies: group.proxies.filter(
                                (_, index) => index !== memberIndex,
                              ),
                            })
                          }
                        >
                          ×
                        </button>
                      </div>
                    ))}
                  </div>

                  <label className="mt-4 grid gap-2 text-xs text-base-content/70">
                    接入出口
                    <select
                      className="select select-sm w-full text-base-content"
                      value=""
                      disabled={candidates.length === 0}
                      onChange={(event) => {
                        if (!event.target.value) return;
                        updateGroup(groupIndex, {
                          proxies: [...group.proxies, event.target.value],
                        });
                      }}
                    >
                      <option value="">
                        {candidates.length ? "选择 Proxy 或内建出口" : "已全部接入"}
                      </option>
                      {candidates.map((candidate) => (
                        <option key={candidate} value={candidate}>
                          {candidate}
                        </option>
                      ))}
                    </select>
                  </label>
                </article>
              );
            })}
          </div>
        )}
      </div>
    </section>
  );
}

interface RulesPanelProps {
  document: ClashDocument;
  onChange: (document: ClashDocument) => void;
}

function RulesPanel({ document, onChange }: RulesPanelProps) {
  const setRules = (rules: string[]) => onChange({ ...document, rules });

  const addRule = () => {
    const target = document["proxy-groups"][0]?.name ?? "DIRECT";
    const rule = `DOMAIN-SUFFIX,example.com,${target}`;
    const fallbackIndex = document.rules.findIndex((item) =>
      item.trim().toUpperCase().startsWith("MATCH,"),
    );
    const rules = [...document.rules];
    rules.splice(fallbackIndex < 0 ? rules.length : fallbackIndex, 0, rule);
    setRules(rules);
  };

  return (
    <section className="card card-border bg-base-200">
      <div className="card-body gap-6 p-5 sm:p-7">
        <SectionHeading
          step="03"
          title="Rule 顺序"
          description="Clash 从上到下命中第一条规则。MATCH 兜底通常放在末尾。"
          count={document.rules.length}
          onAdd={addRule}
          addLabel="添加 Rule"
        />

        <div className="space-y-2">
          {document.rules.map((rule, index) => (
            <div
              key={index}
              className="flex items-center gap-2 rounded-field border border-base-300 bg-base-100/45 p-2"
            >
              <span className="data-type w-8 shrink-0 text-center text-[0.65rem] text-base-content/70">
                {(index + 1).toString().padStart(2, "0")}
              </span>
              <input
                className="input input-ghost data-type h-9 min-w-0 flex-1 text-xs"
                aria-label={`规则 ${index + 1}`}
                value={rule}
                onChange={(event) =>
                  setRules(
                    document.rules.map((item, ruleIndex) =>
                      ruleIndex === index ? event.target.value : item,
                    ),
                  )
                }
              />
              <button
                type="button"
                className="btn btn-ghost btn-xs px-1"
                aria-label={`上移规则 ${index + 1}`}
                disabled={index === 0}
                onClick={() => setRules(moveItem(document.rules, index, -1))}
              >
                ↑
              </button>
              <button
                type="button"
                className="btn btn-ghost btn-xs px-1"
                aria-label={`下移规则 ${index + 1}`}
                disabled={index === document.rules.length - 1}
                onClick={() => setRules(moveItem(document.rules, index, 1))}
              >
                ↓
              </button>
              <button
                type="button"
                className="btn btn-ghost btn-xs px-1 text-error"
                aria-label={`删除规则 ${index + 1}`}
                onClick={() =>
                  setRules(
                    document.rules.filter(
                      (_, ruleIndex) => ruleIndex !== index,
                    ),
                  )
                }
              >
                ×
              </button>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

interface CreateDialogProps {
  dialogRef: React.RefObject<HTMLDialogElement | null>;
  busy: boolean;
  error: string | null;
  onCreate: (name: string, slug: string) => Promise<boolean>;
}

function CreateDialog({
  dialogRef,
  busy,
  error,
  onCreate,
}: CreateDialogProps) {
  const [name, setName] = useState("");
  const [slug, setSlug] = useState("");

  const submit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const created = await onCreate(name.trim(), slug.trim());
    if (created) {
      setName("");
      setSlug("");
      dialogRef.current?.close();
    }
  };

  return (
    <dialog ref={dialogRef} className="modal">
      <form className="modal-box bg-base-200" onSubmit={submit}>
        <div className="data-type mb-2 text-xs tracking-[0.18em] text-accent uppercase">
          New configuration
        </div>
        <h2 className="display-type text-3xl font-semibold">新建配置</h2>
        <p className="mt-2 text-sm text-base-content/70">
          创建最小 Clash 骨架：一个手动 Selector 与 MATCH,DIRECT。
        </p>
        {error ? (
          <div role="alert" className="alert alert-error mt-5 text-sm">
            {error}
          </div>
        ) : null}
        <fieldset disabled={busy} className="mt-6 grid gap-4">
          <label className="grid gap-2 text-sm">
            配置名
            <input
              className="input w-full"
              required
              maxLength={120}
              value={name}
              placeholder="家庭网络"
              onChange={(event) => setName(event.target.value)}
            />
          </label>
          <label className="grid gap-2 text-sm">
            订阅标识
            <input
              className="input data-type w-full"
              required
              pattern="[a-z0-9]+(?:-[a-z0-9]+)*"
              maxLength={64}
              value={slug}
              placeholder="home-network"
              title="仅可使用小写字母、数字与中划线"
              onChange={(event) => setSlug(event.target.value)}
            />
            <span className="text-xs text-base-content/70">
              仅小写字母、数字与中划线。
            </span>
          </label>
        </fieldset>
        <div className="modal-action">
          <button
            type="button"
            className="btn btn-ghost"
            onClick={() => dialogRef.current?.close()}
          >
            取消
          </button>
          <button type="submit" className="btn" disabled={busy}>
            {busy ? <span className="loading loading-spinner loading-sm" /> : null}
            创建配置
          </button>
        </div>
      </form>
      <form method="dialog" className="modal-backdrop">
        <button type="submit">关闭</button>
      </form>
    </dialog>
  );
}

interface EmptyStateProps {
  busy: boolean;
  error: string | null;
  onNew: () => void;
  onRetry: () => void;
}

function EmptyState({ busy, error, onNew, onRetry }: EmptyStateProps) {
  return (
    <main className="grid min-h-[calc(100vh-4rem)] place-items-center p-6">
      <div className="card card-border max-w-lg bg-base-200">
        <div className="card-body items-start">
          <span className={`badge ${error ? "badge-error" : "badge-outline"}`}>
            {error ? "API offline" : "empty rack"}
          </span>
          <h1 className="display-type mt-2 text-4xl font-semibold">
            {error ? "暂时接不上配置库。" : "配线架还是空的。"}
          </h1>
          {error ? (
            <div role="alert" className="alert alert-error text-sm">
              {error}
            </div>
          ) : (
            <p className="text-base-content/70">
              新建配置，或重启后端恢复尚未写入过的初始规则。
            </p>
          )}
          <div className="card-actions mt-4">
            {error ? (
              <button
                type="button"
                className="btn"
                disabled={busy}
                onClick={onRetry}
              >
                {busy ? (
                  <span className="loading loading-spinner loading-sm" />
                ) : null}
                重试连接
              </button>
            ) : (
              <button type="button" className="btn" disabled={busy} onClick={onNew}>
                新建配置
              </button>
            )}
          </div>
        </div>
      </div>
    </main>
  );
}

export default function App() {
  const {
    configs,
    activeId,
    draft,
    dirty,
    busy,
    error,
    subscriptionToken,
    load,
    select,
    setIdentity,
    setDocument,
    save,
    createConfig,
    remove,
    clearError,
  } = useConfigStore();
  const createDialogRef = useRef<HTMLDialogElement>(null);
  const drawerButtonRef = useRef<HTMLButtonElement>(null);
  const drawerCloseButtonRef = useRef<HTMLButtonElement>(null);
  const [copyState, setCopyState] = useState("复制 URL");
  const [drawerOpen, setDrawerOpen] = useState(false);

  useEffect(() => {
    void load();
  }, [load]);

  useEffect(() => {
    if (!drawerOpen) return;
    const frame = window.requestAnimationFrame(() =>
      drawerCloseButtonRef.current?.focus(),
    );
    return () => window.cancelAnimationFrame(frame);
  }, [drawerOpen]);

  const closeDrawer = () => {
    setDrawerOpen(false);
    window.requestAnimationFrame(() => drawerButtonRef.current?.focus());
  };

  const subscriptionUrl = useMemo(
    () => (draft ? getSubscriptionUrl(draft.slug, subscriptionToken) : ""),
    [draft, subscriptionToken],
  );

  const selectConfig = (id: number) => {
    if (busy || id === activeId) return;
    if (dirty && !window.confirm("放弃当前未保存修改并切换配置？")) return;
    select(id);
    if (drawerOpen) closeDrawer();
  };

  const removeConfig = async () => {
    if (!draft) return;
    if (!window.confirm(`删除配置“${draft.name}”？此操作无法撤销。`)) return;
    await remove();
  };

  const copySubscription = async () => {
    try {
      await navigator.clipboard.writeText(subscriptionUrl);
      setCopyState("已复制");
    } catch {
      setCopyState("复制失败");
    }
    window.setTimeout(() => setCopyState("复制 URL"), 1800);
  };

  const openCreateDialog = () => {
    if (busy) return;
    clearError();
    setDrawerOpen(false);
    createDialogRef.current?.showModal();
  };

  return (
    <div className="min-h-screen bg-base-100 text-base-content">
      <div className="drawer lg:drawer-open">
        <input
          id="config-drawer"
          type="checkbox"
          className="drawer-toggle"
          checked={drawerOpen}
          onChange={(event) =>
            event.target.checked ? setDrawerOpen(true) : closeDrawer()
          }
        />
        <div className="drawer-content min-w-0">
          <header className="navbar sticky top-0 z-30 min-h-16 border-b border-base-300 bg-base-200/95 px-3 backdrop-blur sm:px-6">
            <div className="navbar-start min-w-0 gap-2">
              <button
                ref={drawerButtonRef}
                type="button"
                className="btn btn-ghost btn-square drawer-button lg:hidden"
                aria-label="打开配置列表"
                aria-controls="config-sidebar"
                aria-expanded={drawerOpen}
                onClick={() => setDrawerOpen(true)}
              >
                ☰
              </button>
              <div className="min-w-0">
                <div className="truncate text-sm font-semibold">
                  {draft?.name ?? "Route Deck"}
                </div>
                <div className="data-type truncate text-[0.65rem] text-base-content/70">
                  {draft ? `/${draft.slug}` : "Clash configuration"}
                </div>
              </div>
            </div>
            <div className="navbar-end gap-2">
              {draft ? (
                <span
                  className={`badge badge-sm ${
                    dirty ? "badge-warning" : "badge-success badge-soft"
                  }`}
                  aria-live="polite"
                >
                  {dirty ? "未保存" : "已同步"}
                </span>
              ) : null}
              <button
                type="button"
                className="btn btn-primary btn-sm"
                disabled={!draft || !dirty || busy}
                onClick={() => void save()}
              >
                {busy ? (
                  <span className="loading loading-spinner loading-xs" />
                ) : null}
                保存配置
              </button>
            </div>
          </header>

          {busy && configs.length === 0 && !draft ? (
            <main className="grid min-h-[calc(100vh-4rem)] place-items-center">
              <div className="text-center">
                <span className="loading loading-bars loading-lg text-accent" />
                <p className="mt-3 text-sm text-base-content/70">正在接入配置…</p>
              </div>
            </main>
          ) : draft ? (
            <main
              className="mx-auto max-w-[1480px] space-y-5 p-4 sm:p-6 lg:p-8"
              aria-busy={busy}
            >
              {error ? (
                <div role="alert" className="alert alert-error">
                  <span className="min-w-0 flex-1">{error}</span>
                  <button
                    type="button"
                    className="btn btn-ghost btn-sm"
                    onClick={clearError}
                  >
                    关闭
                  </button>
                </div>
              ) : null}

              <fieldset disabled={busy} className="contents">
                <section className="card overflow-hidden border border-base-300 bg-base-200">
                <div className="grid lg:grid-cols-[1.4fr_1fr]">
                  <div className="p-6 sm:p-8 lg:p-10">
                    <div className="data-type mb-4 text-xs tracking-[0.2em] text-accent uppercase">
                      Live routing manifest
                    </div>
                    <h1 className="display-type max-w-3xl text-4xl leading-[0.98] font-semibold tracking-tight sm:text-5xl xl:text-6xl">
                      把每条流量，接到正确出口。
                    </h1>
                    <p className="mt-5 max-w-2xl text-sm leading-6 text-base-content/70 sm:text-base">
                      先定义 Proxy，再把出口接进 Selector，最后按顺序匹配 Rule。保存后订阅立即生效。
                    </p>
                  </div>
                  <div className="grid content-center gap-4 border-t border-base-300 bg-base-300/45 p-6 sm:p-8 lg:border-t-0 lg:border-l">
                    <label className="grid gap-2 text-xs text-base-content/70">
                      配置名
                      <input
                        className="input input-sm w-full text-base-content"
                        maxLength={120}
                        value={draft.name}
                        onChange={(event) =>
                          setIdentity({ name: event.target.value })
                        }
                      />
                    </label>
                    <label className="grid gap-2 text-xs text-base-content/70">
                      订阅标识
                      <input
                        className="input input-sm data-type w-full text-base-content"
                        required
                        pattern="[a-z0-9]+(?:-[a-z0-9]+)*"
                        title="仅可使用小写字母、数字与中划线"
                        maxLength={64}
                        value={draft.slug}
                        onChange={(event) =>
                          setIdentity({ slug: event.target.value })
                        }
                      />
                    </label>
                    <div className="min-w-0">
                      <span className="mb-2 block text-xs text-base-content/70">
                        Clash 订阅 URL
                      </span>
                      <div className="flex min-w-0 items-center gap-2 rounded-field border border-base-300 bg-base-200 p-2">
                        <a
                          className="data-type min-w-0 flex-1 truncate text-xs text-info underline-offset-4 hover:underline"
                          href={subscriptionUrl}
                          target="_blank"
                          rel="noreferrer"
                        >
                          {subscriptionUrl}
                        </a>
                        <button
                          type="button"
                          className="btn btn-ghost btn-xs shrink-0"
                          onClick={() => void copySubscription()}
                        >
                          {copyState}
                        </button>
                      </div>
                    </div>
                    <button
                      type="button"
                      className="btn btn-ghost btn-sm justify-self-start text-error"
                      disabled={busy}
                      onClick={() => void removeConfig()}
                    >
                      删除此配置
                    </button>
                  </div>
                </div>
                </section>

                <RuntimePanel
                  document={draft.document}
                  onChange={setDocument}
                />
                <ProxyPanel document={draft.document} onChange={setDocument} />
                <SelectorPanel document={draft.document} onChange={setDocument} />
                <RulesPanel document={draft.document} onChange={setDocument} />
              </fieldset>

              <footer className="flex flex-col gap-2 px-1 py-5 text-xs text-base-content/70 sm:flex-row sm:items-center sm:justify-between">
                <span>Route Deck · local-first Clash configuration</span>
                <span className="data-type">
                  {draft.document.proxies.length} proxies ·{" "}
                  {draft.document["proxy-groups"].length} selectors ·{" "}
                  {draft.document.rules.length} rules
                </span>
              </footer>
            </main>
          ) : (
            <EmptyState
              busy={busy}
              error={error}
              onNew={openCreateDialog}
              onRetry={() => void load()}
            />
          )}
        </div>

        <div className="drawer-side z-40">
          <label
            htmlFor="config-drawer"
            aria-label="关闭配置列表"
            className="drawer-overlay"
          />
          <Sidebar
            configs={configs}
            activeId={activeId}
            dirty={dirty}
            busy={busy}
            modalOpen={drawerOpen}
            closeButtonRef={drawerCloseButtonRef}
            onSelect={selectConfig}
            onNew={openCreateDialog}
            onClose={closeDrawer}
          />
        </div>
      </div>

      <CreateDialog
        dialogRef={createDialogRef}
        busy={busy}
        error={error}
        onCreate={createConfig}
      />
    </div>
  );
}
