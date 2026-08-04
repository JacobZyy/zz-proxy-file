import { afterEach, describe, expect, it, vi } from "vitest";
import { copyText } from "./clipboard";

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("copyText", () => {
  it("falls back when the Clipboard API is unavailable", async () => {
    const textarea = {
      value: "",
      style: { position: "", opacity: "" },
      setAttribute: vi.fn(),
      select: vi.fn(),
      remove: vi.fn(),
    };
    const appendChild = vi.fn();
    const execCommand = vi.fn(() => true);
    vi.stubGlobal("navigator", {});
    vi.stubGlobal("document", {
      createElement: vi.fn(() => textarea),
      body: { appendChild },
      execCommand,
    });

    await expect(copyText("subscription-url")).resolves.toBeUndefined();
    expect(textarea.value).toBe("subscription-url");
    expect(appendChild).toHaveBeenCalledWith(textarea);
    expect(textarea.select).toHaveBeenCalledOnce();
    expect(execCommand).toHaveBeenCalledWith("copy");
    expect(textarea.remove).toHaveBeenCalledOnce();
  });

  it("removes the fallback element when copying throws", async () => {
    const textarea = {
      value: "",
      style: { position: "", opacity: "" },
      setAttribute: vi.fn(),
      select: vi.fn(),
      remove: vi.fn(),
    };
    vi.stubGlobal("navigator", {});
    vi.stubGlobal("document", {
      createElement: vi.fn(() => textarea),
      body: { appendChild: vi.fn() },
      execCommand: vi.fn(() => {
        throw new Error("denied");
      }),
    });

    await expect(copyText("subscription-url")).rejects.toThrow("denied");
    expect(textarea.remove).toHaveBeenCalledOnce();
  });
});
