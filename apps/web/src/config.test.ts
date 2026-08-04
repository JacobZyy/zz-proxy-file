import { describe, expect, it } from "vitest";
import { createBlankDocument, moveItem, renameRouteTarget } from "./config";

describe("Clash document edits", () => {
  it("creates a manual selector with a direct fallback", () => {
    const document = createBlankDocument();
    expect(document["proxy-groups"][0]).toEqual({
      name: "default-selector",
      type: "select",
      proxies: ["DIRECT"],
    });
    expect(document.rules.at(-1)).toBe("MATCH,DIRECT");
  });

  it("renames references without touching rule payloads", () => {
    const document = createBlankDocument();
    document.proxies = [
      { name: "old", type: "http", server: "127.0.0.1", port: 8080 },
    ];
    document["proxy-groups"][0].proxies = ["old", "DIRECT"];
    document.rules = ["DOMAIN,old.example,old", "MATCH,DIRECT"];

    const renamed = renameRouteTarget(document, "old", "new");
    expect(renamed["proxy-groups"][0].proxies).toEqual(["new", "DIRECT"]);
    expect(renamed.rules).toEqual([
      "DOMAIN,old.example,new",
      "MATCH,DIRECT",
    ]);
  });

  it("keeps ordered lists inside their boundaries", () => {
    expect(moveItem(["a", "b", "c"], 1, 1)).toEqual(["a", "c", "b"]);
    expect(moveItem(["a", "b"], 0, -1)).toEqual(["a", "b"]);
  });
});
