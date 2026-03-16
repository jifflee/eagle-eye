/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{js,ts,jsx,tsx}"],
  darkMode: "class",
  theme: {
    extend: {
      colors: {
        // Entity type colors
        entity: {
          person: "#3B82F6",
          address: "#EF4444",
          business: "#10B981",
          property: "#F59E0B",
          case: "#8B5CF6",
          vehicle: "#EC4899",
          crime: "#DC2626",
          social: "#14B8A6",
          contact: "#6B7280",
          infrastructure: "#94A3B8",
        },
      },
    },
  },
  plugins: [],
};
