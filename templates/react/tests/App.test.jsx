// @vitest-environment jsdom
import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import App from "../src/App.jsx";

describe("App", () => {
  it("renders without crashing and shows the heading", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(() => Promise.resolve({ json: () => Promise.resolve({ status: "ok", connected: false }) })),
    );

    render(<App />);
    expect(screen.getByText("React App Template")).toBeInTheDocument();

    // Wait for the fetch-driven state updates to settle before the test
    // returns -- otherwise they land after unmount and React warns that
    // they weren't wrapped in act().
    expect(await screen.findByText("Backend health: ok")).toBeInTheDocument();
    expect(await screen.findByText("Database connected: false")).toBeInTheDocument();

    vi.unstubAllGlobals();
  });
});
