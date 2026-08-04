import type { ClashDocument } from "./types";

export function createBlankDocument(): ClashDocument {
  return {
    "mixed-port": 7890,
    "allow-lan": false,
    mode: "rule",
    "log-level": "info",
    proxies: [],
    "proxy-groups": [
      {
        name: "default-selector",
        type: "select",
        proxies: ["DIRECT"],
      },
    ],
    rules: ["MATCH,DIRECT"],
  };
}

export function moveItem<T>(items: T[], index: number, offset: -1 | 1): T[] {
  const nextIndex = index + offset;
  if (nextIndex < 0 || nextIndex >= items.length) return items;

  const next = [...items];
  [next[index], next[nextIndex]] = [next[nextIndex], next[index]];
  return next;
}

function renameRuleTarget(rule: string, previous: string, next: string): string {
  const parts = rule.split(",");
  const noResolve = parts.at(-1)?.trim().toLowerCase() === "no-resolve";
  const targetIndex = noResolve ? parts.length - 2 : parts.length - 1;
  if (targetIndex < 0 || parts[targetIndex]?.trim() !== previous) return rule;

  parts[targetIndex] = parts[targetIndex].replace(previous, next);
  return parts.join(",");
}

export function renameRouteTarget(
  document: ClashDocument,
  previous: string,
  next: string,
): ClashDocument {
  if (!previous || previous === next) return document;

  return {
    ...document,
    "proxy-groups": document["proxy-groups"].map((group) => ({
      ...group,
      proxies: group.proxies.map((member) =>
        member === previous ? next : member,
      ),
    })),
    rules: document.rules.map((rule) =>
      renameRuleTarget(rule, previous, next),
    ),
  };
}
