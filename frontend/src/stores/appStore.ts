import { create } from "zustand";

interface AppState {
  darkMode: boolean;
  toggleDarkMode: () => void;
  currentInvestigationId: string | null;
  setCurrentInvestigation: (id: string | null) => void;
}

export const useAppStore = create<AppState>((set) => ({
  darkMode: false,
  toggleDarkMode: () =>
    set((state) => {
      const next = !state.darkMode;
      document.documentElement.classList.toggle("dark", next);
      return { darkMode: next };
    }),
  currentInvestigationId: null,
  setCurrentInvestigation: (id) => set({ currentInvestigationId: id }),
}));
