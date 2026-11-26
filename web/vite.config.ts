/// <reference types="vitest/config" />
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// Dev loop: run the CallCapture app, then
//   CALLCAPTURE_PORT=<port shown by the app> npm run dev
// and open the app's login URL once so the session cookie is set. The dev
// server proxies /api and /login to the app's loopback server.
const target = `http://127.0.0.1:${process.env.CALLCAPTURE_PORT ?? "0"}`;

export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      "/api": { target },
      "/login": { target },
    },
  },
  test: { environment: "jsdom" },
});
