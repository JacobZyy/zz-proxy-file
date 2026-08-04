import type { ApiErrorBody, ConfigDraft, ConfigRecord } from "./types";

const backendPrefix = "/clash-config-tool";
const apiBase = (import.meta.env.VITE_API_URL || backendPrefix).replace(
  /\/$/,
  "",
);

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${apiBase}${path}`, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...init?.headers,
    },
  });

  if (!response.ok) {
    let message = `请求失败（HTTP ${response.status}）`;
    try {
      const body = (await response.json()) as ApiErrorBody;
      message = body.error || message;
    } catch {
      // Keep status-based message when server does not return JSON.
    }
    throw new Error(message);
  }

  if (response.status === 204) {
    return undefined as T;
  }

  return (await response.json()) as T;
}

export function listConfigs(): Promise<ConfigRecord[]> {
  return request<ConfigRecord[]>("/api/configs");
}

export function createConfig(draft: ConfigDraft): Promise<ConfigRecord> {
  return request<ConfigRecord>("/api/configs", {
    method: "POST",
    body: JSON.stringify(draft),
  });
}

export function updateConfig(
  id: number,
  draft: ConfigDraft,
): Promise<ConfigRecord> {
  return request<ConfigRecord>(`/api/configs/${id}`, {
    method: "PUT",
    body: JSON.stringify(draft),
  });
}

export function deleteConfig(id: number): Promise<void> {
  return request<void>(`/api/configs/${id}`, { method: "DELETE" });
}

export async function getSubscriptionToken(): Promise<string> {
  const response = await request<{ token: string | null }>(
    "/api/subscription-token",
  );
  return response.token ?? "";
}

function getConfiguredSubscriptionOrigin(): string {
  const value = import.meta.env.VITE_SUBSCRIPTION_ORIGIN || "";
  if (!value) return "";

  const url = new URL(value);
  if (
    !["http:", "https:"].includes(url.protocol) ||
    url.username ||
    url.password ||
    url.pathname !== "/" ||
    url.search ||
    url.hash
  ) {
    throw new Error("VITE_SUBSCRIPTION_ORIGIN must be an HTTP(S) origin");
  }
  return url.origin;
}

export function getSubscriptionUrl(slug: string, token = ""): string {
  const path = `/subscriptions/${encodeURIComponent(slug)}`;
  const configuredOrigin = getConfiguredSubscriptionOrigin();
  let url: string;
  if (configuredOrigin) {
    url = `${configuredOrigin}${backendPrefix}${path}`;
  } else {
    const absoluteApiBase = new URL(apiBase, window.location.origin)
      .toString()
      .replace(/\/$/, "");
    url = `${absoluteApiBase}${path}`;
  }

  if (!token) return url;
  const subscriptionUrl = new URL(url);
  subscriptionUrl.searchParams.set("token", token);
  return subscriptionUrl.toString();
}
