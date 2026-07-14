import { useEffect, useState } from "react";

// Returns a debounced copy of `value` that updates at most once per `delayMs`
// after changes settle. Used to throttle live /api/validate calls (FR-002).
export function useDebounced<T>(value: T, delayMs: number): T {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const t = setTimeout(() => setDebounced(value), delayMs);
    return () => clearTimeout(t);
  }, [value, delayMs]);
  return debounced;
}
