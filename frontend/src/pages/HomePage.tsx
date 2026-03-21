import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { validateAddress, type AddressFields } from "@/utils/validateAddress";
import { apiFetch } from "@/api/client";

type Step = "input" | "validating" | "confirm" | "submitting";

interface MatchedAddress {
  formatted: string;
  latitude?: number;
  longitude?: number;
  tract?: string;
  county?: string;
}

interface ValidationResponse {
  valid: boolean;
  errors: string[];
  matched: MatchedAddress | null;
  suggestions: MatchedAddress[];
  warning?: string;
}

export default function HomePage() {
  const navigate = useNavigate();
  const [step, setStep] = useState<Step>("input");
  const [address, setAddress] = useState<AddressFields>({
    street: "",
    city: "",
    state: "GA",
    zip: "",
  });
  const [fieldErrors, setFieldErrors] = useState<Record<string, string>>({});
  const [serverErrors, setServerErrors] = useState<string[]>([]);
  const [matched, setMatched] = useState<MatchedAddress | null>(null);
  const [suggestions, setSuggestions] = useState<MatchedAddress[]>([]);
  const [warning, setWarning] = useState("");

  // Load recent searches from localStorage (filter out broken entries)
  const [recentSearches] = useState<string[]>(() => {
    try {
      const raw = JSON.parse(localStorage.getItem("eagle-eye-recent") || "[]") as string[];
      // Filter out broken entries like ", , GA " or empty strings
      return raw.filter((s) => s && s.trim().length > 5 && !s.startsWith(","));
    } catch {
      return [];
    }
  });

  const saveRecent = (addr: string) => {
    const recent = [addr, ...recentSearches.filter((r) => r !== addr)].slice(0, 10);
    localStorage.setItem("eagle-eye-recent", JSON.stringify(recent));
  };

  const handleValidate = async (e: React.FormEvent) => {
    e.preventDefault();
    setFieldErrors({});
    setServerErrors([]);
    setWarning("");

    // Client-side validation
    const { valid, errors } = validateAddress(address);
    if (!valid) {
      setFieldErrors(errors);
      return;
    }

    // Server-side validation via Census Geocoder
    setStep("validating");
    try {
      const result = await apiFetch<ValidationResponse>("/api/v1/address/validate", {
        method: "POST",
        body: JSON.stringify(address),
      });

      if (result.warning) setWarning(result.warning);

      if (result.valid && result.matched) {
        setMatched(result.matched);
        setSuggestions(result.suggestions || []);
        setStep("confirm");
      } else {
        setServerErrors(result.errors || ["Address not found"]);
        setSuggestions(result.suggestions || []);
        setStep("input");
      }
    } catch {
      // API unreachable — proceed with entered address
      setMatched({
        formatted: `${address.street}, ${address.city}, ${address.state} ${address.zip}`,
      });
      setWarning("Could not verify address — server unavailable. Proceeding with entered address.");
      setStep("confirm");
    }
  };

  const handleConfirm = async () => {
    setStep("submitting");
    const addressStr = matched?.formatted || `${address.street}, ${address.city}, ${address.state} ${address.zip}`;
    saveRecent(addressStr);

    // Cache the validation result locally
    try {
      const cacheKey = `eagle-eye-cache:${addressStr}`;
      localStorage.setItem(cacheKey, JSON.stringify({ matched, timestamp: Date.now() }));
    } catch { /* localStorage full — ignore */ }

    try {
      const result = await apiFetch<{ id: string }>("/api/v1/investigation", {
        method: "POST",
        body: JSON.stringify({ address }),
      });
      navigate(`/investigation/${result.id}`);
    } catch (err) {
      // Retry once after 2s (rate limit window)
      await new Promise((r) => setTimeout(r, 2000));
      try {
        const result = await apiFetch<{ id: string }>("/api/v1/investigation", {
          method: "POST",
          body: JSON.stringify({ address }),
        });
        navigate(`/investigation/${result.id}`);
      } catch {
        setStep("input");
        setServerErrors(["Could not create investigation. Please try again."]);
      }
    }
  };

  const handleUseSuggestion = (suggestion: MatchedAddress) => {
    setMatched(suggestion);
    setSuggestions([]);
    setServerErrors([]);
    setStep("confirm");
  };

  const inputClass = (field: string) =>
    `w-full rounded border px-3 py-2 text-sm transition-all focus:outline-none ${
      fieldErrors[field]
        ? "border-red-500/50 bg-red-500/5 text-red-300 dark:border-red-500/30 dark:bg-red-500/5"
        : "border-[#e2e8f0] bg-white text-[#1e293b] dark:border-[#1e293b] dark:bg-[#0f1629] dark:text-[#c8d1e0] dark:focus:border-blue-500/50"
    }`;

  return (
    <div className="mx-auto flex max-w-xl flex-col items-center justify-center px-4 py-20">
      <h1 className="mb-1 text-2xl font-light tracking-[0.15em] uppercase text-[#334155] dark:text-[#94a3b8]">
        Eagle Eye
      </h1>
      <p className="mb-12 text-[11px] font-medium uppercase tracking-[0.25em] text-[#94a3b8] dark:text-[#475569]">
        Open Source Intelligence
      </p>

      {/* === Step: Input === */}
      {(step === "input" || step === "validating") && (
        <form onSubmit={handleValidate} className="w-full space-y-4">
          <div>
            <label className="mb-1 block text-[10px] font-medium uppercase tracking-[0.15em] text-[#64748b]">Street Address</label>
            <input
              type="text"
              value={address.street}
              onChange={(e) => setAddress((a) => ({ ...a, street: e.target.value }))}
              placeholder="123 Main Street"
              className={`${inputClass("street")} text-lg px-4 py-3`}
              disabled={step === "validating"}
            />
            {fieldErrors.street && (
              <p className="mt-1 text-sm text-red-500">{fieldErrors.street}</p>
            )}
          </div>

          <div className="grid grid-cols-3 gap-4">
            <div>
              <label className="mb-1 block text-[10px] font-medium uppercase tracking-[0.15em] text-[#64748b]">City</label>
              <input
                type="text"
                value={address.city}
                onChange={(e) => setAddress((a) => ({ ...a, city: e.target.value }))}
                placeholder="Lawrenceville"
                className={inputClass("city")}
                disabled={step === "validating"}
              />
              {fieldErrors.city && (
                <p className="mt-1 text-sm text-red-500">{fieldErrors.city}</p>
              )}
            </div>
            <div>
              <label className="mb-1 block text-[10px] font-medium uppercase tracking-[0.15em] text-[#64748b]">State</label>
              <input
                type="text"
                value={address.state}
                onChange={(e) => setAddress((a) => ({ ...a, state: e.target.value.toUpperCase() }))}
                placeholder="GA"
                maxLength={2}
                className={inputClass("state")}
                disabled={step === "validating"}
              />
              {fieldErrors.state && (
                <p className="mt-1 text-sm text-red-500">{fieldErrors.state}</p>
              )}
            </div>
            <div>
              <label className="mb-1 block text-[10px] font-medium uppercase tracking-[0.15em] text-[#64748b]">Zip Code</label>
              <input
                type="text"
                value={address.zip}
                onChange={(e) => setAddress((a) => ({ ...a, zip: e.target.value }))}
                placeholder="30043"
                maxLength={10}
                className={inputClass("zip")}
                disabled={step === "validating"}
              />
              {fieldErrors.zip && (
                <p className="mt-1 text-sm text-red-500">{fieldErrors.zip}</p>
              )}
            </div>
          </div>

          {/* Server errors */}
          {serverErrors.length > 0 && (
            <div className="rounded-lg border border-red-200 bg-red-50 p-4 dark:border-red-800 dark:bg-red-950">
              <p className="font-medium text-red-700 dark:text-red-400">Address not found</p>
              {serverErrors.map((err, i) => (
                <p key={i} className="mt-1 text-sm text-red-600 dark:text-red-400">{err}</p>
              ))}
            </div>
          )}

          {/* Suggestions after failed validation */}
          {suggestions.length > 0 && step === "input" && (
            <div className="rounded-lg border border-blue-200 bg-blue-50 p-4 dark:border-blue-800 dark:bg-blue-950">
              <p className="mb-2 text-sm font-medium text-blue-700 dark:text-blue-400">
                Did you mean:
              </p>
              {suggestions.map((s, i) => (
                <button
                  key={i}
                  type="button"
                  onClick={() => handleUseSuggestion(s)}
                  className="mb-1 block w-full rounded-md border border-blue-200 bg-white px-3 py-2 text-left text-sm hover:bg-blue-100 dark:border-blue-700 dark:bg-blue-900 dark:hover:bg-blue-800"
                >
                  {s.formatted}
                </button>
              ))}
            </div>
          )}

          <button
            type="submit"
            disabled={step === "validating"}
            className="w-full rounded border border-blue-500/30 bg-blue-600/10 px-4 py-2.5 text-xs font-semibold uppercase tracking-[0.2em] text-blue-400 transition-all hover:bg-blue-600/20 hover:border-blue-500/50 disabled:opacity-40 dark:bg-blue-500/10 dark:hover:bg-blue-500/20"
          >
            {step === "validating" ? (
              <span className="flex items-center justify-center gap-2">
                <svg className="h-5 w-5 animate-spin" viewBox="0 0 24 24" fill="none">
                  <circle cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" className="opacity-25" />
                  <path fill="currentColor" d="M4 12a8 8 0 018-8v4a4 4 0 00-4 4H4z" className="opacity-75" />
                </svg>
                Validating address...
              </span>
            ) : (
              "Investigate Address"
            )}
          </button>
        </form>
      )}

      {/* === Step: Confirm === */}
      {step === "confirm" && matched && (
        <div className="w-full space-y-4">
          <div className="rounded-lg border border-green-200 bg-green-50 p-6 dark:border-green-800 dark:bg-green-950">
            <p className="mb-1 text-sm font-medium text-green-700 dark:text-green-400">
              Verified Address
            </p>
            <p className="text-xl font-semibold text-green-900 dark:text-green-100">
              {matched.formatted}
            </p>
            {matched.latitude && matched.longitude && (
              <p className="mt-2 text-xs text-green-600 dark:text-green-500">
                {matched.latitude.toFixed(4)}, {matched.longitude.toFixed(4)}
                {matched.tract && ` — Census Tract ${matched.tract}`}
              </p>
            )}
          </div>

          {warning && (
            <div className="rounded-lg border border-yellow-200 bg-yellow-50 p-3 text-sm text-yellow-700 dark:border-yellow-800 dark:bg-yellow-950 dark:text-yellow-400">
              {warning}
            </div>
          )}

          {suggestions.length > 0 && (
            <div className="rounded-lg border border-gray-200 p-4 dark:border-gray-700">
              <p className="mb-2 text-sm text-gray-500 dark:text-gray-400">Other matches:</p>
              {suggestions.map((s, i) => (
                <button
                  key={i}
                  type="button"
                  onClick={() => handleUseSuggestion(s)}
                  className="mb-1 block w-full rounded-md border border-gray-200 px-3 py-2 text-left text-sm hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-800"
                >
                  {s.formatted}
                </button>
              ))}
            </div>
          )}

          <div className="flex gap-3">
            <button
              onClick={() => { setStep("input"); setMatched(null); setSuggestions([]); }}
              className="flex-1 rounded-lg border border-gray-300 px-4 py-3 font-semibold transition-colors hover:bg-gray-50 dark:border-gray-600 dark:hover:bg-gray-800"
            >
              Edit Address
            </button>
            <button
              onClick={handleConfirm}
              className="flex-1 rounded-lg bg-blue-600 px-4 py-3 font-semibold text-white transition-colors hover:bg-blue-700 dark:bg-blue-500 dark:hover:bg-blue-600"
            >
              Start Investigation
            </button>
          </div>
        </div>
      )}

      {/* === Step: Submitting === */}
      {step === "submitting" && (
        <div className="flex w-full flex-col items-center gap-4 py-8">
          <svg className="h-10 w-10 animate-spin text-blue-500" viewBox="0 0 24 24" fill="none">
            <circle cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" className="opacity-25" />
            <path fill="currentColor" d="M4 12a8 8 0 018-8v4a4 4 0 00-4 4H4z" className="opacity-75" />
          </svg>
          <p className="text-lg text-gray-500 dark:text-gray-400">Starting investigation...</p>
        </div>
      )}

      {/* === Recent Searches === */}
      {step === "input" && recentSearches.length > 0 && (
        <div className="mt-8 w-full">
          <p className="mb-2 text-sm font-medium text-gray-400 dark:text-gray-500">Recent</p>
          <div className="space-y-1">
            {recentSearches.slice(0, 5).map((addr, i) => (
              <button
                key={i}
                onClick={() => {
                  // Parse address string back into fields and re-validate
                  const parts = addr.split(",").map((s: string) => s.trim());
                  const street = parts[0] || "";
                  const rest = parts.slice(1).join(",").trim();
                  // "City, ST ZIP" or "City ST ZIP"
                  const cityStateZip = rest.match(/^(.+?),?\s+([A-Z]{2})\s+(\d{5})/);
                  if (cityStateZip) {
                    setAddress({
                      street,
                      city: cityStateZip[1],
                      state: cityStateZip[2],
                      zip: cityStateZip[3],
                    });
                  } else {
                    setAddress((a) => ({ ...a, street }));
                  }
                  // Clear any stale state and let user re-submit
                  setFieldErrors({});
                  setServerErrors([]);
                  setMatched(null);
                  setStep("input");
                }}
                className="block w-full rounded-md px-3 py-2 text-left text-sm text-gray-600 hover:bg-gray-100 dark:text-gray-400 dark:hover:bg-gray-800"
              >
                {addr}
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
