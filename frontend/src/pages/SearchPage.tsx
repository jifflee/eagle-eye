export default function SearchPage() {
  return (
    <div className="mx-auto max-w-4xl px-4 py-8">
      <h2 className="mb-6 text-2xl font-bold">Search Entities</h2>
      <input
        type="text"
        placeholder="Search people, businesses, cases..."
        className="w-full rounded-lg border border-gray-300 px-4 py-3 text-lg focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-200 dark:border-gray-700 dark:bg-gray-800"
      />
      <p className="mt-8 text-center text-gray-400">
        Search will be implemented in Issue #33 (5.6)
      </p>
    </div>
  );
}
