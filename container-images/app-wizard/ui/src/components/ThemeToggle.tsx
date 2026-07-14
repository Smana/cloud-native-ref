import type { ReactElement } from "react";
import { Button } from "@/components/ui/button";
import { nextMode, useTheme, type ThemeMode } from "@/lib/theme";

// Inline SVGs rather than an icon package: the app has no icon dependency today,
// and three glyphs do not justify adding one to the bundle.

function SunIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true" className="h-5 w-5">
      <circle cx="12" cy="12" r="4" />
      <path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" strokeLinecap="round" />
    </svg>
  );
}

function MoonIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true" className="h-5 w-5">
      <path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function SystemIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true" className="h-5 w-5">
      <rect x="2" y="4" width="20" height="13" rx="2" />
      <path d="M8 21h8M12 17v4" strokeLinecap="round" />
    </svg>
  );
}

const ICONS: Record<ThemeMode, () => ReactElement> = {
  light: SunIcon,
  dark: MoonIcon,
  system: SystemIcon,
};

const LABELS: Record<ThemeMode, string> = {
  light: "Theme: light",
  dark: "Theme: dark",
  system: "Theme: system",
};

export function ThemeToggle() {
  const { mode, setMode } = useTheme();
  const Icon = ICONS[mode];

  // The label names the CURRENT mode, not the next one. A button that announces
  // where you are is honest; one that announces where clicking takes you leaves a
  // screen-reader user unable to tell what the theme actually is.
  return (
    <Button
      type="button"
      variant="ghost"
      size="icon"
      aria-label={LABELS[mode]}
      title={`${LABELS[mode]} — click to switch`}
      onClick={() => setMode(nextMode(mode))}
      className="text-brand-navy-fg hover:bg-white/10"
    >
      <Icon />
    </Button>
  );
}
