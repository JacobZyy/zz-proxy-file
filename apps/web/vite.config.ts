import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const apiTarget = "http://127.0.0.1:3001";
const backendPrefix = "/clash-config-tool";

export default defineConfig({
  base: "/clash-config/",
  plugins: [react(), tailwindcss()],
  server: {
    port: 5173,
    proxy: {
      [backendPrefix]: apiTarget,
    },
  },
});
