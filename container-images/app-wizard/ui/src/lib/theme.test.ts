import { beforeEach, describe, expect, it } from "vitest";
import { resetTheme, setSystemDark } from "@/test/setup";
import {
  THEME_STORAGE_KEY,
  applyTheme,
  nextMode,
  readStoredMode,
  resolveTheme,
  storeMode,
} from "@/lib/theme";

beforeEach(resetTheme);

describe("readStoredMode", () => {
  it("defaults to system when nothing has been chosen", () => {
    expect(readStoredMode()).toBe("system");
  });

  it("returns the stored choice", () => {
    storeMode("dark");
    expect(readStoredMode()).toBe("dark");
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe("dark");
  });

  it("falls back to system when the stored value is garbage", () => {
    localStorage.setItem(THEME_STORAGE_KEY, "chartreuse");
    expect(readStoredMode()).toBe("system");
  });
});

describe("resolveTheme", () => {
  it("passes explicit choices straight through", () => {
    setSystemDark(true);
    expect(resolveTheme("light")).toBe("light");
    expect(resolveTheme("dark")).toBe("dark");
  });

  it("follows the OS in system mode", () => {
    setSystemDark(true);
    expect(resolveTheme("system")).toBe("dark");

    setSystemDark(false);
    expect(resolveTheme("system")).toBe("light");
  });
});

describe("applyTheme", () => {
  it("adds the dark class only when the resolved theme is dark", () => {
    applyTheme("dark");
    expect(document.documentElement.classList.contains("dark")).toBe(true);

    applyTheme("light");
    expect(document.documentElement.classList.contains("dark")).toBe(false);
  });

  it("honours the OS preference in system mode", () => {
    setSystemDark(true);
    applyTheme("system");
    expect(document.documentElement.classList.contains("dark")).toBe(true);

    setSystemDark(false);
    applyTheme("system");
    expect(document.documentElement.classList.contains("dark")).toBe(false);
  });
});

describe("nextMode", () => {
  it("cycles light -> dark -> system -> light", () => {
    expect(nextMode("light")).toBe("dark");
    expect(nextMode("dark")).toBe("system");
    expect(nextMode("system")).toBe("light");
  });
});
