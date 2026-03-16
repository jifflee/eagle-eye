import { useState } from "react";
import { useNavigate } from "react-router-dom";

export default function HomePage() {
  const navigate = useNavigate();
  const [address, setAddress] = useState({
    street: "",
    city: "",
    state: "GA",
    zip: "",
  });

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    // TODO: Call POST /api/v1/investigation and navigate to graph
    navigate("/investigation/demo");
  };

  return (
    <div className="mx-auto flex max-w-2xl flex-col items-center justify-center px-4 py-24">
      <h1 className="mb-2 text-4xl font-bold tracking-tight">Eagle Eye</h1>
      <p className="mb-12 text-lg text-gray-500">
        Open Source Intelligence — Address Profiling
      </p>

      <form onSubmit={handleSubmit} className="w-full space-y-4">
        <div>
          <label className="mb-1 block text-sm font-medium">
            Street Address
          </label>
          <input
            type="text"
            value={address.street}
            onChange={(e) =>
              setAddress((a) => ({ ...a, street: e.target.value }))
            }
            placeholder="123 Main Street"
            className="w-full rounded-lg border border-gray-300 px-4 py-3 text-lg focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-200 dark:border-gray-700 dark:bg-gray-800"
            required
          />
        </div>

        <div className="grid grid-cols-3 gap-4">
          <div>
            <label className="mb-1 block text-sm font-medium">City</label>
            <input
              type="text"
              value={address.city}
              onChange={(e) =>
                setAddress((a) => ({ ...a, city: e.target.value }))
              }
              placeholder="Lawrenceville"
              className="w-full rounded-lg border border-gray-300 px-3 py-2 focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-200 dark:border-gray-700 dark:bg-gray-800"
              required
            />
          </div>
          <div>
            <label className="mb-1 block text-sm font-medium">State</label>
            <input
              type="text"
              value={address.state}
              onChange={(e) =>
                setAddress((a) => ({ ...a, state: e.target.value }))
              }
              placeholder="GA"
              maxLength={2}
              className="w-full rounded-lg border border-gray-300 px-3 py-2 focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-200 dark:border-gray-700 dark:bg-gray-800"
              required
            />
          </div>
          <div>
            <label className="mb-1 block text-sm font-medium">ZIP</label>
            <input
              type="text"
              value={address.zip}
              onChange={(e) =>
                setAddress((a) => ({ ...a, zip: e.target.value }))
              }
              placeholder="30043"
              maxLength={10}
              className="w-full rounded-lg border border-gray-300 px-3 py-2 focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-200 dark:border-gray-700 dark:bg-gray-800"
              required
            />
          </div>
        </div>

        <button
          type="submit"
          className="w-full rounded-lg bg-blue-600 px-4 py-3 text-lg font-semibold text-white transition-colors hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-blue-400 focus:ring-offset-2"
        >
          Investigate Address
        </button>
      </form>
    </div>
  );
}
