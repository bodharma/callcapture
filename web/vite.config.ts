/// <reference types="vitest/config" />
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// Dev loop: run the CallCapture app, then
//   CALLCAPTURE_PORT=<port of the app's loopback server> npm run dev
// The dev server proxies /api and /login to the app. The app's Host/Origin
// guard only accepts its own 127.0.0.1:<port>, so the proxy rewrites Host
// (changeOrigin) and, when present, the Origin header of proxied requests.
// Sign in once from the dev origin so the session cookie is set for it: open
//   http://localhost:5173/login?token=<token>&next=/
// with the token from the app's login URL.
const proxyFor = (target: string) => ({
  target,
  changeOrigin: true,
  configure: (p: {
    on: (
      event: "proxyReq",
      cb: (req: { getHeader(n: string): unknown; setHeader(n: string, v: string): void }) => void,
    ) => void;
  }) => {
    p.on("proxyReq", (req) => {
      if (req.getHeader("origin")) req.setHeader("origin", target);
    });
  },
});

export default defineConfig(({ command }) => {
  const port = process.env.CALLCAPTURE_PORT;
  const devServer = command === "serve" && !process.env.VITEST;
  if (devServer && !port) {
    throw new Error(
      "CALLCAPTURE_PORT is not set. Start the app and run: CALLCAPTURE_PORT=<port> npm run dev",
    );
  }
  const proxy = port ? proxyFor(`http://127.0.0.1:${port}`) : undefined;
  return {
    plugins: [react()],
    server: proxy ? { proxy: { "/api": proxy, "/login": proxy } } : {},
    test: { environment: "jsdom" },
  };
});
