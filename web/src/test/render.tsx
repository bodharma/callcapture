import { render } from "@testing-library/react";
import { createMemoryRouter, RouterProvider } from "react-router";
import { AppProviders } from "../app/providers";
import { routes } from "../app/routes";

/** Renders the real route table at `path`, with retries off so errors surface at once. */
export function renderAt(path: string) {
  const router = createMemoryRouter(routes, { initialEntries: [path] });
  const view = render(
    <AppProviders retry={false}>
      <RouterProvider router={router} />
    </AppProviders>,
  );
  return { ...view, router };
}
