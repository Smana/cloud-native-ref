/** @type {import('tailwindcss').Config} */
// Ogenki brand palette (SPEC-008). Light theme is the default; a `.dark`
// block maps surfaces to the deep-navy brand color. Colors are wired through
// CSS variables declared in src/index.css so the theme can be swapped at the
// document root without a rebuild.
export default {
  darkMode: "class",
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        border: "var(--border)",
        input: "var(--input)",
        ring: "var(--ring)",
        background: "var(--background)",
        foreground: "var(--foreground)",
        muted: "var(--muted)",
        "muted-foreground": "var(--muted-foreground)",
        primary: "var(--primary)",
        "primary-foreground": "var(--primary-foreground)",
        accent: "var(--accent)",
        "accent-foreground": "var(--accent-foreground)",
        success: "var(--success)",
        "success-foreground": "var(--success-foreground)",
        destructive: "var(--destructive)",
        "destructive-foreground": "var(--destructive-foreground)",
        warning: "var(--warning)",
        "warning-foreground": "var(--warning-foreground)",
        card: "var(--card)",
        "card-foreground": "var(--card-foreground)",
        brand: {
          navy: "var(--brand-navy)",
          "navy-fg": "var(--brand-navy-foreground)",
        },
      },
      borderRadius: {
        lg: "0.5rem",
        md: "calc(0.5rem - 2px)",
        sm: "calc(0.5rem - 4px)",
      },
    },
  },
  plugins: [],
};
