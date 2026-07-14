import "@testing-library/react";
import { vi } from "vitest";

// jsdom ships no window.matchMedia, so anything reading prefers-color-scheme throws
// before it can be asserted on. This fake is controllable: setSystemDark() flips the
// OS preference AND notifies subscribers, which is what lets us prove a live OS theme
// change reaches a mounted component (and is correctly ignored after an explicit choice).

type ChangeListener = (event: MediaQueryListEvent) => void;

class FakeMediaQueryList {
  readonly listeners = new Set<ChangeListener>();
  matches: boolean;

  constructor(
    readonly media: string,
    matches: boolean,
  ) {
    this.matches = matches;
  }

  addEventListener(_type: "change", listener: ChangeListener) {
    this.listeners.add(listener);
  }

  removeEventListener(_type: "change", listener: ChangeListener) {
    this.listeners.delete(listener);
  }

  // Older Safari exposes only the deprecated pair; support both so the code under
  // test is free to use either.
  addListener(listener: ChangeListener) {
    this.listeners.add(listener);
  }

  removeListener(listener: ChangeListener) {
    this.listeners.delete(listener);
  }

  dispatchEvent() {
    return true;
  }
}

const queries = new Map<string, FakeMediaQueryList>();
let systemDark = false;

function matchesFor(media: string): boolean {
  return media.includes("dark") ? systemDark : !systemDark;
}

vi.stubGlobal("matchMedia", (media: string) => {
  let mql = queries.get(media);
  if (!mql) {
    mql = new FakeMediaQueryList(media, matchesFor(media));
    queries.set(media, mql);
  }
  return mql;
});

/** Flip the simulated OS colour scheme and notify every live subscriber. */
export function setSystemDark(dark: boolean) {
  systemDark = dark;
  for (const mql of queries.values()) {
    mql.matches = matchesFor(mql.media);
    for (const listener of [...mql.listeners]) {
      listener({ matches: mql.matches, media: mql.media } as MediaQueryListEvent);
    }
  }
}

/** Reset OS preference, stored choice and the applied class between tests. */
export function resetTheme() {
  systemDark = false;
  queries.clear();
  localStorage.clear();
  document.documentElement.classList.remove("dark");
}
