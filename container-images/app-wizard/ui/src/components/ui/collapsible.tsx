import { useState } from "react";
import { cn } from "@/lib/utils";

interface CollapsibleProps {
  title: React.ReactNode;
  subtitle?: React.ReactNode;
  defaultOpen?: boolean;
  badge?: React.ReactNode;
  children: React.ReactNode;
  className?: string;
}

// Minimal shadcn-styled collapsible (no Radix) — used for the advanced/expert
// tier group sections.
export function Collapsible({
  title,
  subtitle,
  defaultOpen = false,
  badge,
  children,
  className,
}: CollapsibleProps) {
  const [open, setOpen] = useState(defaultOpen);
  return (
    <div className={cn("rounded-lg border border-border bg-card", className)}>
      <button
        type="button"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
        className="flex w-full items-center justify-between gap-2 rounded-lg px-4 py-3 text-left hover:bg-muted"
      >
        <span className="flex items-center gap-2">
          <span
            className={cn("inline-block transition-transform text-muted-foreground", open && "rotate-90")}
            aria-hidden
          >
            ▶
          </span>
          <span className="text-sm font-medium">{title}</span>
          {badge}
        </span>
        {subtitle && <span className="text-xs text-muted-foreground">{subtitle}</span>}
      </button>
      {open && <div className="space-y-4 border-t border-border px-4 py-4">{children}</div>}
    </div>
  );
}

export function Switch({
  checked,
  onCheckedChange,
  id,
  disabled,
}: {
  checked: boolean;
  onCheckedChange: (v: boolean) => void;
  id?: string;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      role="switch"
      id={id}
      aria-checked={checked}
      disabled={disabled}
      onClick={() => onCheckedChange(!checked)}
      className={cn(
        "relative inline-flex h-5 w-9 shrink-0 items-center rounded-full border transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:opacity-50",
        checked ? "border-primary bg-primary" : "border-slate-400 bg-slate-300",
      )}
    >
      <span
        className={cn(
          "inline-block h-4 w-4 transform rounded-full border border-slate-300 bg-white shadow-sm transition-transform",
          checked ? "translate-x-4" : "translate-x-0.5",
        )}
      />
    </button>
  );
}
