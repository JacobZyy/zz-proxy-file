export interface ClashProxy {
  name: string;
  type: string;
  server?: string;
  port?: number;
  username?: string;
  password?: string;
  [key: string]: unknown;
}

export interface SelectorGroup {
  name: string;
  type: string;
  proxies: string[];
  [key: string]: unknown;
}

export interface ClashDocument {
  "mixed-port"?: number;
  "allow-lan"?: boolean;
  mode?: string;
  "log-level"?: string;
  proxies: ClashProxy[];
  "proxy-groups": SelectorGroup[];
  rules: string[];
  [key: string]: unknown;
}

export interface ConfigRecord {
  id: number;
  name: string;
  slug: string;
  document: ClashDocument;
  createdAt: string;
  updatedAt: string;
}

export interface ConfigDraft {
  name: string;
  slug: string;
  document: ClashDocument;
}

export interface ApiErrorBody {
  error?: string;
}
