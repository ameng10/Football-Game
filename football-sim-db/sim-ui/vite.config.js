import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// If you prefer a dev-time proxy instead of enabling CORS in API:
//  server: { proxy: { "/api": "http://localhost:3001" } }
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173
  }
});
