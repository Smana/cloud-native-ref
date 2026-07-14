import { describe, expect, it, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { fixtureSchema } from "../api/__fixtures__/schema";
import type { User } from "../api/types";

// Stub the API client so the form's live-validate effect doesn't hit the network.
vi.mock("../api/client", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../api/client")>();
  return {
    ...actual,
    validate: vi.fn().mockResolvedValue({
      valid: true,
      schemaErrors: [],
      celViolations: [],
      secretFindings: [],
    }),
    renderPreview: vi.fn(),
    openPR: vi.fn(),
  };
});

import { WizardForm } from "./WizardForm";

const user: User = { login: "octocat", name: "The Octocat", avatarUrl: "" };

describe("WizardForm renderer", () => {
  beforeEach(() => {
    vi.stubGlobal("clipboard", undefined);
  });

  it("basic tier (first screen) shows ≤ 8 visible inputs", () => {
    render(<WizardForm schema={fixtureSchema} user={user} />);
    const formColumn = screen.getByTestId("form-column");
    // First-screen inputs = every control rendered outside a collapsed section.
    // The "Basics" card and the always-open basic-group cards (Workload,
    // Networking & exposure, …) are visible; advanced/expert <Collapsible>
    // groups are collapsed by default and render no children until expanded.
    // Excludes radio inputs (the ImageField pull-policy is an inline radio group,
    // not a distinct first-screen field).
    const inputs = formColumn.querySelectorAll(
      "input:not([type='radio']), textarea, select",
    );
    expect(inputs.length).toBeLessThanOrEqual(8);
    expect(inputs.length).toBeGreaterThan(0);
  });

  it("SC-002: a hint-less schema field is rendered in the (collapsed) advanced tier, never dropped", () => {
    render(<WizardForm schema={fixtureSchema} user={user} />);

    // futureScalarField has no hint → advanced tier → lives in "More options"
    // ungrouped collapsible. Collapsed by default, so not visible yet.
    expect(screen.queryByLabelText(/future/i)).toBeNull();

    // Expand the "More options" section that holds ungrouped advanced fields.
    const moreBtn = screen.getByRole("button", { name: /More options/i });
    fireEvent.click(moreBtn);

    // Now the future field control is in the DOM (proving it was rendered from
    // the schema alone, with zero wizard code referencing it).
    const control = screen.getByLabelText(/future/i);
    expect(control).toBeTruthy();
  });
});
