import { beforeEach, describe, expect, it } from "vitest";
import { act, render, screen } from "@testing-library/react";
import { resetTheme, setSystemDark } from "@/test/setup";
import { THEME_STORAGE_KEY } from "@/lib/theme";
import { ThemeToggle } from "@/components/ThemeToggle";

const isDark = () => document.documentElement.classList.contains("dark");
const toggle = () => screen.getByRole("button", { name: /theme/i });

beforeEach(resetTheme);

describe("ThemeToggle", () => {
  it("follows the OS on first load, with nothing stored", () => {
    setSystemDark(true);
    render(<ThemeToggle />);
    expect(isDark()).toBe(true);
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBeNull();
  });

  it("stays light when the OS prefers light", () => {
    setSystemDark(false);
    render(<ThemeToggle />);
    expect(isDark()).toBe(false);
  });

  it("cycles light -> dark -> system and persists the choice", () => {
    setSystemDark(false);
    render(<ThemeToggle />);

    act(() => toggle().click()); // system -> light
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe("light");
    expect(isDark()).toBe(false);

    act(() => toggle().click()); // light -> dark
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe("dark");
    expect(isDark()).toBe(true);

    act(() => toggle().click()); // dark -> system
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe("system");
  });

  it("restores the persisted choice over the OS preference", () => {
    localStorage.setItem(THEME_STORAGE_KEY, "dark");
    setSystemDark(false); // OS says light, the user said dark
    render(<ThemeToggle />);
    expect(isDark()).toBe(true);
  });

  it("tracks a live OS change while in system mode", () => {
    setSystemDark(false);
    render(<ThemeToggle />);
    expect(isDark()).toBe(false);

    act(() => setSystemDark(true));
    expect(isDark()).toBe(true);
  });

  it("ignores a live OS change once the user has chosen explicitly", () => {
    localStorage.setItem(THEME_STORAGE_KEY, "light");
    setSystemDark(false);
    render(<ThemeToggle />);
    expect(isDark()).toBe(false);

    // The OS goes dark, but the user explicitly asked for light — leave it alone.
    act(() => setSystemDark(true));
    expect(isDark()).toBe(false);
  });

  it("names the current mode for screen readers", () => {
    setSystemDark(false);
    render(<ThemeToggle />);
    expect(toggle().getAttribute("aria-label")).toMatch(/system/i);

    act(() => toggle().click()); // -> light
    expect(toggle().getAttribute("aria-label")).toMatch(/light/i);
  });
});
