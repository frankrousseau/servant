import { describe, it, expect } from "vitest";
import { safeUrl } from "./url";

describe("safeUrl", () => {
  it("allows http/https/mailto/tel", () => {
    expect(safeUrl("https://example.com")).toBe("https://example.com");
    expect(safeUrl("http://example.com")).toBe("http://example.com");
    expect(safeUrl("mailto:a@b.com")).toBe("mailto:a@b.com");
    expect(safeUrl("tel:+33123")).toBe("tel:+33123");
  });

  it("blocks javascript: and data: URIs", () => {
    expect(safeUrl("javascript:alert(1)")).toBeNull();
    expect(safeUrl("data:text/html,<script>")).toBeNull();
  });

  it("returns null for empty input or disallowed schemes", () => {
    expect(safeUrl("")).toBeNull();
    expect(safeUrl("ftp://example.com")).toBeNull();
    expect(safeUrl("file:///etc/passwd")).toBeNull();
  });
});
