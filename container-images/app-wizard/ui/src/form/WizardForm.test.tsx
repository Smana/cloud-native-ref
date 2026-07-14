import { describe, expect, it, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, waitFor } from "@testing-library/react";
import { fixtureSchema } from "../api/__fixtures__/schema";
import type { User } from "../api/types";

// Stub the API client so the form's live-validate effect doesn't hit the network.
// assistStatus defaults to unavailable so the LLM assist UI stays hidden; the
// availability-gate test overrides it per-case.
const assistStatusMock = vi.fn().mockResolvedValue({ available: false });
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
    assistStatus: () => assistStatusMock(),
  };
});

import { WizardForm } from "./WizardForm";

const user: User = {
  login: "octocat",
  name: "The Octocat",
  avatarUrl: "",
  githubLinked: true,
};

describe("WizardForm renderer", () => {
  beforeEach(() => {
    vi.stubGlobal("clipboard", undefined);
    assistStatusMock.mockResolvedValue({ available: false });
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

  it("hides all LLM assist affordances when the assist backend is unavailable", async () => {
    assistStatusMock.mockResolvedValue({ available: false });
    render(<WizardForm schema={fixtureSchema} user={user} />);

    // Give the mount-time status probe a chance to resolve.
    await waitFor(() => expect(assistStatusMock).toHaveBeenCalled());

    expect(screen.queryByText(/Describe your app/i)).toBeNull();
    expect(screen.queryByText(/Network policy helper/i)).toBeNull();
    expect(screen.queryByRole("button", { name: /Prefill/i })).toBeNull();
    expect(screen.queryByRole("button", { name: /Suggest policies/i })).toBeNull();
  });

  it("shows the assist affordances when the backend reports available", async () => {
    assistStatusMock.mockResolvedValue({ available: true });
    render(<WizardForm schema={fixtureSchema} user={user} />);

    // The "Describe your app" collapsible header and the always-visible network
    // policy helper card appear once the status probe resolves available.
    expect(await screen.findByText(/Describe your app/i)).toBeTruthy();
    expect(screen.getByText(/Network policy helper/i)).toBeTruthy();
    // The policy suggester's button is not gated behind a collapse.
    expect(screen.getByRole("button", { name: /Suggest policies/i })).toBeTruthy();

    // Expanding the describe section reveals the Prefill button.
    fireEvent.click(screen.getByRole("button", { name: /Describe your app/i }));
    expect(screen.getByRole("button", { name: /Prefill/i })).toBeTruthy();
  });

  it("disables Open PR and shows a connect hint when githubLinked is false (zitadel mode)", () => {
    const unlinked: User = { ...user, githubLinked: false };
    render(<WizardForm schema={fixtureSchema} user={unlinked} />);

    const openPr = screen.getByRole("button", { name: /Open PR/i }) as HTMLButtonElement;
    expect(openPr.disabled).toBe(true);

    // Connect-GitHub helper text + link surfaces the account-link flow.
    expect(screen.getByText(/Connect your GitHub account first/i)).toBeTruthy();
    const link = screen.getByRole("link", { name: /connect GitHub/i });
    expect(link.getAttribute("href")).toBe("/api/auth/github/link");
  });
});
