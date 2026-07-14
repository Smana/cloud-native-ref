import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]): string {
  return twMerge(clsx(inputs));
}

// Normalise a thrown value into a human-readable message. Shared by the API
// callers (WizardForm, AppList, App) so the `e instanceof Error` dance lives once.
export function errorMessage(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}
