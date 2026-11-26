import { useState } from "react";
import { createBrowserRouter, RouterProvider } from "react-router";
import { AppProviders } from "./app/providers";
import { routes } from "./app/routes";

export function App() {
  const [router] = useState(() => createBrowserRouter(routes));
  return (
    <AppProviders>
      <RouterProvider router={router} />
    </AppProviders>
  );
}
