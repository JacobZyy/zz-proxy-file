import { beforeEach, describe, expect, it, vi } from "vitest";
import { updateConfig } from "./api";
import { useConfigStore } from "./store";
import type { ClashDocument, ConfigDraft, ConfigRecord } from "./types";

vi.mock("./api", () => ({
  createConfig: vi.fn(),
  deleteConfig: vi.fn(),
  listConfigs: vi.fn(),
  updateConfig: vi.fn(),
}));

const document: ClashDocument = {
  proxies: [],
  "proxy-groups": [
    { name: "default-selector", type: "select", proxies: ["DIRECT"] },
  ],
  rules: ["MATCH,DIRECT"],
};

function config(id: number, name: string): ConfigRecord {
  return {
    id,
    name,
    slug: name.toLowerCase(),
    document: structuredClone(document),
    createdAt: "2026-08-04T00:00:00Z",
    updatedAt: "2026-08-04T00:00:00Z",
  };
}

function draft(record: ConfigRecord): ConfigDraft {
  return {
    name: record.name,
    slug: record.slug,
    document: structuredClone(record.document),
  };
}

describe("configuration save", () => {
  const first = config(1, "First");
  const second = config(2, "Second");

  beforeEach(() => {
    vi.mocked(updateConfig).mockReset();
    useConfigStore.setState({
      configs: [first, second],
      activeId: first.id,
      draft: draft(first),
      dirty: true,
      busy: false,
      error: null,
    });
  });

  it("locks edits and ignores a stale save result", async () => {
    let resolveSave!: (record: ConfigRecord) => void;
    vi.mocked(updateConfig).mockReturnValueOnce(
      new Promise((resolve) => {
        resolveSave = resolve;
      }),
    );

    const saving = useConfigStore.getState().save();
    useConfigStore.getState().setIdentity({ name: "Late edit" });
    useConfigStore.getState().select(second.id);

    expect(useConfigStore.getState().draft?.name).toBe("First");
    expect(useConfigStore.getState().activeId).toBe(first.id);

    useConfigStore.setState({
      activeId: second.id,
      draft: draft(second),
      dirty: false,
    });
    resolveSave({ ...first, name: "First saved" });
    await saving;

    const state = useConfigStore.getState();
    expect(state.activeId).toBe(second.id);
    expect(state.draft?.name).toBe("Second");
    expect(state.configs[0].name).toBe("First saved");
    expect(state.busy).toBe(false);
  });
});
