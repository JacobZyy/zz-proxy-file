import { create } from "zustand";
import {
  createConfig as createConfigRequest,
  deleteConfig as deleteConfigRequest,
  listConfigs,
  updateConfig,
} from "./api";
import { createBlankDocument } from "./config";
import type { ClashDocument, ConfigDraft, ConfigRecord } from "./types";

interface ConfigState {
  configs: ConfigRecord[];
  activeId: number | null;
  draft: ConfigDraft | null;
  dirty: boolean;
  busy: boolean;
  error: string | null;
  load: () => Promise<void>;
  select: (id: number) => void;
  setIdentity: (patch: Partial<Pick<ConfigDraft, "name" | "slug">>) => void;
  setDocument: (document: ClashDocument) => void;
  save: () => Promise<boolean>;
  createConfig: (name: string, slug: string) => Promise<boolean>;
  remove: () => Promise<boolean>;
  clearError: () => void;
}

function toDraft(config: ConfigRecord): ConfigDraft {
  return {
    name: config.name,
    slug: config.slug,
    document: structuredClone(config.document),
  };
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "未知错误";
}

export const useConfigStore = create<ConfigState>((set, get) => ({
  configs: [],
  activeId: null,
  draft: null,
  dirty: false,
  busy: false,
  error: null,

  load: async () => {
    set({ busy: true, error: null });
    try {
      const configs = await listConfigs();
      const active = configs[0] ?? null;
      set({
        configs,
        activeId: active?.id ?? null,
        draft: active ? toDraft(active) : null,
        dirty: false,
        busy: false,
      });
    } catch (error) {
      set({ busy: false, error: errorMessage(error) });
    }
  },

  select: (id) => {
    const state = get();
    if (state.busy) return;
    const config = state.configs.find((item) => item.id === id);
    if (config) {
      set({ activeId: id, draft: toDraft(config), dirty: false, error: null });
    }
  },

  setIdentity: (patch) => {
    const { busy, draft } = get();
    if (!busy && draft) set({ draft: { ...draft, ...patch }, dirty: true });
  },

  setDocument: (document) => {
    const { busy, draft } = get();
    if (!busy && draft) set({ draft: { ...draft, document }, dirty: true });
  },

  save: async () => {
    const { activeId, busy, draft } = get();
    if (busy || activeId === null || !draft) return false;

    set({ busy: true, error: null });
    try {
      const saved = await updateConfig(activeId, draft);
      set((state) => {
        const configs = state.configs.map((item) =>
          item.id === saved.id ? saved : item,
        );
        if (state.activeId !== activeId) return { configs, busy: false };
        return {
          configs,
          draft: toDraft(saved),
          dirty: false,
          busy: false,
        };
      });
      return true;
    } catch (error) {
      set({ busy: false, error: errorMessage(error) });
      return false;
    }
  },

  createConfig: async (name, slug) => {
    if (get().busy) return false;
    set({ busy: true, error: null });
    try {
      const created = await createConfigRequest({
        name,
        slug,
        document: createBlankDocument(),
      });
      set((state) => ({
        configs: [created, ...state.configs],
        activeId: created.id,
        draft: toDraft(created),
        dirty: false,
        busy: false,
      }));
      return true;
    } catch (error) {
      set({ busy: false, error: errorMessage(error) });
      return false;
    }
  },

  remove: async () => {
    const { activeId, busy } = get();
    if (busy || activeId === null) return false;

    set({ busy: true, error: null });
    try {
      await deleteConfigRequest(activeId);
      const configs = get().configs.filter((item) => item.id !== activeId);
      const active = configs[0] ?? null;
      set({
        configs,
        activeId: active?.id ?? null,
        draft: active ? toDraft(active) : null,
        dirty: false,
        busy: false,
      });
      return true;
    } catch (error) {
      set({ busy: false, error: errorMessage(error) });
      return false;
    }
  },

  clearError: () => set({ error: null }),
}));
