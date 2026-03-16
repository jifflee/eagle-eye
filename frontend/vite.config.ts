import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "path";

export default defineConfig(({ mode }) => {
  const backendUrl = process.env.VITE_API_BASE_URL || "http://localhost:8000";

  return {
    plugins: [react()],
    resolve: {
      alias: {
        "@": path.resolve(__dirname, "./src"),
      },
    },
    server: {
      // Port can be overridden via --port flag or VITE_PORT env
      port: parseInt(process.env.VITE_PORT || "5173", 10),
      strictPort: false, // If port taken, Vite picks next available
      open: false, // We handle browser opening in launch.sh
      proxy: {
        "/api": {
          target: backendUrl,
          changeOrigin: true,
        },
      },
    },
  };
});
