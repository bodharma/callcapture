import { Navigate, type RouteObject } from "react-router";
import { NotFound } from "../components/NotFound";
import { LivePlaceholder } from "../features/sessions/LivePlaceholder";
import { SessionDetail } from "../features/sessions/SessionDetail";
import { SessionsIndex, SessionsPage } from "../features/sessions/SessionsPage";
import { SettingsPage, SettingsPaneRoute } from "../features/settings/SettingsPage";

/** The app's routes (library mode; the server answers index.html for any non-API path). */
export const routes: RouteObject[] = [
  { path: "/", element: <Navigate to="/sessions" replace /> },
  {
    path: "/sessions",
    element: <SessionsPage />,
    children: [
      { index: true, element: <SessionsIndex /> },
      { path: ":id", element: <SessionDetail /> },
      { path: ":id/live", element: <LivePlaceholder /> },
    ],
  },
  {
    path: "/settings",
    element: <SettingsPage />,
    children: [
      { index: true, element: <Navigate to="/settings/general" replace /> },
      { path: ":pane", element: <SettingsPaneRoute /> },
    ],
  },
  { path: "*", element: <NotFound /> },
];
