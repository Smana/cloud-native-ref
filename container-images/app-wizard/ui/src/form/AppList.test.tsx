import { describe, expect, it, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";

vi.mock("../api/client", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../api/client")>();
  return {
    ...actual,
    listApps: vi.fn().mockResolvedValue([
      { stack: "dev", name: "cinema", namespace: "dev-apps", image: "cinema:1.0", type: "web" },
      { stack: "prod", name: "reaper", namespace: "prod-apps", image: "reaper:2.1", type: "cron" },
    ]),
    openPR: vi.fn(),
  };
});

import { AppList } from "./AppList";

describe("AppList", () => {
  it("renders a row per app from the fixture", async () => {
    render(<AppList onEdit={vi.fn()} />);

    await waitFor(() => {
      expect(screen.getAllByTestId("app-row")).toHaveLength(2);
    });

    expect(screen.getByText("cinema")).toBeTruthy();
    expect(screen.getByText("reaper")).toBeTruthy();
    // Type badge + edit/decommission actions present.
    expect(screen.getAllByRole("button", { name: /Edit/i })).toHaveLength(2);
    expect(screen.getAllByRole("button", { name: /Decommission/i })).toHaveLength(2);
  });
});
