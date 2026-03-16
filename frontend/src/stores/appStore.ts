import { create } from "zustand";

function getInitialDarkMode(): boolean {
  if (typeof window === "undefined") return false;
  const stored = localStorage.getItem("eagle-eye-dark-mode");
  if (stored !== null) return stored === "true";
  return window.matchMedia("(prefers-color-scheme: dark)").matches;
}

function applyDarkMode(dark: boolean) {
  document.documentElement.classList.toggle("dark", dark);
  localStorage.setItem("eagle-eye-dark-mode", String(dark));
}

interface AppState {
  darkMode: boolean;
  toggleDarkMode: () => void;
  currentInvestigationId: string | null;
  setCurrentInvestigation: (id: string | null) => void;
}

export const useAppStore = create<AppState>((set) => {
  const initial = getInitialDarkMode();
  applyDarkMode(initial);

  return {
    darkMode: initial,
    toggleDarkMode: () =>
      set((state) => {
        const next = !state.darkMode;
        applyDarkMode(next);
        return { darkMode: next };
      }),
    currentInvestigationId: null,
    setCurrentInvestigation: (id) => set({ currentInvestigationId: id }),
  };
});
