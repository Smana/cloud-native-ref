import { useCallback, useEffect, useState } from "react";

// The dark palette already exists (.dark in index.css, darkMode: "class" in
// tailwind.config.js) — this module is what actually turns it on.
//
// Three modes rather than a boolean: "system" is a real, sticky choice ("keep
// following my OS"), not merely the absence of one. A boolean cannot express it,
// and users who dislike being overridden notice.

export type ThemeMode = "light" | "dark" | "system";
export type ResolvedTheme = "light" | "dark";

export const THEME_STORAGE_KEY = "app-wizard:theme";

const DARK_QUERY = "(prefers-color-scheme: dark)";

function isThemeMode(value: unknown): value is ThemeMode {
  return value === "light" || value === "dark" || value === "system";
}

/** The user's stored choice, or "system" when unset or corrupt. */
export function readStoredMode(): ThemeMode {
  try {
    const stored = localStorage.getItem(THEME_STORAGE_KEY);
    return isThemeMode(stored) ? stored : "system";
  } catch {
    // Safari private mode throws on localStorage access. Following the OS is a
    // perfectly good answer; failing to render is not.
    return "system";
  }
}

export function storeMode(mode: ThemeMode): void {
  try {
    localStorage.setItem(THEME_STORAGE_KEY, mode);
  } catch {
    // Non-fatal: the theme still applies for this session, it just won't persist.
  }
}

export function systemPrefersDark(): boolean {
  return typeof matchMedia === "function" && matchMedia(DARK_QUERY).matches;
}

export function resolveTheme(mode: ThemeMode): ResolvedTheme {
  if (mode === "system") return systemPrefersDark() ? "dark" : "light";
  return mode;
}

/** Toggle the `dark` class on <html>, which is what Tailwind keys off. */
export function applyTheme(mode: ThemeMode): ResolvedTheme {
  const resolved = resolveTheme(mode);
  document.documentElement.classList.toggle("dark", resolved === "dark");
  return resolved;
}

export function nextMode(mode: ThemeMode): ThemeMode {
  if (mode === "light") return "dark";
  if (mode === "dark") return "system";
  return "light";
}

export function useTheme() {
  const [mode, setModeState] = useState<ThemeMode>(readStoredMode);
  const [resolved, setResolved] = useState<ResolvedTheme>(() => resolveTheme(readStoredMode()));

  // Apply on mount and whenever the mode changes. The inline script in index.html
  // has already painted the right theme; this keeps React's view in sync with it.
  useEffect(() => {
    setResolved(applyTheme(mode));
  }, [mode]);

  // Track the OS *only* while following it. An explicit light/dark choice must
  // survive the user switching their OS theme.
  useEffect(() => {
    if (mode !== "system" || typeof matchMedia !== "function") return;

    const query = matchMedia(DARK_QUERY);
    const onChange = () => setResolved(applyTheme("system"));

    query.addEventListener("change", onChange);
    return () => query.removeEventListener("change", onChange);
  }, [mode]);

  const setMode = useCallback((next: ThemeMode) => {
    storeMode(next);
    setModeState(next);
  }, []);

  return { mode, resolved, setMode };
}
